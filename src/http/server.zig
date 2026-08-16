const std = @import("std");
const store = @import("../store.zig");
const redis = @import("../redis/client.zig");
const hitokoto = @import("hitokoto.zig");

pub const Server = struct {
    gpa: std.mem.Allocator,
    // 命名偏离了 brief 字面量（brief 写的是 `store`）：这个模块顶层已经有
    // `const store = @import("../store.zig")`，字段再叫 `store` 虽然能编译
    // （字段名和模块级 const 属于不同的命名空间，Zig 不会报重影），但会让
    // `self.store.randomAny(...)` 这类调用点里同一个标识符在同一行里指两个
    // 完全不同的东西（一次是字段访问，一次是紧挨着的 `store.Quote`/
    // `store.Store` 类型引用），读起来容易错认。改成 `st` 是刻意的可读性
    // 选择，不是编译器强制的——跟下面 `listen_port` 那个真正会撞
    // `port()` 方法名导致编译失败的重命名不是一回事。
    st: *store.Store,
    listener: std.net.Server,
    /// 已 accept 连接的接收超时（秒）。这个服务是单线程串行处理的：一条连上来
    /// 就一直不发请求行的连接，会让 receiveHead 永久阻塞，整个公开 API 停摆
    /// （Slowloris，一条连接就够）。有了它，静默连接最多占住这么久就会被踢掉，
    /// 循环继续接下一条。测试里调小以便快速验证。
    ///
    /// 只设收方向、不设发方向：响应体都在几 KB 以内，塞得进内核发送缓冲区，
    /// 写不会阻塞；真正的暴露面在读。
    recv_timeout_s: u32 = 10,

    pub fn listen(
        gpa: std.mem.Allocator,
        st: *store.Store,
        host: []const u8,
        listen_port: u16,
    ) !Server {
        const addr = try std.net.Address.parseIp(host, listen_port);
        return .{
            .gpa = gpa,
            .st = st,
            .listener = try addr.listen(.{ .reuse_address = true }),
        };
    }

    pub fn port(self: *Server) u16 {
        return self.listener.listen_address.getPort();
    }

    pub fn deinit(self: *Server) void {
        self.listener.deinit();
    }

    /// 生产入口：持续 accept，单次连接失败只记日志、不让整个服务崩掉——
    /// 一次畸形请求或者客户端提前断开不应该拖垮后面所有连接。
    pub fn runForever(self: *Server) void {
        while (true) {
            self.serveOnce() catch |e| {
                std.log.warn("http: connection failed: {s}", .{@errorName(e)});
            };
        }
    }

    /// 给已 accept 的连接装上 SO_RCVTIMEO。设置失败不致命：拿不到超时保护也
    /// 比直接拒绝这条连接强，记一行警告继续处理。
    fn setRecvTimeout(self: *Server, sock: std.posix.socket_t) void {
        const tv: std.posix.timeval = .{ .sec = @intCast(self.recv_timeout_s), .usec = 0 };
        std.posix.setsockopt(
            sock,
            std.posix.SOL.SOCKET,
            std.posix.SO.RCVTIMEO,
            std.mem.asBytes(&tv),
        ) catch |e| {
            std.log.warn("http: could not set SO_RCVTIMEO: {s}", .{@errorName(e)});
        };
    }

    /// 供测试单步驱动：只 accept 一次、处理一个请求就返回。
    pub fn serveOnce(self: *Server) !void {
        const conn = try self.listener.accept();
        defer conn.stream.close();
        self.setRecvTimeout(conn.stream.handle);

        var rbuf: [8192]u8 = undefined;
        var wbuf: [8192]u8 = undefined;
        var sr = conn.stream.reader(&rbuf);
        var sw = conn.stream.writer(&wbuf);
        // reader 是函数调用，writer 是字段取址 —— 顺序写反编不过。
        var http_server = std.http.Server.init(sr.interface(), &sw.interface);

        var req = try http_server.receiveHead();
        try self.handle(&req);
    }

    /// keep_alive = false 是刻意的，不是保守默认：serveOnce 里的
    /// `defer conn.stream.close()` 无论如何都会关掉这条连接，而 req.respond 的
    /// 默认值 keep_alive=true 不会发 `connection: close` 头。两者凑在一起就是
    /// 在骗客户端——带连接池的客户端会把这条已经被我们关掉的 socket 留着复用，
    /// 下一个请求撞上 EOF。宣称的行为必须跟实际行为一致。
    fn respondJson(req: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
        try req.respond(body, .{
            .status = status,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json; charset=utf-8" }},
        });
    }

    /// `/extra/batch/:count` 的前缀。单独命名成常量是因为路由判断和路径段
    /// 切分（`path[extra_batch_prefix.len..]`）必须用同一个字符串——写成两个
    /// 字面量会有一份将来改动时漏改另一份的风险。
    const extra_batch_prefix = "/extra/batch/";

    fn handle(self: *Server, req: *std.http.Server.Request) !void {
        const gpa = self.gpa;
        const target = req.head.target;

        // 先按路径路由，再看方法：未知路径一律 404（不论方法），只有落在
        // 一个已知路径上、方法又不对时才是 405。先判方法会让 "POST /nope"
        // 之类的请求错误地报出 405（意味着 "/nope" 上其实存在别的方法），
        // 而不是 404（这个路径压根不存在）——两者语义不同，顺序不能反。
        // 三个已知路径统一走这一条路由，各自的方法检查放在各自的处理函数里。
        const path_end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
        const path = target[0..path_end];

        if (std.mem.eql(u8, path, "/")) return self.handleRoot(req, target);
        if (std.mem.eql(u8, path, "/extra/all")) return self.handleExtraAll(req);
        if (std.mem.startsWith(u8, path, extra_batch_prefix)) {
            const rest = path[extra_batch_prefix.len..];
            // `rest` 不含 '/' 才是 "/extra/batch/:count" 这一条路由本身：
            // 空串（"/extra/batch/"，缺 count）算命中这条路由、count 校验时
            // 再拒；含 '/' 的（"/extra/batch/1/2"）路径结构上就不是这一条
            // 路由能表达的形状，落到下面的通用 404，跟 "/nope" 同一个道理——
            // 这个资源压根不存在，不是"这个资源存在但传参有误"。
            if (std.mem.indexOfScalar(u8, rest, '/') == null) {
                return self.handleExtraBatch(req, rest);
            }
        }

        const b = try hitokoto.errorBody(gpa, "not found");
        defer gpa.free(b);
        return respondJson(req, .not_found, b);
    }

    fn handleRoot(self: *Server, req: *std.http.Server.Request, target: []const u8) !void {
        const gpa = self.gpa;

        if (req.head.method != .GET) {
            const b = try hitokoto.errorBody(gpa, "method not allowed");
            defer gpa.free(b);
            return respondJson(req, .method_not_allowed, b);
        }

        const query = hitokoto.parseQuery(gpa, target) catch |e| {
            const msg = switch (e) {
                error.UnsupportedCharset => "only utf-8 charset is supported",
                error.BadLengthRange => "min_length must not exceed max_length",
                error.InvalidNumber => "min_length and max_length must be integers",
                error.InvalidEncode => "encode must be one of json, text, js",
                error.InvalidCallback => "callback must be non-empty and match [A-Za-z0-9_$.]",
                error.OutOfMemory => return e,
            };
            const b = try hitokoto.errorBody(gpa, msg);
            defer gpa.free(b);
            return respondJson(req, .bad_request, b);
        };
        defer query.deinit(gpa);

        const maybe = if (query.min_length != null or query.max_length != null)
            self.st.randomByLength(gpa, query.min_length orelse 0, query.max_length orelse std.math.maxInt(u32))
        else
            self.st.randomAny(gpa);

        // 区分两类失败：Redis 返回“没有匹配”（null）是正常的 404；Redis
        // 本身连不上/协议错误/读写失败是另一类——不能让它原样从 handle
        // 里 try 出去、把连接直接摔断而不回任何响应。对公网端点来说，
        // 500 + 跟 400/404 一致的 JSON 错误体，比一个客户端只能看到
        // "连接被重置"的哑巴失败要好得多。OutOfMemory 单独放过：那种情况下
        // 连 errorBody 本身都可能分配失败，跟其余「构造错误响应」的分支
        // 保持同样的处理方式（直接 return e，交给 runForever 记日志）。
        const found = maybe catch |e| {
            if (e == error.OutOfMemory) return e;
            const b = try hitokoto.errorBody(gpa, "storage backend unavailable");
            defer gpa.free(b);
            return respondJson(req, .internal_server_error, b);
        };

        const quote = found orelse {
            const b = try hitokoto.errorBody(gpa, "no sentence available");
            defer gpa.free(b);
            return respondJson(req, .not_found, b);
        };
        defer quote.deinit(gpa);

        const rendered = try hitokoto.render(gpa, quote, query);
        defer rendered.deinit(gpa);

        // keep_alive = false 的理由同 respondJson。
        try req.respond(rendered.body, .{
            .status = .ok,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = rendered.content_type }},
        });
    }

    /// `GET /extra/all`：返回全部语录，JSON 数组。不认 `encode`/`min_length`/
    /// `max_length`/`callback`/`select`——一言协议没有多条语录的形态，这条
    /// 路径落在 `/extra/` 前缀下就是在承认它是自定义扩展，query string 整个
    /// 被忽略，不解析。
    ///
    /// 库空 → `[]` + 200，不是 404：跟 `/` 的"没有可服务的东西"不是一回事。
    /// 数组端点返回空数组本身就是一个成功的答案（"这就是全部，全部是零条"），
    /// 404 意味着"这条资源不存在"，语义不对。`/` 的单条语义不适用于这里。
    fn handleExtraAll(self: *Server, req: *std.http.Server.Request) !void {
        const gpa = self.gpa;

        if (req.head.method != .GET) {
            const b = try hitokoto.errorBody(gpa, "method not allowed");
            defer gpa.free(b);
            return respondJson(req, .method_not_allowed, b);
        }

        const quotes = self.st.allQuotes(gpa) catch |e| {
            if (e == error.OutOfMemory) return e;
            const b = try hitokoto.errorBody(gpa, "storage backend unavailable");
            defer gpa.free(b);
            return respondJson(req, .internal_server_error, b);
        };
        defer {
            for (quotes) |q| q.deinit(gpa);
            gpa.free(quotes);
        }

        const body = try hitokoto.jsonArrayBody(gpa, quotes);
        defer gpa.free(body);
        return respondJson(req, .ok, body);
    }

    /// `GET /extra/batch/:count`：随机返回 `count` 条语录，JSON 数组，
    /// **允许重复**——运营方明确选了这个语义（见 `store.randomMany` 的
    /// SRANDMEMBER 负数形式）。同样不认 `/` 的那套 query 参数。
    ///
    /// `count` 上限钉在 1000：它直接来自 URL，不做上限的话
    /// `/extra/batch/999999999` 是任何人都能触发的分配耗尽攻击——这不是
    /// 保守，是这条路径独有的暴露面。`/extra/all` 不需要这条护栏，因为它的
    /// 规模由库大小决定，不是由用户输入决定。
    fn handleExtraBatch(self: *Server, req: *std.http.Server.Request, count_str: []const u8) !void {
        const gpa = self.gpa;

        if (req.head.method != .GET) {
            const b = try hitokoto.errorBody(gpa, "method not allowed");
            defer gpa.free(b);
            return respondJson(req, .method_not_allowed, b);
        }

        // parseInt(usize, ...) 天然拒绝负号、小数点、空串、非数字字符——
        // usize 装不下负数，"-1"/"abc"/"" 都直接落进 catch。0 单独判断：
        // parseInt 能解析出 0，但语义上"要 0 条"不是一个合法的批量请求。
        const count = std.fmt.parseInt(usize, count_str, 10) catch {
            const b = try hitokoto.errorBody(gpa, "count must be a positive integer");
            defer gpa.free(b);
            return respondJson(req, .bad_request, b);
        };
        if (count == 0 or count > max_batch_count) {
            const b = try hitokoto.errorBody(gpa, "count must be between 1 and 1000");
            defer gpa.free(b);
            return respondJson(req, .bad_request, b);
        }

        const quotes = self.st.randomMany(gpa, count) catch |e| {
            if (e == error.OutOfMemory) return e;
            const b = try hitokoto.errorBody(gpa, "storage backend unavailable");
            defer gpa.free(b);
            return respondJson(req, .internal_server_error, b);
        };
        defer {
            for (quotes) |q| q.deinit(gpa);
            gpa.free(quotes);
        }

        const body = try hitokoto.jsonArrayBody(gpa, quotes);
        defer gpa.free(body);
        return respondJson(req, .ok, body);
    }
};

