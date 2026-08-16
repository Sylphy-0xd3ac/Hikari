const std = @import("std");
const onebot = @import("onebot.zig");

/// ✨ = U+2728，QQ 的 Unicode 表情回应用十进制码点做 emoji_id。
pub const star_emoji_id = "10024";
/// 数值形式由字符串形式在 comptime 推导，两者不可能漂移。
const star_emoji_id_num: i64 = std.fmt.parseInt(i64, star_emoji_id, 10) catch unreachable;

/// 🔥 = U+1F525，同样以十进制码点做 emoji_id。用于"链式收录"：被观察者把一句话
/// 拆成几条发，群友额外贴 🔥（在 ✨ 之外）标记它们应当拼成一条语录。
pub const fire_emoji_id = "128293";
/// 数值形式由字符串形式在 comptime 推导，两者不可能漂移——同 star_emoji_id_num
/// 一样，这个模式此前真的漂移过一次。
const fire_emoji_id_num: i64 = std.fmt.parseInt(i64, fire_emoji_id, 10) catch unreachable;

/// 💤 = U+1F4A4 = 十进制 128164。管理员发一条只有 💤 的消息、再由本人给这条
/// 消息点一个 💤 表情回应，才构成“这个群这一轮不收录”的双重确认。
pub const sleep_emoji_id = "128164";
const sleep_emoji_id_num: i64 = std.fmt.parseInt(i64, sleep_emoji_id, 10) catch unreachable;

pub const Error = error{
    NapCatError,
    BadResponse,
    OutOfMemory,
    RequestFailed,
};

/// hasStarReaction / hasFireReaction 共用的判定逻辑：emoji_id 可能是字符串也可能是
/// 数字；likes_cnt 缺省视为 1。
fn hasReaction(data: std.json.Value, id_str: []const u8, id_num: i64) bool {
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
            .string => |s| std.mem.eql(u8, s, id_str),
            else => if (onebot.asInt(idv)) |n| n == id_num else false,
        };
        if (!matches) continue;
        const cnt = if (io.get("likes_cnt")) |cv| (onebot.asInt(cv) orelse 1) else 1;
        if (cnt > 0) return true;
    }
    return false;
}

/// 在 get_msg 的 data 里判断有没有 ✨ 表情回应。
pub fn hasStarReaction(data: std.json.Value) bool {
    return hasReaction(data, star_emoji_id, star_emoji_id_num);
}

/// 在 get_msg 的 data 里判断有没有 🔥 表情回应。跟 hasStarReaction 读的是同一个
/// get_msg 响应体，不需要额外调用。
pub fn hasFireReaction(data: std.json.Value) bool {
    return hasReaction(data, fire_emoji_id, fire_emoji_id_num);
}

/// 在 get_msg 的 data 里判断有没有 💤 表情回应。这里只确认“至少有人点过”；
/// 回应者是谁要再用 NapCat 的 `get_emoji_likes` 查询，见 hasEmojiLikeFromUser。
pub fn hasSleepReaction(data: std.json.Value) bool {
    return hasReaction(data, sleep_emoji_id, sleep_emoji_id_num);
}

/// `get_emoji_likes` 的 data 形如
/// `{ "emoji_like_list": [{ "user_id": "123", ... }] }`。NapCat 推荐 ID 用
/// 字符串，但兼容层和既有 get_msg 一样也接受数字，避免部署版本差异让确认命令
/// 静默失效。
pub fn hasEmojiLikeFromUser(data: std.json.Value, user_id: u64) bool {
    const obj = switch (data) {
        .object => |o| o,
        else => return false,
    };
    const list = switch (obj.get("emoji_like_list") orelse return false) {
        .array => |a| a,
        else => return false,
    };
    for (list.items) |item| {
        const like = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const uid = onebot.asInt(like.get("user_id") orelse continue) orelse continue;
        if (uid >= 0 and @as(u64, @intCast(uid)) == user_id) return true;
    }
    return false;
}

