const std = @import("std");
const napcat = @import("../napcat.zig");
const onebot = @import("../onebot.zig");
const rules = @import("rules.zig");
const store = @import("../store.zig");
const uuid = @import("../uuid.zig");
const scheduler = @import("../scheduler.zig");

pub const page_size: usize = 200;

pub const banner = [3][]const u8{
    "Hikari!",
    "Made with ❤️ by CuzTeam, AmethystDevs-Lab",
    "Thanks to collaborators: 恩恩hhh, apanzinc, Lonely, 小晴同学, Sylphy",
};
pub const processing_line = "Processing...";
pub const success_line = "Successfully.";

pub fn willProcessLine(gpa: std.mem.Allocator, n: usize) ![]u8 {
    return std.fmt.allocPrint(gpa, "Will process {d} messages.", .{n});
}

pub fn resultLine(gpa: std.mem.Allocator, added: usize, skipped: usize) ![]u8 {
    return std.fmt.allocPrint(gpa, "Added {d} messages, skipped {d} messages.", .{ added, skipped });
}

pub fn failedLine(gpa: std.mem.Allocator, reason: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "Failed: {s}", .{reason});
}

pub const BuildArgs = struct {
    id: u64,
    text: []const u8,
    from: []const u8,
    from_who: []const u8,
    created_at: i64,
    message_id: i64,
    group_id: u64,
    user_id: u64,
};

pub fn buildQuote(gpa: std.mem.Allocator, a: BuildArgs) !store.Quote {
    return .{
        .id = a.id,
        .uuid = uuid.v4(),
        .hitokoto = try gpa.dupe(u8, a.text),
        .kind = try gpa.dupe(u8, "g"),
        .from = try gpa.dupe(u8, a.from),
        .from_who = try gpa.dupe(u8, a.from_who),
        .creator = try gpa.dupe(u8, "Hikari"),
        .creator_uid = 0,
        .reviewer = 0,
        .commit_from = try gpa.dupe(u8, "hikari"),
        .created_at = try std.fmt.allocPrint(gpa, "{d}", .{a.created_at}),
        .length = store.utf8Length(a.text),
        .message_id = a.message_id,
        .group_id = a.group_id,
        .user_id = a.user_id,
    };
}

pub fn freeQuote(gpa: std.mem.Allocator, q: store.Quote) void {
    q.deinit(gpa);
}

pub fn inWindow(t: i64, start: i64, end: i64) bool {
    return t >= start and t < end;
}

pub fn oldestTime(msgs: []const onebot.Message) ?i64 {
    if (msgs.len == 0) return null;
    var lo = msgs[0].time;
    for (msgs[1..]) |m| lo = @min(lo, m.time);
    return lo;
}

pub fn oldestId(msgs: []const onebot.Message) ?i64 {
    if (msgs.len == 0) return null;
    var best = msgs[0];
    for (msgs[1..]) |m| if (m.time < best.time) {
        best = m;
    };
    return best.message_id;
}

pub const Deps = struct {
    gpa: std.mem.Allocator,
    nap: *napcat.Client,
    st: *store.Store,
    observed_qq: u64,
    admin_qqs: []const u64,
    group_ids: []const u64,
};

fn sendLine(deps: Deps, group_id: u64, text: []const u8) void {
    var ar = std.heap.ArenaAllocator.init(deps.gpa);
    defer ar.deinit();
    const a = ar.allocator();

    var aw: std.Io.Writer.Allocating = .init(a);
    std.json.Stringify.value(.{
        .group_id = group_id,
        .message = .{.{ .type = "text", .data = .{ .text = text } }},
    }, .{}, &aw.writer) catch return;

    _ = deps.nap.callData(a, "send_group_msg", aw.written()) catch |e| {
        std.log.warn("send_group_msg failed for group {d}: {s}", .{ group_id, @errorName(e) });
    };
}

fn groupName(deps: Deps, arena: std.mem.Allocator, group_id: u64) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(.{ .group_id = group_id }, .{}, &aw.writer) catch return "";
    const data = deps.nap.callData(arena, "get_group_info", aw.written()) catch return "";
    const obj = switch (data) {
        .object => |o| o,
        else => return "",
    };
    const v = obj.get("group_name") orelse return "";
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

