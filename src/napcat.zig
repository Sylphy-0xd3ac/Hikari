const std = @import("std");
const onebot = @import("onebot.zig");

/// ✨ = U+2728，QQ 的 Unicode 表情回应用十进制码点做 emoji_id。
pub const star_emoji_id = "10024";

pub const Error = error{
    NapCatError,
    BadResponse,
    OutOfMemory,
    RequestFailed,
};

/// 在 get_msg 的 data 里判断有没有 ✨ 表情回应。
/// emoji_id 可能是字符串也可能是数字；likes_cnt 缺省视为 1。
pub fn hasStarReaction(data: std.json.Value) bool {
    const obj = switch (data) {
        .object => |o| o,
        else => return false,
    };
    const list = switch (obj.get("emoji_likes_list") orelse return false) {
        .array => |a| a,
        else => return false,
    };
    for (list.items) |item| {
        const io = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const idv = io.get("emoji_id") orelse continue;
        const matches = switch (idv) {
            .string => |s| std.mem.eql(u8, s, star_emoji_id),
            else => if (onebot.asInt(idv)) |n| n == 10024 else false,
        };
        if (!matches) continue;
        const cnt = if (io.get("likes_cnt")) |cv| (onebot.asInt(cv) orelse 1) else 1;
        if (cnt > 0) return true;
    }
    return false;
}

/// 校验 OneBot 统一响应壳，返回 data 字段。
pub fn extractData(v: std.json.Value) Error!std.json.Value {
    const obj = switch (v) {
        .object => |o| o,
        else => return error.BadResponse,
    };
    if (obj.get("status")) |s| {
        if (s == .string and !std.mem.eql(u8, s.string, "ok")) return error.NapCatError;
    }
    if (obj.get("retcode")) |r| {
        if (onebot.asInt(r)) |n| {
            if (n != 0) return error.NapCatError;
        }
    }
    return obj.get("data") orelse std.json.Value{ .null = {} };
}

pub const Client = struct {
    gpa: std.mem.Allocator,
    base_url: []const u8,
    token: []const u8,
    http: std.http.Client,

    pub fn init(gpa: std.mem.Allocator, base_url: []const u8, token: []const u8) Client {
        return .{
            .gpa = gpa,
            .base_url = base_url,
            .token = token,
            .http = .{ .allocator = gpa },
        };
    }

    pub fn deinit(self: *Client) void {
        self.http.deinit();
    }

    /// POST {base_url}/{action}，body 为 params_json，返回响应体原文（arena 分配）。
    pub fn call(
        self: *Client,
        arena: std.mem.Allocator,
        action: []const u8,
        params_json: []const u8,
    ) ![]u8 {
        const url = try std.fmt.allocPrint(arena, "{s}/{s}", .{ self.base_url, action });
        const auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{self.token});

        var aw: std.Io.Writer.Allocating = .init(arena);
        const res = self.http.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = params_json,
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .extra_headers = &.{.{ .name = "authorization", .value = auth }},
            .response_writer = &aw.writer,
        }) catch return error.RequestFailed;

        if (res.status != .ok) return error.RequestFailed;
        return aw.toOwnedSlice();
    }

    pub fn callData(
        self: *Client,
        arena: std.mem.Allocator,
        action: []const u8,
        params_json: []const u8,
    ) !std.json.Value {
        const body = try self.call(arena, action, params_json);
        const parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch return error.BadResponse;
        return extractData(parsed.value);
    }
};

fn parseVal(arena: std.mem.Allocator, src: []const u8) !std.json.Value {
    const p = try std.json.parseFromSlice(std.json.Value, arena, src, .{});
    return p.value;
}