/// `/extra/batch/:count` 的上限。见 `handleExtraBatch` 顶部注释——这不是
/// 随手挑的保守数字，是"用户输入直接决定 Redis 命令与分配规模"这条暴露面
/// 唯一的护栏。
const max_batch_count: usize = 1000;

/// 按脚本顺序回复的假 Redis。每次收到一条命令就吐出脚本里的下一段。
///
/// 额外记录收到的字节（`received`），跟 store.zig / redis/client.zig 里的
/// FakeServer 同一个用途：不光要验证响应状态码，还要能钉住发给 Redis 的
/// 命令参数本身（比如 min/max 有没有被换位）。
/// 脚本用完就主动关掉这条连接、回到 accept 等下一条：redis.Client 现在会在
/// 传输层失败（含 ProtocolError）之后自己重拨并重试一次，所以假 Redis 必须能
/// 接住第二条连接，否则重拨会挂在一个永远没人 accept 的半连接上，整个测试卡死。
/// 每条新连接都从头重放同一份 replies。
const FakeRedis = struct {
    listener: std.net.Server,
    thread: std.Thread,
    replies: []const []const u8,
    received: std.ArrayList(u8),
    gpa: std.mem.Allocator,
    shutdown: std.atomic.Value(bool),
    stopped: bool,

    fn serve(self: *FakeRedis) void {
        while (true) {
            const conn = self.listener.accept() catch return;
            defer conn.stream.close();
            if (self.shutdown.load(.acquire)) return;
            var buf: [8192]u8 = undefined;
            var i: usize = 0;
            while (i < self.replies.len) {
                const n = conn.stream.read(&buf) catch break;
                if (n == 0) break;
                self.received.appendSlice(self.gpa, buf[0..n]) catch break;
                conn.stream.writeAll(self.replies[i]) catch break;
                i += 1;
            }
        }
    }

    fn start(gpa: std.mem.Allocator, replies: []const []const u8) !*FakeRedis {
        const self = try gpa.create(FakeRedis);
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        self.* = .{
            .listener = try addr.listen(.{ .reuse_address = true }),
            .thread = undefined,
            .replies = replies,
            .received = .empty,
            .gpa = gpa,
            .shutdown = .init(false),
            .stopped = false,
        };
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    /// 只负责停服务线程 + 关监听，幂等（可以显式调用一次拿到稳定的 `received`
    /// 之后，再让 defer 里兜底的第二次调用变成空操作）。`received` 的释放
    /// 和结构体本身的销毁交给 `destroy`，这样调用方可以在 stop() 之后、
    /// destroy() 之前安全读取 received.items。
    ///
    /// 服务线程现在是个 accept 循环，停的时候多半正卡在 accept() 上。直接
    /// listener.deinit() 关掉监听 fd 会让阻塞中的 accept 拿到 EBADF，而
    /// std.posix.accept 把 EBADF 当成 unreachable——会直接 panic。所以先立
    /// shutdown 标志、自己拨一条连接把 accept 叫醒，join 之后才关监听。
    fn stop(self: *FakeRedis) void {
        if (self.stopped) return;
        self.stopped = true;
        self.shutdown.store(true, .release);
        if (std.net.tcpConnectToAddress(self.listener.listen_address)) |s| {
            s.close();
        } else |_| {}
        self.thread.join();
        self.listener.deinit();
    }

    fn destroy(self: *FakeRedis, gpa: std.mem.Allocator) void {
        self.received.deinit(gpa);
        gpa.destroy(self);
    }
};

fn hgetallReply() []const u8 {
    return "*24\r\n" ++
        "$2\r\nid\r\n$2\r\n42\r\n" ++
        "$4\r\nuuid\r\n$36\r\n550e8400-e29b-41d4-a716-446655440000\r\n" ++
        "$8\r\nhitokoto\r\n$21\r\n今天也是好天气\r\n" ++
        "$4\r\ntype\r\n$1\r\ng\r\n" ++
        "$4\r\nfrom\r\n$9\r\n测试群\r\n" ++
        "$8\r\nfrom_who\r\n$6\r\n小明\r\n" ++
        "$7\r\ncreator\r\n$6\r\nHikari\r\n" ++
        "$10\r\ncreated_at\r\n$10\r\n1700000000\r\n" ++
        "$6\r\nlength\r\n$1\r\n7\r\n" ++
        "$10\r\nmessage_id\r\n$5\r\n12345\r\n" ++
        "$8\r\ngroup_id\r\n$3\r\n999\r\n" ++
        "$7\r\nuser_id\r\n$5\r\n10001\r\n";
}

/// store.zig 的 fetchById 现在在每次 HGETALL 之后紧跟着发一条 `MGET
/// hikari:username:{id} hikari:groupname:{id}`（resolveDisplayNames，改名
/// 覆盖/回退旧值）。这里的测试只关心 HTTP 层的路由/状态码/响应体，不关心
/// 改名覆盖本身（那在 store.zig 单独测），所以统一喂一对 nil，让内容退回
/// hash 里的值，测试原有的断言不用跟着改。
const mget_nil_reply = "*2\r\n$-1\r\n$-1\r\n";

const Harness = struct {
    fake: *FakeRedis,
    client: redis.Client,
    st: store.Store,
    srv: Server,
    thread: std.Thread,
    gpa: std.mem.Allocator,
};

fn startHarness(gpa: std.mem.Allocator, replies: []const []const u8) !*Harness {
    const h = try gpa.create(Harness);
    h.gpa = gpa;
    h.fake = try FakeRedis.start(gpa, replies);
    h.client = try redis.Client.connect(gpa, "127.0.0.1", h.fake.listener.listen_address.getPort(), null, 0);
    h.st = store.Store.init(gpa, &h.client);
    h.srv = try Server.listen(gpa, &h.st, "127.0.0.1", 0);
    h.thread = try std.Thread.spawn(.{}, Server.serveOnce, .{&h.srv});
    return h;
}

fn stopHarness(h: *Harness) void {
    h.thread.join();
    h.srv.deinit();
    h.client.deinit();
    h.fake.stop();
    h.fake.destroy(h.gpa);
    h.gpa.destroy(h);
}

fn request(gpa: std.mem.Allocator, method: std.http.Method, port: u16, path: []const u8, out: *std.Io.Writer.Allocating) !std.http.Status {
    var client: std.http.Client = .{ .allocator = gpa };
    defer client.deinit();
    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}{s}", .{ port, path });
    defer gpa.free(url);
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .response_writer = &out.writer,
    });
    return res.status;
}