fn observedCard(deps: Deps, arena: std.mem.Allocator, group_id: u64) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(.{
        .group_id = group_id,
        .user_id = deps.observed_qq,
        .no_cache = true,
    }, .{}, &aw.writer) catch return "";
    const data = deps.nap.callData(arena, "get_group_member_info", aw.written()) catch return "";
    const obj = switch (data) {
        .object => |o| o,
        else => return "",
    };
    for ([_][]const u8{ "card", "nickname" }) |k| {
        if (obj.get(k)) |v| {
            if (v == .string and v.string.len > 0) return v.string;
        }
    }
    return "";
}

fn fetchPage(
    deps: Deps,
    arena: std.mem.Allocator,
    group_id: u64,
    before_id: ?i64,
) ![]onebot.Message {
    var aw: std.Io.Writer.Allocating = .init(arena);
    if (before_id) |bid| {
        try std.json.Stringify.value(.{
            .group_id = group_id,
            .message_seq = bid,
            .count = page_size,
            .reverse_order = false,
        }, .{}, &aw.writer);
    } else {
        try std.json.Stringify.value(.{
            .group_id = group_id,
            .count = page_size,
            .reverse_order = false,
        }, .{}, &aw.writer);
    }
    const data = try deps.nap.callData(arena, "get_group_msg_history", aw.written());
    const obj = switch (data) {
        .object => |o| o,
        else => return &.{},
    };
    const arr = obj.get("messages") orelse return &.{};
    return onebot.parseMessages(arena, arr);
}

fn getMsg(deps: Deps, arena: std.mem.Allocator, message_id: i64) ?std.json.Value {
    var aw: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(.{ .message_id = message_id }, .{}, &aw.writer) catch return null;
    return deps.nap.callData(arena, "get_msg", aw.written()) catch null;
}

/// 跑一次完整扫描。失败不抛出，改为在日志里发 Failed 行。
pub fn runOnce(deps: Deps, run_at: i64) void {
    const win_start = scheduler.windowStart(run_at);

    for (deps.group_ids) |gid| {
        for (banner) |line| sendLine(deps, gid, line);
        sendLine(deps, gid, processing_line);
    }

    for (deps.group_ids) |gid| {
        scanGroup(deps, gid, win_start, run_at) catch |e| {
            const msg = failedLine(deps.gpa, @errorName(e)) catch {
                // 格式化 Failed 行本身失败（理论上只会是 gpa OOM）：不能因此
                // `return` 掉整个 runOnce——那样会连带跳过其余尚未处理的群，
                // 也会跳过下面的 setLastRun。只记警告，继续下一个群。
                std.log.warn("group {d}: scanGroup failed ({s}) and failedLine formatting also failed", .{ gid, @errorName(e) });
                continue;
            };
            defer deps.gpa.free(msg);
            sendLine(deps, gid, msg);
        };
    }

    deps.st.setLastRun(run_at) catch |e| {
        std.log.warn("setLastRun failed: {s}", .{@errorName(e)});
    };
}