test "hasStarReaction 识别 ✨ 表情回应" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const yes = try parseVal(a,
        \\{"emoji_likes_list":[{"emoji_id":"128","emoji_type":"1","likes_cnt":1},
        \\                     {"emoji_id":"10024","emoji_type":"2","likes_cnt":3}]}
    );
    try std.testing.expect(hasStarReaction(yes));

    const no = try parseVal(a,
        \\{"emoji_likes_list":[{"emoji_id":"128","emoji_type":"1","likes_cnt":1}]}
    );
    try std.testing.expect(!hasStarReaction(no));

    const empty = try parseVal(a, "{\"emoji_likes_list\":[]}");
    try std.testing.expect(!hasStarReaction(empty));

    const missing = try parseVal(a, "{}");
    try std.testing.expect(!hasStarReaction(missing));
}

test "hasStarReaction 接受数字形式的 emoji_id" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parseVal(a, "{\"emoji_likes_list\":[{\"emoji_id\":10024}]}");
    try std.testing.expect(hasStarReaction(v));
}

test "hasStarReaction 忽略 likes_cnt 为 0 的条目" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parseVal(a, "{\"emoji_likes_list\":[{\"emoji_id\":\"10024\",\"likes_cnt\":0}]}");
    try std.testing.expect(!hasStarReaction(v));
}

test "extractData 校验 status 与 retcode" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const ok = try extractData(try parseVal(a, "{\"status\":\"ok\",\"retcode\":0,\"data\":{\"x\":1}}"));
    try std.testing.expectEqual(@as(i64, 1), ok.object.get("x").?.integer);

    try std.testing.expectError(error.NapCatError, extractData(
        try parseVal(a, "{\"status\":\"failed\",\"retcode\":1404,\"data\":null}"),
    ));
    try std.testing.expectError(error.BadResponse, extractData(try parseVal(a, "[]")));
}

test "extractData 允许 data 为 null 时返回 null 值" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try extractData(try parseVal(a, "{\"status\":\"ok\",\"retcode\":0,\"data\":null}"));
    try std.testing.expect(v == .null);
}

test "call 发出带 Bearer token 的 POST 请求" {
    const gpa = std.testing.allocator;

    const Fake = struct {
        listener: std.net.Server,
        got: std.ArrayList(u8),
        gpa: std.mem.Allocator,

        fn serve(self: *@This()) void {
            const conn = self.listener.accept() catch return;
            defer conn.stream.close();
            var rbuf: [8192]u8 = undefined;
            var wbuf: [8192]u8 = undefined;
            var sr = conn.stream.reader(&rbuf);
            var sw = conn.stream.writer(&wbuf);
            var hs = std.http.Server.init(sr.interface(), &sw.interface);
            var req = hs.receiveHead() catch return;

            var it = req.iterateHeaders();
            while (it.next()) |h| {
                self.got.appendSlice(self.gpa, h.name) catch return;
                self.got.append(self.gpa, ':') catch return;
                self.got.appendSlice(self.gpa, h.value) catch return;
                self.got.append(self.gpa, '\n') catch return;
            }
            self.got.appendSlice(self.gpa, req.head.target) catch return;

            req.respond("{\"status\":\"ok\",\"retcode\":0,\"data\":{\"ok\":true}}", .{
                .status = .ok,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            }) catch return;
        }
    };

    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var fake: Fake = .{
        .listener = try addr.listen(.{ .reuse_address = true }),
        .got = .empty,
        .gpa = gpa,
    };
    defer {
        fake.got.deinit(gpa);
        fake.listener.deinit();
    }
    const th = try std.Thread.spawn(.{}, Fake.serve, .{&fake});

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{fake.listener.listen_address.getPort()});
    defer gpa.free(base);

    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();

    var c = Client.init(gpa, base, "secret-token");
    defer c.deinit();
    const data = try c.callData(ar.allocator(), "get_msg", "{\"message_id\":1}");
    th.join();

    try std.testing.expect(data.object.get("ok").?.bool);
    try std.testing.expect(std.mem.indexOf(u8, fake.got.items, "Bearer secret-token") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.got.items, "/get_msg") != null);
}
