const std = @import("std");
const store = @import("../store.zig");
const redis = @import("../redis/client.zig");
const hitokoto = @import("hitokoto.zig");

pub const Server = struct {
    gpa: std.mem.Allocator,
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
            try self.st.randomByLength(gpa, query.min_length orelse 0, query.max_length orelse std.math.maxInt(u32))
        else
            try self.st.randomAny(gpa);

        const quote = maybe orelse {
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
const FakeRedis = struct {
    listener: std.net.Server,
    thread: std.Thread,
    replies: []const []const u8,

    fn serve(self: *FakeRedis) void {
        const conn = self.listener.accept() catch return;
        defer conn.stream.close();
        var buf: [8192]u8 = undefined;
        var i: usize = 0;
        while (i < self.replies.len) {
            const n = conn.stream.read(&buf) catch return;
            if (n == 0) return;
            conn.stream.writeAll(self.replies[i]) catch return;
            i += 1;
        }
        while (true) {
            const n = conn.stream.read(&buf) catch return;
            if (n == 0) return;
        }
    }

    fn start(gpa: std.mem.Allocator, replies: []const []const u8) !*FakeRedis {
        const self = try gpa.create(FakeRedis);
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        self.* = .{
            .listener = try addr.listen(.{ .reuse_address = true }),
            .thread = undefined,
            .replies = replies,
        };
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    fn stop(self: *FakeRedis, gpa: std.mem.Allocator) void {
        self.listener.deinit();
        self.thread.join();
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
    h.fake.stop(h.gpa);
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