fn get(gpa: std.mem.Allocator, port: u16, path: []const u8, out: *std.Io.Writer.Allocating) !std.http.Status {
    return request(gpa, .GET, port, path, out);
}

/// 用裸 socket 发一段原样的 HTTP 请求文本，读回整段响应原文（状态行 + 响应头 +
/// 响应体）。std.http.Client.fetch 只把响应体交出来，验不了 `connection: close`
/// 这类响应头。服务端处理完就关连接，所以读到 EOF 即可。
fn rawRequest(gpa: std.mem.Allocator, port: u16, request_text: []const u8) ![]u8 {
    const addr = try std.net.Address.parseIp("127.0.0.1", port);
    const sock = try std.net.tcpConnectToAddress(addr);
    defer sock.close();
    try sock.writeAll(request_text);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try sock.read(&buf);
        if (n == 0) break;
        try out.appendSlice(gpa, buf[0..n]);
    }
    return out.toOwnedSlice(gpa);
}

test "200 响应带 connection: close —— 宣称的行为跟真的会关连接一致" {
    const gpa = std.testing.allocator;
    const replies = [_][]const u8{ "$5\r\n12345\r\n", hgetallReply(), mget_nil_reply };
    const h = try startHarness(gpa, &replies);
    defer stopHarness(h);

    const raw = try rawRequest(gpa, h.srv.port(), "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
    defer gpa.free(raw);

    // serveOnce 的 `defer conn.stream.close()` 无论如何都会关掉这条连接。
    // req.respond 默认 keep_alive=true 时不发 connection 头，带连接池的客户端
    // 会把这条已经死掉的 socket 留着复用，下一个请求撞 EOF。
    try std.testing.expect(std.mem.indexOf(u8, raw, " 200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "connection: close\r\n") != null);
}

test "错误响应（404）同样带 connection: close" {
    const gpa = std.testing.allocator;
    const h = try startHarness(gpa, &[_][]const u8{});
    defer stopHarness(h);

    const raw = try rawRequest(gpa, h.srv.port(), "GET /nope HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
    defer gpa.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, " 404 Not Found") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "connection: close\r\n") != null);
}

test "静默客户端撞上接收超时，serveOnce 出错返回而不是永久卡住整个服务" {
    const gpa = std.testing.allocator;
    // 走不到 store，所以假 Redis 不需要任何脚本。
    const fake = try FakeRedis.start(gpa, &[_][]const u8{});
    defer {
        fake.stop();
        fake.destroy(gpa);
    }
    var client = try redis.Client.connect(gpa, "127.0.0.1", fake.listener.listen_address.getPort(), null, 0);
    defer client.deinit();
    var st = store.Store.init(gpa, &client);

    var srv = try Server.listen(gpa, &st, "127.0.0.1", 0);
    defer srv.deinit();
    srv.recv_timeout_s = 1;

    // 连上来，一个字节都不发。没有 SO_RCVTIMEO 的话下面这行会永远不返回——
    // 这个服务是串行 accept 的，线上表现就是整个公开 API 被一条连接拖死。
    const sock = try std.net.tcpConnectToAddress(srv.listener.listen_address);
    defer sock.close();

    try std.testing.expectError(error.ReadFailed, srv.serveOnce());
}

test "GET / 返回 hitokoto JSON" {
    const gpa = std.testing.allocator;
    const replies = [_][]const u8{ "$5\r\n12345\r\n", hgetallReply(), mget_nil_reply };
    const h = try startHarness(gpa, &replies);
    defer stopHarness(h);

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    const status = try get(gpa, h.srv.port(), "/", &body);
    try std.testing.expectEqual(std.http.Status.ok, status);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("今天也是好天气", parsed.value.object.get("hitokoto").?.string);
}

test "GET /?encode=text 返回纯文本" {
    const gpa = std.testing.allocator;
    const replies = [_][]const u8{ "$5\r\n12345\r\n", hgetallReply(), mget_nil_reply };
    const h = try startHarness(gpa, &replies);
    defer stopHarness(h);

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    const status = try get(gpa, h.srv.port(), "/?encode=text", &body);
    try std.testing.expectEqual(std.http.Status.ok, status);
    try std.testing.expectEqualStrings("今天也是好天气", body.written());
}

test "库空时返回 404" {
    const gpa = std.testing.allocator;
    const replies = [_][]const u8{"$-1\r\n"};
    const h = try startHarness(gpa, &replies);
    defer stopHarness(h);

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    try std.testing.expectEqual(std.http.Status.not_found, try get(gpa, h.srv.port(), "/", &body));
}

test "charset=gbk 返回 400" {
    const gpa = std.testing.allocator;
    const replies = [_][]const u8{};
    const h = try startHarness(gpa, &replies);
    defer stopHarness(h);

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    try std.testing.expectEqual(std.http.Status.bad_request, try get(gpa, h.srv.port(), "/?charset=gbk", &body));
}

test "callback 非法字符返回 400（JSONP 注入防护）" {
    const gpa = std.testing.allocator;
    const replies = [_][]const u8{};
    const h = try startHarness(gpa, &replies);
    defer stopHarness(h);

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    try std.testing.expectEqual(std.http.Status.bad_request, try get(gpa, h.srv.port(), "/?callback=alert(1)", &body));
}

test "未知路径返回 404" {
    const gpa = std.testing.allocator;
    const replies = [_][]const u8{};
    const h = try startHarness(gpa, &replies);
    defer stopHarness(h);

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    try std.testing.expectEqual(std.http.Status.not_found, try get(gpa, h.srv.port(), "/nope", &body));
}

test "DELETE / 返回 405" {
    const gpa = std.testing.allocator;
    const replies = [_][]const u8{};
    const h = try startHarness(gpa, &replies);
    defer stopHarness(h);

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    try std.testing.expectEqual(
        std.http.Status.method_not_allowed,
        try request(gpa, .DELETE, h.srv.port(), "/", &body),
    );
}

test "DELETE 未知路径仍然是 404，不是 405（先按路径路由）" {
    const gpa = std.testing.allocator;
    const replies = [_][]const u8{};
    const h = try startHarness(gpa, &replies);
    defer stopHarness(h);

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    try std.testing.expectEqual(
        std.http.Status.not_found,
        try request(gpa, .DELETE, h.srv.port(), "/nope", &body),
    );
}

// ---------------------------------------------------------------------------
// min_length/max_length -> randomByLength 派发：之前完全没有测试从 HTTP 层
// 打到长度过滤这条分支的路径——如果 min/max 顺序在 handle() 里被换位，
// 或者“匹配为空”被误判成别的状态码，全套测试之前都不会亮红灯。

test "min_length/max_length 过滤后为空时返回 404（区别于「库整体为空」）" {
    const gpa = std.testing.allocator;
    // ZRANGEBYSCORE 回一个空数组：库不是空的，只是这个长度区间没有命中，
    // 跟前面「库空时返回 404」测的是同一个状态码、不同的成因——brief 把
    // 这两种情形明确列成了两个不同的场景，这里补上没覆盖到的那一个。
    const replies = [_][]const u8{"*0\r\n"};
    const h = try startHarness(gpa, &replies);
    defer stopHarness(h);

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    try std.testing.expectEqual(
        std.http.Status.not_found,
        try get(gpa, h.srv.port(), "/?min_length=5&max_length=10", &body),
    );
}

test "min_length/max_length 命中时返回 200，且发给 Redis 的 min/max 顺序正确" {
    const gpa = std.testing.allocator;
    const replies = [_][]const u8{ "*1\r\n$5\r\n12345\r\n", hgetallReply(), mget_nil_reply };
    const fake = try FakeRedis.start(gpa, &replies);
    defer {
        fake.stop();
        fake.destroy(gpa);
    }

    var client = try redis.Client.connect(gpa, "127.0.0.1", fake.listener.listen_address.getPort(), null, 0);
    defer client.deinit();
    var st = store.Store.init(gpa, &client);
    var srv = try Server.listen(gpa, &st, "127.0.0.1", 0);
    defer srv.deinit();
    const thread = try std.Thread.spawn(.{}, Server.serveOnce, .{&srv});

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    const status = try get(gpa, srv.port(), "/?min_length=3&max_length=20", &body);
    try std.testing.expectEqual(std.http.Status.ok, status);
    thread.join();

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("今天也是好天气", parsed.value.object.get("hitokoto").?.string);

    // 跟 store.zig 里 FakeServer 的测试同一个套路：先关掉真实 redis 客户端
    // 连接，让 FakeRedis 的读循环收到 EOF 退出，再 stop()（join 线程），
    // 之后 received 才是稳定、不会再变化、可以安全读取的状态。
    client.deinit();
    fake.stop();
    // 不能只分别查 "ZRANGEBYSCORE" / key / "$1\r\n3\r\n" / "$2\r\n20\r\n"
    // 这几个子串是否存在：min/max 被换位成 "... 20 3" 时，四段子串依然
    // 全部存在，只是相对顺序变了，四条独立的 indexOf 会全部通过，测不出
    // 换位。改成断言整条命令帧——命令名、key、min、max 的相对位置一起钉
    // 死在一个连续字节串里，换位会让这个字节串在整个流里都找不到。
    // 帧内容照抄 resp.encodeCommand 的编码格式：
    // "*{参数个数}\r\n" + 每个参数 "${长度}\r\n{内容}\r\n"，
    // 参数依次是 ZRANGEBYSCORE、key_bylen（"hikari:bylen"，12 字节）、
    // "3"（1 字节）、"20"（2 字节），共 4 个参数。
    try std.testing.expect(std.mem.indexOf(
        u8,
        fake.received.items,
        "*4\r\n$13\r\nZRANGEBYSCORE\r\n$12\r\nhikari:bylen\r\n$1\r\n3\r\n$2\r\n20\r\n",
    ) != null);
}

// ---------------------------------------------------------------------------
// Redis I/O/协议失败：跟“查询结果为空”（404）是完全不同的一类失败，
// 之前会被 handle() 里的裸 try 原样抛出 serveOnce，连接直接被摔断、
// 客户端连响应体都收不到。修复后应该是 500 + 跟 400/404 一致的 JSON 错误体。

test "Redis 返回协议错误时是 500 + JSON 错误体，而不是直接断连" {
    const gpa = std.testing.allocator;
    // "%1\r\n" 是 RESP 里未定义的类型前缀（Map 类型，这个最小客户端没实现），
    // resp.readValue 会在读到这一行的瞬间就返回 error.ProtocolError——
    // 不需要真的断开连接或者等超时，触发起来又快又稳定。
    const replies = [_][]const u8{"%1\r\n"};
    const h = try startHarness(gpa, &replies);
    defer stopHarness(h);

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    const status = try get(gpa, h.srv.port(), "/", &body);
    try std.testing.expectEqual(std.http.Status.internal_server_error, status);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body.written(), .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("message") != null);
}

