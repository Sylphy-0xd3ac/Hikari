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

/// 传输层失败：连接本身不可信了（socket 断了，或者读缓冲里可能卡着半条回复）。
/// 跟服务端正常回的 -ERR（RedisError）、以及分配失败（OutOfMemory）严格区分开：
/// 只有这一类才触发拆连接重拨。
fn isTransportFailure(e: Error) bool {
    return switch (e) {
        error.WriteFailed,
        error.ReadFailed,
        error.EndOfStream,
        error.StreamTooLong,
        error.ProtocolError,
        => true,
        else => false,
    };
}

pub const Client = struct {
    gpa: std.mem.Allocator,
    stream: std.net.Stream,
    read_buf: []u8,
    write_buf: []u8,
    reader: std.net.Stream.Reader,
    writer: std.net.Stream.Writer,
    /// 当前这条 socket 是否活着。false 表示需要重拨——可能是刚被传输层错误拆掉，
    /// 也可能是上一次重拨没成功。跟 `dead` 分开：连接断了是可恢复状态。
    connected: bool,
    /// deinit 过了：缓冲区与连接参数都已释放，此后任何命令一律 ConnectionFailed，
    /// 绝不重拨。deinit 幂等靠的就是这个标志。
    dead: bool,
    // ---- 重拨需要的连接参数。host/password 都是自己复制一份持有的，
    // 不借调用方的内存：Client 的寿命就是进程寿命，不该对配置对象的生命周期
    // 做任何假设。
    host: []u8,
    port: u16,
    password: ?[]u8,
    db: u32,

    pub fn connect(
        gpa: std.mem.Allocator,
        host: []const u8,
        port: u16,
        password: ?[]const u8,
        db: u32,
    ) Error!Client {
        const host_dup = gpa.dupe(u8, host) catch return error.OutOfMemory;
        errdefer gpa.free(host_dup);
        const password_dup: ?[]u8 = if (password) |p|
            (gpa.dupe(u8, p) catch return error.OutOfMemory)
        else
            null;
        errdefer if (password_dup) |p| gpa.free(p);

        const read_buf = try gpa.alloc(u8, 64 * 1024);
        errdefer gpa.free(read_buf);
        const write_buf = try gpa.alloc(u8, 16 * 1024);
        errdefer gpa.free(write_buf);

        var self: Client = .{
            .gpa = gpa,
            .stream = undefined,
            .read_buf = read_buf,
            .write_buf = write_buf,
            .reader = undefined,
            .writer = undefined,
            .connected = false,
            .dead = false,
            .host = host_dup,
            .port = port,
            .password = password_dup,
            .db = db,
        };
        try self.dial();
        return self;
    }

    /// 拨一条新连接并重做握手。要求当前没有活连接（调用方先 teardown）。
    ///
    /// reader/writer 在这里整个重建：它们的 seek/end 归零，等于把上一条连接
    /// 残留在 read_buf 里的半条回复彻底丢掉。只关 socket 而复用旧 reader 的话，
    /// ProtocolError 之后缓冲区里剩下的那几个字节会被当成新连接的第一条回复读
    /// 出来，从此每一条回复都错位一格——store.exists() 会拿着别人的答案回答自己
    /// 的问题。这是静默的数据错误，不是可见的失败，所以必须整条丢弃。
    fn dial(self: *Client) Error!void {
        std.debug.assert(!self.connected);
        const stream = std.net.tcpConnectToHost(self.gpa, self.host, self.port) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ConnectionFailed,
        };
        errdefer stream.close();

        self.stream = stream;
        self.reader = stream.reader(self.read_buf);
        self.writer = stream.writer(self.write_buf);
        self.connected = true;
        errdefer self.connected = false;

        if (self.password) |p| {
            try self.roundTripOk(&.{ "AUTH", p });
        }
        if (self.db != 0) {
            var nb: [16]u8 = undefined;
            const dbs = std.fmt.bufPrint(&nb, "{d}", .{self.db}) catch unreachable;
            try self.roundTripOk(&.{ "SELECT", dbs });
        }
    }

    /// 关掉当前连接但保留对象本身（缓冲区、连接参数都还在），下一条命令会重拨。
    fn teardown(self: *Client) void {
        if (!self.connected) return;
        self.connected = false;
        self.stream.close();
    }

    /// 发一条已编码好的命令并读回一条回复。不做任何重连/重试——dial 里的握手
    /// 与 command 里的两次尝试都走它，避免 command -> dial -> command 的递归。
    fn roundTrip(self: *Client, payload: []const u8) Error!resp.Value {
        const w: *std.Io.Writer = &self.writer.interface;
        w.writeAll(payload) catch return error.WriteFailed;
        w.flush() catch return error.WriteFailed;
        return resp.readValue(self.gpa, self.reader.interface());
    }

    fn roundTripOk(self: *Client, args: []const []const u8) Error!void {
        const payload = try resp.encodeCommand(self.gpa, args);
        defer self.gpa.free(payload);
        const v = try self.roundTrip(payload);
        defer v.deinit(self.gpa);
        if (v == .err) return error.RedisError;
    }

    pub fn deinit(self: *Client) void {
        if (self.dead) return;
        self.dead = true;
        self.teardown();
        self.gpa.free(self.read_buf);
        self.gpa.free(self.write_buf);
        self.gpa.free(self.host);
        if (self.password) |p| self.gpa.free(p);
    }

    /// 发一条命令。传输层失败时拆掉连接、重拨、**只重试一次**。
    ///
    /// 为什么只重试一次：第一次尝试失败在读阶段时，这条命令可能已经被服务端
    /// 执行过了。无限重试会把它反复重放。本仓库里唯一非幂等的命令是
    /// `INCR hikari:seq`——重放一次只是白烧一个 id（id 允许有空洞），
    /// 而 HSET/SADD/ZADD/ZREM/SREM/DEL/SET 都是幂等的，读命令更无所谓。
    /// 用"最多重放一次"换"Redis 重启后进程还能自己活过来"是划算的；
    /// 无限重试换来的额外可用性不足以抵消重放次数不可控的风险，所以第二次
    /// 失败就如实交给调用方，由它决定是报 Failed 行还是回 500。
    pub fn command(self: *Client, args: []const []const u8) Error!resp.Value {
        if (self.dead) return error.ConnectionFailed;
        const payload = try resp.encodeCommand(self.gpa, args);
        defer self.gpa.free(payload);

        // 上一次重拨没成功（或者上一条命令刚把连接拆掉）：先补一次拨号。
        // 每次调用最多拨一次，不成功就把错误返回，下一条命令再试。
        if (!self.connected) try self.dial();

        return self.roundTrip(payload) catch |e| {
            if (!isTransportFailure(e)) return e;
            self.teardown();
            // 重拨失败就把 ConnectionFailed 交给调用方（原始错误已经在这里丢了，
            // 但两者语义一致：这条命令没做成，连接也没了）。
            try self.dial();
            return self.roundTrip(payload) catch |e2| {
                if (isTransportFailure(e2)) self.teardown();
                return e2;
            };
        };
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

/// 按「连接」分段的脚本服务器：`scripts[i]` 是第 i 条连接上的回复序列，
/// 每收到一条命令就回一段，序列用完就**主动关掉这条连接**——用来模拟
/// Redis 重启 / 空闲超时 / NAT conntrack 过期，客户端必须自己重拨才能继续。
/// 连接数超过 scripts.len 时重复最后一段序列。
const ScriptedServer = struct {
    listener: std.net.Server,
    thread: std.Thread,
    scripts: []const []const []const u8,
    accepted: std.atomic.Value(usize),
    shutdown: std.atomic.Value(bool),
    stopped: bool,

    fn serve(self: *ScriptedServer) void {
        var i: usize = 0;
        while (true) : (i += 1) {
            const conn = self.listener.accept() catch return;
            defer conn.stream.close();
            if (self.shutdown.load(.acquire)) return;
            _ = self.accepted.fetchAdd(1, .monotonic);
            const script = if (i < self.scripts.len) self.scripts[i] else self.scripts[self.scripts.len - 1];
            var buf: [4096]u8 = undefined;
            for (script) |reply| {
                // 先把这条命令读走，再回复，最后才关闭：接收缓冲区里若还留着
                // 没读走的字节，close() 在 BSD/macOS 上会发 RST 而不是 FIN，
                // 刚写出去的回复就可能被一起丢掉。
                _ = conn.stream.read(&buf) catch return;
                conn.stream.writeAll(reply) catch return;
            }
        }
    }

    fn start(gpa: std.mem.Allocator, scripts: []const []const []const u8) !*ScriptedServer {
        const self = try gpa.create(ScriptedServer);
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        self.* = .{
            .listener = try addr.listen(.{ .reuse_address = true }),
            .thread = undefined,
            .scripts = scripts,
            .accepted = .init(0),
            .shutdown = .init(false),
            .stopped = false,
        };
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    fn port(self: *ScriptedServer) u16 {
        return self.listener.listen_address.getPort();
    }

    /// 幂等。跟上面 FakeServer 的 stop() 不同：这个服务线程是个 accept 循环，
    /// 停的时候多半正卡在 accept() 里。直接 listener.deinit() 关掉监听 fd 会让
    /// 阻塞中的 accept 拿到 EBADF，而 std.posix.accept 把 EBADF 当成
    /// unreachable（"always a race condition"）——会直接 panic。所以先立起
    /// shutdown 标志，再自己拨一条连接把 accept 叫醒，join 之后才关监听。
    fn stop(self: *ScriptedServer) void {
        if (self.stopped) return;
        self.stopped = true;
        self.shutdown.store(true, .release);
        if (std.net.tcpConnectToAddress(self.listener.listen_address)) |s| {
            s.close();
        } else |_| {}
        self.thread.join();
        self.listener.deinit();
    }
};

test "服务端断开后下一条命令自动重连并重试一次" {
    const gpa = std.testing.allocator;
    const srv = try ScriptedServer.start(gpa, &.{ &.{"+PONG\r\n"}, &.{"+PONG\r\n"} });
    defer {
        srv.stop();
        gpa.destroy(srv);
    }

    var c = try Client.connect(gpa, "127.0.0.1", srv.port(), null, 0);
    defer c.deinit();

    // 第一条命令走第一条连接，服务端回完就把它关掉
    const a = try c.command(&.{"PING"});
    defer a.deinit(gpa);
    try std.testing.expectEqualStrings("PONG", a.simple);

    // 第二条命令落在一条已经死掉的 socket 上：必须自己重拨并重试一次，
    // 而不是从此永远返回错误。
    const b = try c.command(&.{"PING"});
    defer b.deinit(gpa);
    try std.testing.expectEqualStrings("PONG", b.simple);
    try std.testing.expect(srv.accepted.load(.monotonic) >= 2);
}

test "重连后带密码与 db 的连接会重新握手" {
    const gpa = std.testing.allocator;
    // 每条连接都要走完 AUTH +OK、SELECT +OK，才轮到 PING +PONG。
    // 重连时漏掉握手的实现会在第二条连接上把 AUTH 的回复当成 PING 的回复。
    const srv = try ScriptedServer.start(gpa, &.{ &.{ "+OK\r\n", "+OK\r\n", "+PONG\r\n" }, &.{ "+OK\r\n", "+OK\r\n", "+PONG\r\n" } });
    defer {
        srv.stop();
        gpa.destroy(srv);
    }

    var c = try Client.connect(gpa, "127.0.0.1", srv.port(), "s3cret", 2);
    defer c.deinit();

    const a = try c.command(&.{"PING"});
    defer a.deinit(gpa);
    try std.testing.expectEqualStrings("PONG", a.simple);

    const b = try c.command(&.{"PING"});
    defer b.deinit(gpa);
    try std.testing.expectEqualStrings("PONG", b.simple);
}

test "ProtocolError 触发彻底重连：读缓冲里的残留字节不会串到下一条命令" {
    const gpa = std.testing.allocator;
    // 第一条连接回一个非法类型前缀，后面还跟着一段看起来完全合法的整数回复。
    // 只关 socket、不重建 reader 的实现会把这个 :99 当成重试之后的回复读出来，
    // 从此每条回复都错位一格——这正是 C1 描述的静默串位。
    const srv = try ScriptedServer.start(gpa, &.{ &.{"%1\r\n:99\r\n"}, &.{":7\r\n"} });
    defer {
        srv.stop();
        gpa.destroy(srv);
    }

    var c = try Client.connect(gpa, "127.0.0.1", srv.port(), null, 0);
    defer c.deinit();

    try std.testing.expectEqual(@as(i64, 7), try c.commandInt(&.{ "INCR", "hikari:seq" }));
}

test "deinit 之后不再重连，命令直接返回 ConnectionFailed" {
    const gpa = std.testing.allocator;
    const srv = try ScriptedServer.start(gpa, &.{&.{"+PONG\r\n"}});
    defer {
        srv.stop();
        gpa.destroy(srv);
    }
    var c = try Client.connect(gpa, "127.0.0.1", srv.port(), null, 0);
    defer c.deinit();
    c.deinit();
    try std.testing.expectError(error.ConnectionFailed, c.commandOk(&.{"PING"}));
}

test "服务端彻底消失时重拨失败，错误如实返回且不会无限重试" {
    const gpa = std.testing.allocator;
    const srv = try ScriptedServer.start(gpa, &.{&.{"+PONG\r\n"}});
    defer gpa.destroy(srv);

    var c = try Client.connect(gpa, "127.0.0.1", srv.port(), null, 0);
    defer c.deinit();

    const a = try c.command(&.{"PING"});
    defer a.deinit(gpa);
    try std.testing.expectEqualStrings("PONG", a.simple);

    // 关掉监听：连接断了，重拨也会被拒绝
    srv.stop();
    try std.testing.expectError(error.ConnectionFailed, c.commandOk(&.{"PING"}));
}
