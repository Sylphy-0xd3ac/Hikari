const std = @import("std");
const resp = @import("resp.zig");

pub const Error = error{
    RedisError,
    ProtocolError,
    ConnectionFailed,
    OutOfMemory,
    ReadFailed,
    WriteFailed,
    EndOfStream,
    StreamTooLong,
};

pub const Client = struct {
    gpa: std.mem.Allocator,
    stream: std.net.Stream,
    read_buf: []u8,
    write_buf: []u8,
    reader: std.net.Stream.Reader,
    writer: std.net.Stream.Writer,
    closed: bool,

    pub fn connect(
        gpa: std.mem.Allocator,
        host: []const u8,
        port: u16,
        password: ?[]const u8,
        db: u32,
    ) Error!Client {
        const stream = std.net.tcpConnectToHost(gpa, host, port) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ConnectionFailed,
        };
        errdefer stream.close();

        const read_buf = try gpa.alloc(u8, 64 * 1024);
        errdefer gpa.free(read_buf);
        const write_buf = try gpa.alloc(u8, 16 * 1024);
        errdefer gpa.free(write_buf);

        var self: Client = .{
            .gpa = gpa,
            .stream = stream,
            .read_buf = read_buf,
            .write_buf = write_buf,
            .reader = stream.reader(read_buf),
            .writer = stream.writer(write_buf),
            .closed = false,
        };

        if (password) |p| {
            try self.commandOk(&.{ "AUTH", p });
        }
        if (db != 0) {
            var nb: [16]u8 = undefined;
            const dbs = std.fmt.bufPrint(&nb, "{d}", .{db}) catch unreachable;
            try self.commandOk(&.{ "SELECT", dbs });
        }
        return self;
    }

    pub fn deinit(self: *Client) void {
        if (self.closed) return;
        self.closed = true;
        self.stream.close();
        self.gpa.free(self.read_buf);
        self.gpa.free(self.write_buf);
    }

    pub fn command(self: *Client, args: []const []const u8) Error!resp.Value {
        if (self.closed) return error.ConnectionFailed;
        const payload = try resp.encodeCommand(self.gpa, args);
        defer self.gpa.free(payload);

        const w: *std.Io.Writer = &self.writer.interface;
        w.writeAll(payload) catch return error.WriteFailed;
        w.flush() catch return error.WriteFailed;

        return resp.readValue(self.gpa, self.reader.interface());
    }

    pub fn commandOk(self: *Client, args: []const []const u8) Error!void {
        const v = try self.command(args);
        defer v.deinit(self.gpa);
        if (v == .err) return error.RedisError;
    }

    pub fn commandInt(self: *Client, args: []const []const u8) Error!i64 {
        const v = try self.command(args);
        defer v.deinit(self.gpa);
        return switch (v) {
            .int => |i| i,
            .err => error.RedisError,
            else => error.ProtocolError,
        };
    }
};

