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

    /// 供测试单步驱动：只 accept 一次、处理一个请求就返回。
    pub fn serveOnce(self: *Server) !void {
        const conn = try self.listener.accept();
        defer conn.stream.close();

        var rbuf: [8192]u8 = undefined;
        var wbuf: [8192]u8 = undefined;
        var sr = conn.stream.reader(&rbuf);
        var sw = conn.stream.writer(&wbuf);
        // reader 是函数调用，writer 是字段取址 —— 顺序写反编不过。
        var http_server = std.http.Server.init(sr.interface(), &sw.interface);

        var req = try http_server.receiveHead();
        try self.handle(&req);
    }

    fn respondJson(req: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
        try req.respond(body, .{
            .status = status,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json; charset=utf-8" }},
        });
    }

    fn handle(self: *Server, req: *std.http.Server.Request) !void {
        const gpa = self.gpa;
        const target = req.head.target;

        // 先按路径路由，再看方法：未知路径一律 404（不论方法），只有落在 "/"
        // 上、方法又不是 GET 时才是 405。先判方法会让 "POST /nope" 之类的
        // 请求错误地报出 405（意味着 "/nope" 上其实存在别的方法），而不是
        // 404（这个路径压根不存在）——两者语义不同，顺序不能反。
        const path_end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
        if (!std.mem.eql(u8, target[0..path_end], "/")) {
            const b = try hitokoto.errorBody(gpa, "not found");
            defer gpa.free(b);
            return respondJson(req, .not_found, b);
        }

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

        try req.respond(rendered.body, .{
            .status = .ok,
            .extra_headers = &.{.{ .name = "content-type", .value = rendered.content_type }},
        });
    }
};

/// 按脚本顺序回复的假 Redis。每次收到一条命令就吐出脚本里的下一段。
///
/// 额外记录收到的字节（`received`），跟 store.zig / redis/client.zig 里的
/// FakeServer 同一个用途：不光要验证响应状态码，还要能钉住发给 Redis 的
/// 命令参数本身（比如 min/max 有没有被换位）。
const FakeRedis = struct {
    listener: std.net.Server,
    thread: std.Thread,
    replies: []const []const u8,
    received: std.ArrayList(u8),
    gpa: std.mem.Allocator,
    stopped: bool,

    fn serve(self: *FakeRedis) void {
        const conn = self.listener.accept() catch return;
        defer conn.stream.close();
        var buf: [8192]u8 = undefined;
        var i: usize = 0;
        while (i < self.replies.len) {
            const n = conn.stream.read(&buf) catch return;
            if (n == 0) return;
            self.received.appendSlice(self.gpa, buf[0..n]) catch return;
            conn.stream.writeAll(self.replies[i]) catch return;
            i += 1;
        }
        while (true) {
            const n = conn.stream.read(&buf) catch return;
            if (n == 0) return;
            self.received.appendSlice(self.gpa, buf[0..n]) catch return;
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
            .stopped = false,
        };
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    /// 只负责关监听 + join，幂等（可以显式调用一次拿到稳定的 `received`
    /// 之后，再让 defer 里兜底的第二次调用变成空操作）。`received` 的释放
    /// 和结构体本身的销毁交给 `destroy`，这样调用方可以在 stop() 之后、
    /// destroy() 之前安全读取 received.items。
    fn stop(self: *FakeRedis) void {
        if (self.stopped) return;
        self.stopped = true;
        self.listener.deinit();
        self.thread.join();
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

test "GET / 返回 hitokoto JSON" {
    const gpa = std.testing.allocator;
    const replies = [_][]const u8{ "$5\r\n12345\r\n", hgetallReply() };
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
    const replies = [_][]const u8{ "$5\r\n12345\r\n", hgetallReply() };
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
    const replies = [_][]const u8{ "*1\r\n$5\r\n12345\r\n", hgetallReply() };
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
    try std.testing.expect(std.mem.indexOf(u8, fake.received.items, "ZRANGEBYSCORE") != null);
    // 不能只查裸的 "3" / "20" 子串：那两个数字前缀恰好也会出现在 RESP 里
    // 到处都是的 bulk 长度头（比如 "$3\r\n..."）里，裸子串匹配永远为真，
    // 测不出 min/max 是不是真的按正确顺序发出去了。改成匹配 min/max 各自
    // 完整的 RESP bulk 编码——这正是能把 min/max 换位这种 bug 测出来的地方。
    try std.testing.expect(std.mem.indexOf(u8, fake.received.items, "$1\r\n3\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.received.items, "$2\r\n20\r\n") != null);
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