// ---------------------------------------------------------------------------
// /extra/all 与 /extra/batch/:count —— 全量导出 / 允许重复的批量随机抽样。
// 两者都是自定义扩展，不认 `/` 的那套 encode/min_length/max_length/callback/
// select，JSON 数组只是每个元素跟 encode=json 单条对象同构。

fn hgetallReply2() []const u8 {
    return "*24\r\n" ++
        "$2\r\nid\r\n$2\r\n43\r\n" ++
        "$4\r\nuuid\r\n$36\r\n660e8400-e29b-41d4-a716-446655440001\r\n" ++
        "$8\r\nhitokoto\r\n$15\r\n第二条语录\r\n" ++
        "$4\r\ntype\r\n$1\r\ng\r\n" ++
        "$4\r\nfrom\r\n$9\r\n测试群\r\n" ++
        "$8\r\nfrom_who\r\n$6\r\n小红\r\n" ++
        "$7\r\ncreator\r\n$6\r\nHikari\r\n" ++
        "$10\r\ncreated_at\r\n$10\r\n1700000100\r\n" ++
        "$6\r\nlength\r\n$1\r\n5\r\n" ++
        "$10\r\nmessage_id\r\n$3\r\n999\r\n" ++
        "$8\r\ngroup_id\r\n$3\r\n999\r\n" ++
        "$7\r\nuser_id\r\n$5\r\n10002\r\n";
}