const FakeServer = struct {
    listener: std.net.Server,
    thread: std.Thread,
    script: []const u8,
    received: std.ArrayList(u8),
    gpa: std.mem.Allocator,
    stopped: bool,

    fn serve(self: *FakeServer) void {
        const conn = self.listener.accept() catch return;
        defer conn.stream.close();
        var buf: [4096]u8 = undefined;
        // 先把脚本全部写出去，客户端按需读取
        _ = conn.stream.writeAll(self.script) catch return;
        // 读走客户端发来的字节，避免它写阻塞
        while (true) {
            const n = conn.stream.read(&buf) catch return;
            if (n == 0) return;
            self.received.appendSlice(self.gpa, buf[0..n]) catch return;
        }
    }

    fn start(gpa: std.mem.Allocator, script: []const u8) !*FakeServer {
        const self = try gpa.create(FakeServer);
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        self.* = .{
            .listener = try addr.listen(.{ .reuse_address = true }),
            .thread = undefined,
            .script = script,
            .received = .empty,
            .gpa = gpa,
            .stopped = false,
        };
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    fn port(self: *FakeServer) u16 {
        return self.listener.listen_address.getPort();
    }

    /// 只负责关监听与 join。`received` 的释放与 destroy 交给调用方，
    /// 这样测试可以在 join 之后安全读取 `received`。幂等：测试里既会显式调用一次，
    /// 又会在 defer 里再调一次（用来兜住失败路径），第二次必须是空操作，
    /// 否则会重复 join 已结束的线程、重复关闭监听 fd。
    fn stop(self: *FakeServer) void {
        if (self.stopped) return;
        self.stopped = true;
        self.listener.deinit();
        self.thread.join();
    }
};

test "connect 不带密码不带 db 时不发 AUTH / SELECT" {
    const gpa = std.testing.allocator;
    const srv = try FakeServer.start(gpa, "+PONG\r\n");
    defer {
        srv.stop();
        srv.received.deinit(gpa);
        gpa.destroy(srv);
    }

    var c = try Client.connect(gpa, "127.0.0.1", srv.port(), null, 0);
    defer c.deinit();

    const v = try c.command(&.{"PING"});
    defer v.deinit(gpa);
    try std.testing.expectEqualStrings("PONG", v.simple);
}

test "connect 带密码与 db 时先发 AUTH 再发 SELECT" {
    const gpa = std.testing.allocator;
    // 依次回应 AUTH、SELECT、PING
    const srv = try FakeServer.start(gpa, "+OK\r\n+OK\r\n+PONG\r\n");
    // stop() 是幂等的：happy path 下面会显式调用一次，这里的 defer 只在
    // 提前失败（connect/command/expect 出错）时才真正生效，保证线程一定
    // 被 join、fd 一定被关，不会在失败路径上残留一个还在跑的后台线程
    // 或者卡在 accept() 里挂起整个测试。
    defer {
        srv.stop();
        srv.received.deinit(gpa);
        gpa.destroy(srv);
    }

    var c = try Client.connect(gpa, "127.0.0.1", srv.port(), "s3cret", 2);
    defer c.deinit();
    const v = try c.command(&.{"PING"});
    defer v.deinit(gpa);
    try std.testing.expectEqualStrings("PONG", v.simple);

    // FakeServer 在 accept 后立刻把整段脚本写出去，不等待读到任何字节，
    // 所以客户端三次往返（AUTH/SELECT/PING）完全可能只凭内核收发缓冲区里
    // 已经就位的数据完成，跟后台线程是否已经执行过一次 read() 毫无关系。
    // 这意味着在这里直接读 srv.received 是和后台线程的未同步竞争。
    // 和下面「command 把参数编码成 RESP 数组发出去」测试一样，
    // 必须先关闭客户端连接让 fake server 的读循环收到 EOF 退出，
    // 再 stop()（join 线程），之后 received 才稳定可读。
    c.deinit();
    srv.stop();

    // 客户端确实发出了 AUTH 与 SELECT
    try std.testing.expect(std.mem.indexOf(u8, srv.received.items, "AUTH") != null);
    try std.testing.expect(std.mem.indexOf(u8, srv.received.items, "s3cret") != null);
    try std.testing.expect(std.mem.indexOf(u8, srv.received.items, "SELECT") != null);
}

test "commandInt 读整数回复" {
    const gpa = std.testing.allocator;
    const srv = try FakeServer.start(gpa, ":7\r\n");
    defer {
        srv.stop();
        srv.received.deinit(gpa);
        gpa.destroy(srv);
    }
    var c = try Client.connect(gpa, "127.0.0.1", srv.port(), null, 0);
    defer c.deinit();
    try std.testing.expectEqual(@as(i64, 7), try c.commandInt(&.{ "INCR", "k" }));
}

test "服务端返回 -ERR 时转成 error.RedisError" {
    const gpa = std.testing.allocator;
    const srv = try FakeServer.start(gpa, "-ERR nope\r\n");
    defer {
        srv.stop();
        srv.received.deinit(gpa);
        gpa.destroy(srv);
    }
    var c = try Client.connect(gpa, "127.0.0.1", srv.port(), null, 0);
    defer c.deinit();
    try std.testing.expectError(error.RedisError, c.commandOk(&.{ "SET", "k", "v" }));
}

test "command 把参数编码成 RESP 数组发出去" {
    const gpa = std.testing.allocator;
    const srv = try FakeServer.start(gpa, "+OK\r\n");
    // stop() 是幂等的：happy path 下面会显式调用一次，这里的 defer 只在
    // 提前失败（connect/commandOk/expect 出错）时才真正生效，保证线程一定
    // 被 join、fd 一定被关。
    defer {
        srv.stop();
        srv.received.deinit(gpa);
        gpa.destroy(srv);
    }

    var c = try Client.connect(gpa, "127.0.0.1", srv.port(), null, 0);
    defer c.deinit();
    try c.commandOk(&.{ "SET", "key", "val" });

    // 先关客户端连接让 fake server 的读循环收到 EOF 退出，
    // stop() 关监听并 join，之后 received 才稳定可读。
    c.deinit();
    srv.stop();

    try std.testing.expectEqualStrings("*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$3\r\nval\r\n", srv.received.items);
}