/// 把 get_msg 的 data 里出现过的**全部** emoji_id 收成一行 `id×次数` 文本
/// （用传入的 allocator 分配，扫描里传的是每个群一份的 arena）。
///
/// design.md §3.3 要求"扫描时把所有未匹配的 emoji_id 打进日志，便于首次实跑时
/// 核对真实值"，README 线上假设 #4 也指着这条日志。hasStarReaction 只回 bool，
/// 在里面直接打日志会让每个调用点（包括单元测试）都往 stderr 刷字，所以改成
/// 把看到的 id 交回给调用方，由扫描器决定什么时候打——纯函数，可单测，测试输出
/// 也保持干净。
///
/// 没有任何表情回应时返回空串：调用方用它来判断该不该打这一行，避免给绝大多数
/// 压根没有回应的消息刷屏。
pub fn emojiIdsSummary(gpa: std.mem.Allocator, data: std.json.Value) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var w = out.writer(gpa);

    const obj = switch (data) {
        .object => |o| o,
        else => return out.toOwnedSlice(gpa),
    };
    const list = switch (obj.get("emoji_likes_list") orelse return out.toOwnedSlice(gpa)) {
        .array => |a| a,
        else => return out.toOwnedSlice(gpa),
    };
    for (list.items) |item| {
        const io = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const idv = io.get("emoji_id") orelse continue;
        if (out.items.len > 0) try w.writeAll(", ");
        switch (idv) {
            .string => |s| try w.print("{s}", .{s}),
            else => if (onebot.asInt(idv)) |n| {
                try w.print("{d}", .{n});
            } else {
                try w.writeAll("?");
            },
        }
        const cnt = if (io.get("likes_cnt")) |cv| (onebot.asInt(cv) orelse 1) else 1;
        try w.print("x{d}", .{cnt});
    }
    return out.toOwnedSlice(gpa);
}

/// 校验 OneBot 统一响应壳，返回 data 字段。
///
/// 信封本身不合法（status 缺失/非字符串，或 retcode 缺失/不可解析为整数）→ BadResponse。
/// 信封合法但请求失败（status 不是 "ok"，或 retcode 非 0）→ NapCatError。
/// 两种失败模式故意区分开，方便调用方分辨"响应格式不对"和"NapCat 拒绝了这次调用"。
pub fn extractData(v: std.json.Value) Error!std.json.Value {
    const obj = switch (v) {
        .object => |o| o,
        else => return error.BadResponse,
    };
    const status = switch (obj.get("status") orelse return error.BadResponse) {
        .string => |s| s,
        else => return error.BadResponse,
    };
    const retcode = onebot.asInt(obj.get("retcode") orelse return error.BadResponse) orelse
        return error.BadResponse;

    if (!std.mem.eql(u8, status, "ok") or retcode != 0) return error.NapCatError;
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

test "hasStarReaction 缺省 likes_cnt 按 1 计（视为存在但未计数）" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parseVal(a, "{\"emoji_likes_list\":[{\"emoji_id\":\"10024\"}]}");
    try std.testing.expect(hasStarReaction(v));
}

test "hasFireReaction 识别 🔥 表情回应，与 ✨ 互不干扰" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const both = try parseVal(a,
        \\{"emoji_likes_list":[{"emoji_id":"10024","emoji_type":"2","likes_cnt":1},
        \\                     {"emoji_id":"128293","emoji_type":"2","likes_cnt":1}]}
    );
    try std.testing.expect(hasStarReaction(both));
    try std.testing.expect(hasFireReaction(both));

    const star_only = try parseVal(a,
        \\{"emoji_likes_list":[{"emoji_id":"10024","emoji_type":"2","likes_cnt":1}]}
    );
    try std.testing.expect(hasStarReaction(star_only));
    try std.testing.expect(!hasFireReaction(star_only));

    const fire_only = try parseVal(a,
        \\{"emoji_likes_list":[{"emoji_id":"128293","emoji_type":"2","likes_cnt":1}]}
    );
    try std.testing.expect(!hasStarReaction(fire_only));
    try std.testing.expect(hasFireReaction(fire_only));

    const neither = try parseVal(a, "{\"emoji_likes_list\":[]}");
    try std.testing.expect(!hasFireReaction(neither));
}