test "GET /extra/all 返回全部语录的 JSON 数组" {
    const gpa = std.testing.allocator;
    const smembers = "*2\r\n$5\r\n12345\r\n$3\r\n999\r\n";
    const replies = [_][]const u8{ smembers, hgetallReply(), mget_nil_reply, hgetallReply2(), mget_nil_reply };
    const h = try startHarness(gpa, &replies);
    defer stopHarness(h);

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    const status = try get(gpa, h.srv.port(), "/extra/all", &body);
    try std.testing.expectEqual(std.http.Status.ok, status);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body.written(), .{});
    defer parsed.deinit();
    const arr = parsed.value.array.items;
    try std.testing.expectEqual(@as(usize, 2), arr.len);
    try std.testing.expectEqualStrings("今天也是好天气", arr[0].object.get("hitokoto").?.string);
    try std.testing.expectEqualStrings("第二条语录", arr[1].object.get("hitokoto").?.string);
}

test "GET /extra/all 库空时返回 [] 而不是 404 —— 数组端点的\"没有\"是一个成功答案" {
    const gpa = std.testing.allocator;
    const replies = [_][]const u8{"*0\r\n"};
    const h = try startHarness(gpa, &replies);
    defer stopHarness(h);

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    const status = try get(gpa, h.srv.port(), "/extra/all", &body);
    try std.testing.expectEqual(std.http.Status.ok, status);
    try std.testing.expectEqualStrings("[]", body.written());
}