fn scanGroup(deps: Deps, gid: u64, win_start: i64, win_end: i64) !void {
    var ar = std.heap.ArenaAllocator.init(deps.gpa);
    defer ar.deinit();
    const a = ar.allocator();

    // ---- 1. 翻页拉历史，窗口外再多拉一页作解析缓冲 ----
    var pool: std.ArrayList(onebot.Message) = .empty;
    var before: ?i64 = null;
    var reached_start = false;
    var buffer_page_done = false;
    var guard: usize = 0;

    while (guard < 200) : (guard += 1) {
        const page = try fetchPage(deps, a, gid, before);
        if (page.len == 0) break;
        try pool.appendSlice(a, page);

        const oldest = oldestTime(page) orelse break;
        const next_before = oldestId(page) orelse break;
        if (before != null and next_before == before.?) break; // 不再前进，防死循环
        before = next_before;

        if (reached_start) {
            buffer_page_done = true;
            break;
        }
        if (oldest < win_start) reached_start = true;
    }

    // ---- 2. 切出判定集 ----
    var window: std.ArrayList(onebot.Message) = .empty;
    for (pool.items) |m| {
        if (inWindow(m.time, win_start, win_end)) try window.append(a, m);
    }
    std.mem.sort(onebot.Message, window.items, {}, struct {
        fn lt(_: void, x: onebot.Message, y: onebot.Message) bool {
            return x.time < y.time;
        }
    }.lt);

    const line = try willProcessLine(deps.gpa, window.items.len);
    defer deps.gpa.free(line);
    sendLine(deps, gid, line);

    // ---- 3. 补拉不在池里的 reply 目标 ----
    for (window.items) |m| {
        const rid = m.replyTarget() orelse continue;
        var found = false;
        for (pool.items) |p| {
            if (p.message_id == rid) {
                found = true;
                break;
            }
        }
        if (found) continue;
        const data = getMsg(deps, a, rid) orelse {
            std.log.warn("group {d}: reply target {d} unresolvable", .{ gid, rid });
            continue;
        };
        if (try onebot.parseMessage(a, data)) |parsed| try pool.append(a, parsed);
    }

    // ---- 4. 逐条查被观察者消息的表情回应 ----
    var star_ids: std.ArrayList(i64) = .empty;
    for (window.items) |m| {
        if (m.user_id != deps.observed_qq) continue;
        const data = getMsg(deps, a, m.message_id) orelse continue;
        if (napcat.hasStarReaction(data)) try star_ids.append(a, m.message_id);
    }

    // ---- 5. 判定 ----
    var outcome = try rules.classify(deps.gpa, window.items, pool.items, star_ids.items, .{
        .observed_qq = deps.observed_qq,
        .admin_qqs = deps.admin_qqs,
    });
    defer outcome.deinit(deps.gpa);

    for (outcome.unresolved) |rid| {
        std.log.warn("group {d}: reply target {d} unresolvable", .{ gid, rid });
    }

    // ---- 6. 作废先落盘 ----
    for (outcome.revoked) |rid| {
        deps.st.revoke(rid) catch |e| {
            std.log.warn("revoke {d} failed: {s}", .{ rid, @errorName(e) });
        };
    }

    // ---- 7. 过滤并入库 ----
    const from = groupName(deps, a, gid);
    const from_who = observedCard(deps, a, gid);

    var added: usize = 0;
    var skipped: usize = 0;

    for (outcome.candidates) |cand| {
        if (try deps.st.isTombstoned(cand.message_id)) {
            skipped += 1;
            continue;
        }
        if (try deps.st.exists(cand.message_id)) {
            skipped += 1;
            continue;
        }

        var target: ?onebot.Message = null;
        for (pool.items) |p| {
            if (p.message_id == cand.message_id) {
                target = p;
                break;
            }
        }

        const text: []const u8 = if (cand.text_override) |t| t else blk: {
            const tm = target orelse {
                skipped += 1;
                continue;
            };
            break :blk try tm.renderText(a);
        };
        if (text.len == 0) {
            skipped += 1;
            continue;
        }

        const id = try deps.st.nextId();
        const q = try buildQuote(deps.gpa, .{
            .id = id,
            .text = text,
            .from = from,
            .from_who = from_who,
            .created_at = if (target) |t| t.time else win_end,
            .message_id = cand.message_id,
            .group_id = gid,
            .user_id = if (target) |t| t.user_id else deps.observed_qq,
        });
        defer freeQuote(deps.gpa, q);

        deps.st.add(q) catch |e| {
            std.log.warn("add {d} failed: {s}", .{ cand.message_id, @errorName(e) });
            skipped += 1;
            continue;
        };
        added += 1;
    }

    const result = try resultLine(deps.gpa, added, skipped);
    defer deps.gpa.free(result);
    sendLine(deps, gid, result);
    sendLine(deps, gid, success_line);
}

test "banner 三行文案逐字正确" {
    try std.testing.expectEqual(@as(usize, 3), banner.len);
    try std.testing.expectEqualStrings("Hikari!", banner[0]);
    try std.testing.expectEqualStrings("Made with ❤️ by CuzTeam, AmethystDevs-Lab", banner[1]);
    try std.testing.expectEqualStrings(
        "Thanks to collaborators: 恩恩hhh, apanzinc, Lonely, 小晴同学, Sylphy",
        banner[2],
    );
}