test "hasFireReaction 接受数字形式的 emoji_id" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parseVal(a, "{\"emoji_likes_list\":[{\"emoji_id\":128293}]}");
    try std.testing.expect(hasFireReaction(v));
}

test "hasFireReaction 忽略 likes_cnt 为 0 的条目" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parseVal(a, "{\"emoji_likes_list\":[{\"emoji_id\":\"128293\",\"likes_cnt\":0}]}");
    try std.testing.expect(!hasFireReaction(v));
}

test "hasSleepReaction 识别 💤 表情回应且不与 ✨/🔥 混淆" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const sleep_only = try parseVal(a,
        \\{"emoji_likes_list":[{"emoji_id":"128164","emoji_type":"2","likes_cnt":1}]}
    );
    try std.testing.expect(hasSleepReaction(sleep_only));
    try std.testing.expect(!hasStarReaction(sleep_only));
    try std.testing.expect(!hasFireReaction(sleep_only));

    const zero = try parseVal(a,
        \\{"emoji_likes_list":[{"emoji_id":128164,"likes_cnt":0}]}
    );
    try std.testing.expect(!hasSleepReaction(zero));
}

test "hasEmojiLikeFromUser 从 get_emoji_likes 结果核对点击者，兼容字符串和数字 ID" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const data = try parseVal(a,
        \\{"emoji_like_list":[
        \\  {"user_id":"20001","nick_name":"管理员"},
        \\  {"user_id":30001,"nick_name":"群员"}
        \\]}
    );
    try std.testing.expect(hasEmojiLikeFromUser(data, 20001));
    try std.testing.expect(hasEmojiLikeFromUser(data, 30001));
    try std.testing.expect(!hasEmojiLikeFromUser(data, 40001));
    try std.testing.expect(!hasEmojiLikeFromUser(try parseVal(a, "{}"), 20001));
}

test "emojiIdsSummary 列出全部 emoji_id 与计数（首次实跑核对 star_emoji_id 用）" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const v = try parseVal(a,
        \\{"emoji_likes_list":[{"emoji_id":"128","emoji_type":"1","likes_cnt":2},
        \\                     {"emoji_id":"9999","emoji_type":"2"}]}
    );
    try std.testing.expectEqualStrings("128x2, 9999x1", try emojiIdsSummary(a, v));
}

test "emojiIdsSummary 接受数字形式的 emoji_id" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parseVal(a, "{\"emoji_likes_list\":[{\"emoji_id\":76,\"likes_cnt\":3}]}");
    try std.testing.expectEqualStrings("76x3", try emojiIdsSummary(a, v));
}

test "emojiIdsSummary 没有任何表情回应时返回空串（调用方据此不打日志）" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    try std.testing.expectEqualStrings("", try emojiIdsSummary(a, try parseVal(a, "{}")));
    try std.testing.expectEqualStrings("", try emojiIdsSummary(a, try parseVal(a, "{\"emoji_likes_list\":[]}")));
    try std.testing.expectEqualStrings("", try emojiIdsSummary(a, try parseVal(a, "{\"emoji_likes_list\":\"nope\"}")));
    try std.testing.expectEqualStrings("", try emojiIdsSummary(a, try parseVal(a, "[]")));
}

test "emojiIdsSummary 也会列出已匹配的 ✨——调用方只在没匹配上时才打这行" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parseVal(a, "{\"emoji_likes_list\":[{\"emoji_id\":\"10024\",\"likes_cnt\":1}]}");
    try std.testing.expectEqualStrings("10024x1", try emojiIdsSummary(a, v));
}

