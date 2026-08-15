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

/// 逐字段分配并立刻 errdefer：前面已经成功分配的字符串字段在后面任意一步
/// 失败时都会按相反顺序释放，不会孤儿化。与 store.zig 的 quoteFromPairs /
/// hashFields 用的是同一套链式清理写法。
pub fn buildQuote(gpa: std.mem.Allocator, a: BuildArgs) !store.Quote {
    var q: store.Quote = undefined;
    q.id = a.id;
    q.uuid = uuid.v4();

    q.hitokoto = try gpa.dupe(u8, a.text);
    errdefer gpa.free(q.hitokoto);
    q.kind = try gpa.dupe(u8, "g");
    errdefer gpa.free(q.kind);
    q.from = try gpa.dupe(u8, a.from);
    errdefer gpa.free(q.from);
    q.from_who = try gpa.dupe(u8, a.from_who);
    errdefer gpa.free(q.from_who);
    q.creator = try gpa.dupe(u8, "Hikari");
    errdefer gpa.free(q.creator);
    q.commit_from = try gpa.dupe(u8, "hikari");
    errdefer gpa.free(q.commit_from);
    q.created_at = try std.fmt.allocPrint(gpa, "{d}", .{a.created_at});

    q.creator_uid = 0;
    q.reviewer = 0;
    q.length = store.utf8Length(a.text);
    q.message_id = a.message_id;
    q.group_id = a.group_id;
    q.user_id = a.user_id;
    return q;
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

/// 时间并列时按 message_id 取最小者，保证与输入顺序无关的确定性。
/// QQ 的时间戳常见秒级碰撞；若不打破并列就用数组顺序，翻页锚点
/// （下一页的 message_seq）就可能因为并列消息里挑中了不是最老的那条
/// 而漏掉同一秒内排在它前面的消息。
pub fn oldestId(msgs: []const onebot.Message) ?i64 {
    if (msgs.len == 0) return null;
    var best = msgs[0];
    for (msgs[1..]) |m| {
        if (m.time < best.time or (m.time == best.time and m.message_id < best.message_id)) {
            best = m;
        }
    }
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
    std.json.Stringify.value(.{ .group_id = group_id }, .{}, &aw.writer) catch |e| {
        std.log.warn("group {d}: building get_group_info request failed: {s}", .{ group_id, @errorName(e) });
        return "";
    };
    const data = deps.nap.callData(arena, "get_group_info", aw.written()) catch |e| {
        std.log.warn("group {d}: get_group_info failed: {s}", .{ group_id, @errorName(e) });
        return "";
    };
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
    }, .{}, &aw.writer) catch |e| {
        std.log.warn("group {d}: building get_group_member_info request failed: {s}", .{ group_id, @errorName(e) });
        return "";
    };
    const data = deps.nap.callData(arena, "get_group_member_info", aw.written()) catch |e| {
        std.log.warn("group {d}: get_group_member_info failed: {s}", .{ group_id, @errorName(e) });
        return "";
    };
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
///
/// `setLastRun` 只在"至少一个群跑成功"时才调用：全体失败就不标记今天已跑过，
/// 好让 scheduler.missedRun 在下次进程启动时补跑；只要有一个群成功，就仍然
/// 调用它——重新扫一遍已经成功的群（重复处理，但 store 的 exists/isTombstoned
/// 会挡掉重复入库）比彻底漏掉今天这次更糟。
pub fn runOnce(deps: Deps, run_at: i64) void {
    const win_start = scheduler.windowStart(run_at);

    for (deps.group_ids) |gid| {
        for (banner) |line| sendLine(deps, gid, line);
        sendLine(deps, gid, processing_line);
    }

    var any_succeeded = false;
    for (deps.group_ids) |gid| {
        const ok = scanGroup(deps, gid, win_start, run_at) catch |e| catch_blk: {
            const msg = failedLine(deps.gpa, @errorName(e)) catch {
                // 格式化 Failed 行本身失败（理论上只会是 gpa OOM）：不能因此
                // 中断整个 runOnce——那样会连带跳过其余尚未处理的群，也会
                // 跳过下面对 any_succeeded 的正确统计。只记警告，把这个群
                // 计为失败，继续处理下一个群。
                std.log.warn("group {d}: scanGroup failed ({s}) and failedLine formatting also failed", .{ gid, @errorName(e) });
                break :catch_blk false;
            };
            defer deps.gpa.free(msg);
            sendLine(deps, gid, msg);
            break :catch_blk false;
        };
        if (ok) any_succeeded = true;
    }

    if (any_succeeded) {
        deps.st.setLastRun(run_at) catch |e| {
            std.log.warn("setLastRun failed: {s}", .{@errorName(e)});
        };
    } else {
        std.log.warn("all groups failed this run; skipping setLastRun so a missed run gets retried", .{});
    }
}