test "非 GET 请求 /extra/all 返回 405" {
    const gpa = std.testing.allocator;
    const h = try startHarness(gpa, &[_][]const u8{});
    defer stopHarness(h);

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    try std.testing.expectEqual(
        std.http.Status.method_not_allowed,
        try request(gpa, .DELETE, h.srv.port(), "/extra/all", &body),
    );
}

test "GET /extra/all 遇到 Redis 协议错误时是 500 + JSON 错误体，而不是断连" {
    const gpa = std.testing.allocator;
    const replies = [_][]const u8{"%1\r\n"};
    const h = try startHarness(gpa, &replies);
    defer stopHarness(h);

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    const status = try get(gpa, h.srv.port(), "/extra/all", &body);
    try std.testing.expectEqual(std.http.Status.internal_server_error, status);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body.written(), .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("message") != null);
}

test "GET /extra/batch/:count 用 SRANDMEMBER 的负数形式取样（允许重复），命令帧钉死符号" {
    const gpa = std.testing.allocator;
    // 同一个 id 出现两次：真实 Redis 的负数形式允许重复，这里直接在脚本层
    // 模拟"抽中了同一条两次"，顺带验证 handleExtraBatch 不会偷偷去重。
    const srandmember = "*2\r\n$5\r\n12345\r\n$5\r\n12345\r\n";
    const replies = [_][]const u8{ srandmember, hgetallReply(), mget_nil_reply, hgetallReply(), mget_nil_reply };
    const fake = try FakeRedis.start(gpa, &replies);
    defer {
        fake.stop();
        fake.destroy(gpa);
    }
    var client = try redis.Client.connect(gpa, "127.0.0.1", fake.listener.listen_address.getPort(), null, 0);
    defer client.deinit();
    var st = store.Store.init(gpa, &client);
    var srv = try Server.listen(gpa, &st, "127.0.0.1", 0);
    defer srv.deinit();
    const thread = try std.Thread.spawn(.{}, Server.serveOnce, .{&srv});

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    const status = try get(gpa, srv.port(), "/extra/batch/2", &body);
    try std.testing.expectEqual(std.http.Status.ok, status);
    thread.join();

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);

    client.deinit();
    fake.stop();
    // 符号是这条命令唯一容易搞反、又不会被普通子串检查抓到的地方：搞反成
    // 正数形式会让 Redis 走去重语义，在 count 超过库大小时还会静默截断到
    // 库大小——两种情况普通测试都可能"恰好"通过。这里钉死完整帧：命令名、
    // key、"-2" 三段的相对顺序与内容一起验证。
    try std.testing.expect(std.mem.indexOf(
        u8,
        fake.received.items,
        "*3\r\n$11\r\nSRANDMEMBER\r\n$12\r\nhikari:index\r\n$2\r\n-2\r\n",
    ) != null);
}