fn emojiIdsSummaryUnderFailingAllocator(gpa: std.mem.Allocator) !void {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const v = try parseVal(ar.allocator(),
        \\{"emoji_likes_list":[{"emoji_id":"128","likes_cnt":2},{"emoji_id":9999}]}
    );
    const s = try emojiIdsSummary(gpa, v);
    gpa.free(s);
}

test "OOM 回归：emojiIdsSummary 在任意分配点失败都不泄漏" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        emojiIdsSummaryUnderFailingAllocator,
        .{},
    );
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

test "extractData 拒绝信封缺失或类型不对的响应" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    // status 整体缺失。
    try std.testing.expectError(error.BadResponse, extractData(
        try parseVal(a, "{\"retcode\":0,\"data\":{}}"),
    ));
    // status 存在但不是字符串。
    try std.testing.expectError(error.BadResponse, extractData(
        try parseVal(a, "{\"status\":123,\"retcode\":0,\"data\":{}}"),
    ));
    // retcode 整体缺失。
    try std.testing.expectError(error.BadResponse, extractData(
        try parseVal(a, "{\"status\":\"ok\",\"data\":{}}"),
    ));
    // retcode 存在但无法解析为整数。
    try std.testing.expectError(error.BadResponse, extractData(
        try parseVal(a, "{\"status\":\"ok\",\"retcode\":\"oops\",\"data\":{}}"),
    ));
}

test "call 发出带 Bearer token 的 POST 请求" {
    const gpa = std.testing.allocator;

    const Fake = struct {
        listener: std.net.Server,
        got: std.ArrayList(u8),
        gpa: std.mem.Allocator,
        method: std.http.Method = undefined,
        body: ?[]u8 = null,

        fn serve(self: *@This()) void {
            const conn = self.listener.accept() catch return;
            defer conn.stream.close();
            var rbuf: [8192]u8 = undefined;
            var wbuf: [8192]u8 = undefined;
            var sr = conn.stream.reader(&rbuf);
            var sw = conn.stream.writer(&wbuf);
            var hs = std.http.Server.init(sr.interface(), &sw.interface);
            var req = hs.receiveHead() catch return;

            self.method = req.head.method;

            var it = req.iterateHeaders();
            while (it.next()) |h| {
                self.got.appendSlice(self.gpa, h.name) catch return;
                self.got.append(self.gpa, ':') catch return;
                self.got.appendSlice(self.gpa, h.value) catch return;
                self.got.append(self.gpa, '\n') catch return;
            }
            self.got.appendSlice(self.gpa, req.head.target) catch return;

            var body_buf: [4096]u8 = undefined;
            const body_reader = req.readerExpectNone(&body_buf);
            self.body = body_reader.allocRemaining(self.gpa, .unlimited) catch null;

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
        if (fake.body) |b| gpa.free(b);
        fake.listener.deinit();
    }
    const th = try std.Thread.spawn(.{}, Fake.serve, .{&fake});
    var joined = false;
    // 兜底：如果下面的 try 提前失败，也不能把线程句柄扔掉不 join。
    // 正常路径里显式 join 发生在读取 fake.got/fake.body 之前（见下），
    // 所以这里不会造成对同一线程 join 两次。
    defer if (!joined) th.join();

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{fake.listener.listen_address.getPort()});
    defer gpa.free(base);

    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();

    var c = Client.init(gpa, base, "secret-token");
    defer c.deinit();
    const data = try c.callData(ar.allocator(), "get_msg", "{\"message_id\":1}");
    th.join();
    joined = true;

    try std.testing.expect(data.object.get("ok").?.bool);
    try std.testing.expect(std.mem.indexOf(u8, fake.got.items, "Bearer secret-token") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.got.items, "/get_msg") != null);
    try std.testing.expectEqual(std.http.Method.POST, fake.method);
    try std.testing.expect(fake.body != null);
    try std.testing.expectEqualStrings("{\"message_id\":1}", fake.body.?);
}