/// 扫单个群。返回值不是错误通道——它是 runOnce 判断是否调用 setLastRun 用的
/// 成功信号：true = 这个群从头到尾没出岔子（哪怕 Added/skipped 都是 0）；
/// false = 落库阶段出现了至少一次 store.add 失败（已经在函数内部发了
/// Failed 行，不需要 runOnce 再发一次）。真正的硬失败（分页/判定阶段的
/// `try` 出错）仍然走 `!bool` 的错误通道，由 runOnce 的 catch 处理。
fn scanGroup(deps: Deps, gid: u64, win_start: i64, win_end: i64) !bool {
    var ar = std.heap.ArenaAllocator.init(deps.gpa);
    defer ar.deinit();
    const a = ar.allocator();

    // ---- 1. 翻页拉历史，窗口外再多拉一页作解析缓冲 ----
    var pool: std.ArrayList(onebot.Message) = .empty;
    var before: ?i64 = null;
    var reached_start = false;
    var guard: usize = 0;

    while (guard < 200) : (guard += 1) {
        const page = try fetchPage(deps, a, gid, before);
        if (page.len == 0) break;
        try pool.appendSlice(a, page);

        const oldest = oldestTime(page) orelse break;
        const next_before = oldestId(page) orelse break;
        if (before != null and next_before == before.?) break; // 不再前进，防死循环
        before = next_before;

        // reached_start 单独一个标志就足以实现"再多拉一页"：本次迭代刚拉到的
        // 这一页就是缓冲页——上一轮已经看到过窗口外的消息了，这里再 break 出去。
        if (reached_start) break;
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
        // 拉不到就静默跳过：这里对窗口内每条带 reply 段的消息都会尝试解析，
        // 绝大多数是普通聊天回复，从来用不上；真正被 classify 需要却解析不了
        // 的目标，会出现在下面 outcome.unresolved 里并在那里统一警告一次，
        // 不在这里重复发一遍。
        const data = getMsg(deps, a, rid) orelse continue;
        if (try onebot.parseMessage(a, data)) |parsed| try pool.append(a, parsed);
    }

    // ---- 4. 逐条查被观察者消息的表情回应 ----
    var star_ids: std.ArrayList(i64) = .empty;
    for (window.items) |m| {
        if (m.user_id != deps.observed_qq) continue;
        const data = getMsg(deps, a, m.message_id) orelse {
            std.log.warn("group {d}: star-reaction probe for message {d} failed", .{ gid, m.message_id });
            continue;
        };
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
    // store.add 失败与"被关卡拦下"是两码事（spec §7 的 skipped 特指后者），
    // 单独计数，不混进 skipped。
    var failed: usize = 0;
    var last_add_err: []const u8 = "";

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
            failed += 1;
            last_add_err = @errorName(e);
            continue;
        };
        added += 1;
    }

    const result = try resultLine(deps.gpa, added, skipped);
    defer deps.gpa.free(result);
    sendLine(deps, gid, result);

    // 写库失败不能用 Successfully. 收尾——那是运营方唯一的"这次跑成功了"信号。
    // 改发 Failed 行，带上丢了几条、最后一次的错误原因，让人知道有东西没存住。
    if (failed > 0) {
        const reason = try std.fmt.allocPrint(
            deps.gpa,
            "{d} quote(s) failed to save (last error: {s})",
            .{ failed, last_add_err },
        );
        defer deps.gpa.free(reason);
        const msg = try failedLine(deps.gpa, reason);
        defer deps.gpa.free(msg);
        sendLine(deps, gid, msg);
        return false;
    }

    sendLine(deps, gid, success_line);
    return true;
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

test "resultLine 处理 0/0" {
    const gpa = std.testing.allocator;
    const a = try resultLine(gpa, 0, 0);
    defer gpa.free(a);
    try std.testing.expectEqualStrings("Added 0 messages, skipped 0 messages.", a);
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

test "buildQuote 遇到非法 UTF-8 时 length 退化为字节数（store.utf8Length 的约定）" {
    const gpa = std.testing.allocator;
    const invalid = "\xff\xfe\xfd";
    const q = try buildQuote(gpa, .{
        .id = 1,
        .text = invalid,
        .from = "g",
        .from_who = "w",
        .created_at = 0,
        .message_id = 1,
        .group_id = 1,
        .user_id = 1,
    });
    defer freeQuote(gpa, q);
    try std.testing.expectEqual(@as(usize, 3), q.length);
}

fn buildQuoteUnderFailingAllocator(gpa: std.mem.Allocator) !void {
    const q = try buildQuote(gpa, .{
        .id = 1,
        .text = "abc",
        .from = "g",
        .from_who = "w",
        .created_at = 0,
        .message_id = 1,
        .group_id = 1,
        .user_id = 1,
    });
    freeQuote(gpa, q);
}

test "OOM 回归：buildQuote 在任意分配点失败都不能泄漏之前已分配的字段" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, buildQuoteUnderFailingAllocator, .{});
}

test "inWindow 判定左闭右开区间" {
    try std.testing.expect(inWindow(100, 100, 200));
    try std.testing.expect(inWindow(199, 100, 200));
    try std.testing.expect(!inWindow(200, 100, 200));
    try std.testing.expect(!inWindow(99, 100, 200));
}

test "inWindow：start 等于 end 时区间为空，任何 t 都不在窗口内" {
    try std.testing.expect(!inWindow(100, 100, 100));
    try std.testing.expect(!inWindow(99, 100, 100));
    try std.testing.expect(!inWindow(101, 100, 100));
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

test "oldestId 空切片返回 null" {
    try std.testing.expectEqual(@as(?i64, null), oldestId(&.{}));
}

test "oldestId 时间并列时按 message_id 取最小者，与输入顺序无关" {
    const a_first = [_]onebot.Message{
        .{ .message_id = 5, .user_id = 1, .time = 100, .segments = &.{} },
        .{ .message_id = 2, .user_id = 1, .time = 100, .segments = &.{} },
        .{ .message_id = 9, .user_id = 1, .time = 300, .segments = &.{} },
    };
    try std.testing.expectEqual(@as(?i64, 2), oldestId(&a_first));

    const b_first = [_]onebot.Message{
        .{ .message_id = 2, .user_id = 1, .time = 100, .segments = &.{} },
        .{ .message_id = 5, .user_id = 1, .time = 100, .segments = &.{} },
        .{ .message_id = 9, .user_id = 1, .time = 300, .segments = &.{} },
    };
    try std.testing.expectEqual(@as(?i64, 2), oldestId(&b_first));
}