test "count 上限：1000 放行到 store 层（命令帧钉死 -1000），1001 未接触 Redis 就 400" {
    const gpa = std.testing.allocator;
    {
        // SRANDMEMBER 对空库回空数组，不论请求的 count 是多少——用这个
        // 空库回复反过来验证 1000 确实穿过了校验、命令确实发出去了。
        const replies = [_][]const u8{"*0\r\n"};
        const fake = try FakeRedis.start(gpa, &replies);
        defer {
            fake.stop();
            fake.destroy(gpa);
        }
        var client = try redis.Client.connect(gpa, "127.0.0.1", fake.listener.listen_address.getPort(), null, 0);
        defer client.deinit();
        var st = store.Store.init(gpa, &client);
        var srv = try Server.listen(gpa, &st, "127.0.0.1", 0);
        defer srv.deinit();
        const thread = try std.Thread.spawn(.{}, Server.serveOnce, .{&srv});

        var body: std.Io.Writer.Allocating = .init(gpa);
        defer body.deinit();
        const status = try get(gpa, srv.port(), "/extra/batch/1000", &body);
        try std.testing.expectEqual(std.http.Status.ok, status);
        thread.join();
        try std.testing.expectEqualStrings("[]", body.written());

        client.deinit();
        fake.stop();
        try std.testing.expect(std.mem.indexOf(u8, fake.received.items, "$5\r\n-1000\r\n") != null);
    }
    {
        // 1001 一步都不该碰 Redis：给一个空脚本，如果实现错误地先发了命令
        // 再校验，这里会因为读不到回复而超时/失败，而不是安静地凑巧通过。
        const h = try startHarness(gpa, &[_][]const u8{});
        defer stopHarness(h);
        var body: std.Io.Writer.Allocating = .init(gpa);
        defer body.deinit();
        try std.testing.expectEqual(
            std.http.Status.bad_request,
            try get(gpa, h.srv.port(), "/extra/batch/1001", &body),
        );
    }
}