test "固定行文案正确" {
    try std.testing.expectEqualStrings("Processing...", processing_line);
    try std.testing.expectEqualStrings("Successfully.", success_line);
}

test "willProcessLine 格式" {
    const gpa = std.testing.allocator;
    const a = try willProcessLine(gpa, 1234);
    defer gpa.free(a);
    try std.testing.expectEqualStrings("Will process 1234 messages.", a);

    const b = try willProcessLine(gpa, 0);
    defer gpa.free(b);
    try std.testing.expectEqualStrings("Will process 0 messages.", b);
}

test "resultLine 格式" {
    const gpa = std.testing.allocator;
    const a = try resultLine(gpa, 12, 34);
    defer gpa.free(a);
    try std.testing.expectEqualStrings("Added 12 messages, skipped 34 messages.", a);
}

test "failedLine 格式" {
    const gpa = std.testing.allocator;
    const a = try failedLine(gpa, "ConnectionFailed");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("Failed: ConnectionFailed", a);
}

test "buildQuote 填齐 hitokoto 字段" {
    const gpa = std.testing.allocator;
    const q = try buildQuote(gpa, .{
        .id = 9,
        .text = "今天也是好天气",
        .from = "测试群",
        .from_who = "小明",
        .created_at = 1700000000,
        .message_id = 12345,
        .group_id = 999,
        .user_id = 10001,
    });
    defer freeQuote(gpa, q);

    try std.testing.expectEqual(@as(u64, 9), q.id);
    try std.testing.expectEqualStrings("今天也是好天气", q.hitokoto);
    try std.testing.expectEqualStrings("g", q.kind);
    try std.testing.expectEqualStrings("测试群", q.from);
    try std.testing.expectEqualStrings("小明", q.from_who);
    try std.testing.expectEqualStrings("Hikari", q.creator);
    try std.testing.expectEqual(@as(u64, 0), q.creator_uid);
    try std.testing.expectEqual(@as(u64, 0), q.reviewer);
    try std.testing.expectEqualStrings("hikari", q.commit_from);
    try std.testing.expectEqualStrings("1700000000", q.created_at);
    // 长度按码点数，不是字节数
    try std.testing.expectEqual(@as(usize, 7), q.length);
    try std.testing.expectEqual(@as(i64, 12345), q.message_id);
}

test "buildQuote 的 length 对混合中英文按码点计" {
    const gpa = std.testing.allocator;
    const q = try buildQuote(gpa, .{
        .id = 1,
        .text = "你好ab✨",
        .from = "g",
        .from_who = "w",
        .created_at = 0,
        .message_id = 1,
        .group_id = 1,
        .user_id = 1,
    });
    defer freeQuote(gpa, q);
    try std.testing.expectEqual(@as(usize, 5), q.length);
}

test "inWindow 判定左闭右开区间" {
    try std.testing.expect(inWindow(100, 100, 200));
    try std.testing.expect(inWindow(199, 100, 200));
    try std.testing.expect(!inWindow(200, 100, 200));
    try std.testing.expect(!inWindow(99, 100, 200));
}

test "oldestTime 取批次里最早的时间" {
    const msgs = [_]onebot.Message{
        .{ .message_id = 1, .user_id = 1, .time = 300, .segments = &.{} },
        .{ .message_id = 2, .user_id = 1, .time = 100, .segments = &.{} },
        .{ .message_id = 3, .user_id = 1, .time = 200, .segments = &.{} },
    };
    try std.testing.expectEqual(@as(?i64, 100), oldestTime(&msgs));
    try std.testing.expectEqual(@as(?i64, null), oldestTime(&.{}));
}

test "oldestId 取最早那条的 message_id" {
    const msgs = [_]onebot.Message{
        .{ .message_id = 1, .user_id = 1, .time = 300, .segments = &.{} },
        .{ .message_id = 2, .user_id = 1, .time = 100, .segments = &.{} },
    };
    try std.testing.expectEqual(@as(?i64, 2), oldestId(&msgs));
}