test "count 为 0、负数或非数字 -> 400" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "/extra/batch/0", "/extra/batch/-1", "/extra/batch/abc" }) |path| {
        const h = try startHarness(gpa, &[_][]const u8{});
        defer stopHarness(h);
        var body: std.Io.Writer.Allocating = .init(gpa);
        defer body.deinit();
        try std.testing.expectEqual(std.http.Status.bad_request, try get(gpa, h.srv.port(), path, &body));
    }
}

test "畸形路径：/extra/batch（缺 count）与 /extra/batch/1/2（多余路径段）是 404，/extra/allx 也是 404" {
    const gpa = std.testing.allocator;
    // 这两个路径结构上都不是 "/extra/batch/:count" 这一条路由能表达的
    // 形状——跟 "/nope" 是同一类："这个资源压根不存在"，不是"资源存在但
    // 参数有误"。"/extra/allx" 同理：它既不等于 "/extra/all"，也不是
    // "/extra/batch/" 前缀，落进通用 404。
    for ([_][]const u8{ "/extra/batch", "/extra/batch/1/2", "/extra/allx" }) |path| {
        const h = try startHarness(gpa, &[_][]const u8{});
        defer stopHarness(h);
        var body: std.Io.Writer.Allocating = .init(gpa);
        defer body.deinit();
        try std.testing.expectEqual(std.http.Status.not_found, try get(gpa, h.srv.port(), path, &body));
    }
}

test "/extra/batch/（空 count 段）命中路由但 count 校验失败 -> 400，不是 404" {
    const gpa = std.testing.allocator;
    // 跟上一条测试里 "/extra/batch"（无尾随斜杠）区分开：这里的路径结构
    // 是 "/extra/batch/" + 空字符串，仍然落进 "/extra/batch/:count" 这条
    // 路由——只是 count 这一段是空的，校验时按"非数字"处理，跟
    // "/extra/batch/abc" 走的是同一条错误路径。
    const h = try startHarness(gpa, &[_][]const u8{});
    defer stopHarness(h);
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    try std.testing.expectEqual(
        std.http.Status.bad_request,
        try get(gpa, h.srv.port(), "/extra/batch/", &body),
    );
}

test "非 GET 请求 /extra/batch/:count 返回 405" {
    const gpa = std.testing.allocator;
    const h = try startHarness(gpa, &[_][]const u8{});
    defer stopHarness(h);

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    try std.testing.expectEqual(
        std.http.Status.method_not_allowed,
        try request(gpa, .DELETE, h.srv.port(), "/extra/batch/5", &body),
    );
}

test "GET /extra/batch/:count 遇到 Redis 协议错误时是 500 + JSON 错误体，而不是断连" {
    const gpa = std.testing.allocator;
    const replies = [_][]const u8{"%1\r\n"};
    const h = try startHarness(gpa, &replies);
    defer stopHarness(h);

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    const status = try get(gpa, h.srv.port(), "/extra/batch/5", &body);
    try std.testing.expectEqual(std.http.Status.internal_server_error, status);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body.written(), .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("message") != null);
}
