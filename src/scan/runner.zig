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

/// 一个群这一轮里出的岔子。三类分开计数，因为它们的后果不一样，运营方需要
/// 从群里那一行 `Failed:` 直接看出是哪一类：
///   - revoke_failed：撤稿没落盘。**最严重的一类**——那条 💦 明天就滑出窗口，
///     永远不会被重新看到，而语录还在公网上可以被随机到。
///   - add_failed：语录没写进库。下一次扫描窗口还包含它的话会重试。
///   - unattributed：群名/群名片没问出来，这一批候选整批没写（见 scanGroup）。
pub const Trouble = struct {
    revoke_failed: usize = 0,
    add_failed: usize = 0,
    unattributed: usize = 0,
    last_err: []const u8 = "",

    pub fn any(self: Trouble) bool {
        return self.revoke_failed > 0 or self.add_failed > 0 or self.unattributed > 0;
    }
};

/// 把 Trouble 组装成 `Failed:` 后面那段原因串。多类同时发生时用 "; " 串起来，
/// 一行说清楚，不发多行——群里那几行日志是运营方唯一的运行信号，行数固定才好核对。
pub fn troubleReason(gpa: std.mem.Allocator, t: Trouble) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var w = out.writer(gpa);

    if (t.revoke_failed > 0) {
        try w.print("{d} revocation(s) failed", .{t.revoke_failed});
    }
    if (t.add_failed > 0) {
        if (out.items.len > 0) try w.writeAll("; ");
        try w.print("{d} quote(s) failed to save", .{t.add_failed});
    }
    if (t.unattributed > 0) {
        if (out.items.len > 0) try w.writeAll("; ");
        try w.print("{d} quote(s) not written: group attribution unavailable", .{t.unattributed});
    }
    if (t.last_err.len > 0) {
        try w.print(" (last error: {s})", .{t.last_err});
    }
    return out.toOwnedSlice(gpa);
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

/// 取群名。**null 与空串是两回事**：空串表示"问到了，这个群就是没名字"，
/// null 表示"这次没问出来"（请求失败 / 响应不是对象 / 没有 group_name 字段 /
/// 值不是字符串）。调用方靠这个区分要不要把这批语录写进库——buildQuote 会把
/// from 原样烧进每一条语录，而设计里没有任何事后编辑的路径，一次 API 抖动
/// 就会让这一批语录永远带着空归属对外服务。
fn groupName(deps: Deps, arena: std.mem.Allocator, group_id: u64) ?[]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(.{ .group_id = group_id }, .{}, &aw.writer) catch |e| {
        std.log.warn("group {d}: building get_group_info request failed: {s}", .{ group_id, @errorName(e) });
        return null;
    };
    const data = deps.nap.callData(arena, "get_group_info", aw.written()) catch |e| {
        std.log.warn("group {d}: get_group_info failed: {s}", .{ group_id, @errorName(e) });
        return null;
    };
    const obj = switch (data) {
        .object => |o| o,
        else => {
            std.log.warn("group {d}: get_group_info returned a non-object", .{group_id});
            return null;
        },
    };
    const v = obj.get("group_name") orelse {
        std.log.warn("group {d}: get_group_info reply has no group_name field", .{group_id});
        return null;
    };
    return switch (v) {
        .string => |s| s,
        else => {
            std.log.warn("group {d}: get_group_info group_name is not a string", .{group_id});
            return null;
        },
    };
}

/// 取被观察者在这个群里的名片（群名片优先，其次昵称）。null / 空串的区分同
/// groupName：两个字段都缺是"没问出来"，两个字段都在但都是空是"这人确实
/// 没设名片也没有昵称"。
fn observedCard(deps: Deps, arena: std.mem.Allocator, group_id: u64) ?[]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(.{
        .group_id = group_id,
        .user_id = deps.observed_qq,
        .no_cache = true,
    }, .{}, &aw.writer) catch |e| {
        std.log.warn("group {d}: building get_group_member_info request failed: {s}", .{ group_id, @errorName(e) });
        return null;
    };
    const data = deps.nap.callData(arena, "get_group_member_info", aw.written()) catch |e| {
        std.log.warn("group {d}: get_group_member_info failed: {s}", .{ group_id, @errorName(e) });
        return null;
    };
    const obj = switch (data) {
        .object => |o| o,
        else => {
            std.log.warn("group {d}: get_group_member_info returned a non-object", .{group_id});
            return null;
        },
    };
    var seen_any = false;
    for ([_][]const u8{ "card", "nickname" }) |k| {
        if (obj.get(k)) |v| {
            seen_any = true;
            if (v == .string and v.string.len > 0) return v.string;
        }
    }
    if (!seen_any) {
        std.log.warn("group {d}: get_group_member_info reply has neither card nor nickname", .{group_id});
        return null;
    }
    return "";
}

/// 一页历史的拉取结果。
///
/// `stop` 非空表示这一页没能提供继续翻页的依据，同时**说明是哪种情况**。
/// 原先 fetchPage 对"翻到群历史开头了"（正常）和"NapCat 回了个看不懂的东西"
/// （README 线上假设 #1 正在失效）都返回同一个 `&.{}`，两者在日志里完全无法
/// 分辨；而后者意味着窗口没被完整覆盖，漏掉的不只是语录，还有作废指令——
/// 作废指令漏掉就永远不会被重看一次。
pub const Page = struct {
    msgs: []onebot.Message,
    stop: ?[]const u8,
};

/// 从 get_group_msg_history 的 data 与解析出的条数，判断"这一页为什么不能再往前翻"。
/// null 表示这一页正常。抽成纯函数是为了能单测：翻页截断的可见性正是 I3 的全部内容，
/// 而 fetchPage 本身要发 HTTP，测不了。
pub fn pageStopReason(data: std.json.Value, parsed_len: usize) ?[]const u8 {
    const obj = switch (data) {
        .object => |o| o,
        else => return "get_group_msg_history reply was not an object",
    };
    const arr = obj.get("messages") orelse
        return "get_group_msg_history reply has no messages field";
    if (parsed_len > 0) return null;
    const raw_len: usize = switch (arr) {
        .array => |items| items.items.len,
        else => return "get_group_msg_history messages field is not an array",
    };
    return if (raw_len == 0)
        "empty page (reached the start of the group's history)"
    else
        "page carried messages but none of them could be parsed";
}

fn fetchPage(
    deps: Deps,
    arena: std.mem.Allocator,
    group_id: u64,
    before_id: ?i64,
) !Page {
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
    const arr: std.json.Value = switch (data) {
        .object => |o| o.get("messages") orelse .{ .null = {} },
        else => .{ .null = {} },
    };
    // parseMessages 对 null / 非数组一律返回空切片，形状判断统一交给
    // pageStopReason，这里不重复判一遍。
    const msgs = try onebot.parseMessages(arena, arr);
    return .{ .msgs = msgs, .stop = pageStopReason(data, msgs.len) };
}

/// 每页打一行 info：页序号、条数、最老/最新一条的 message_id 与 time。
/// README 的两条线上假设都靠这行核对——#1（`message_seq` 是不是 `message_id`）
/// 看相邻两页的时间是否连续、有没有大段跳跃；#2（`message_seq` 边界是否闭区间）
/// 看相邻两页的首尾 message_id 有没有重叠。ReleaseSafe 下 std.log 的默认级别
/// 就是 info，所以按 README 的推荐构建方式跑起来就能直接看到。
fn logPage(gid: u64, page_index: usize, msgs: []const onebot.Message) void {
    if (msgs.len == 0) return;
    var oldest = msgs[0];
    var newest = msgs[0];
    for (msgs[1..]) |m| {
        if (m.time < oldest.time or (m.time == oldest.time and m.message_id < oldest.message_id)) oldest = m;
        if (m.time > newest.time or (m.time == newest.time and m.message_id > newest.message_id)) newest = m;
    }
    std.log.info(
        "group {d}: history page {d}: {d} message(s); oldest message_id={d} time={d}; newest message_id={d} time={d}",
        .{ gid, page_index, msgs.len, oldest.message_id, oldest.time, newest.message_id, newest.time },
    );
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
    // 真正拉到内容的页数。跟 guard 不是一回事：最后一次 fetchPage 可能什么都
    // 没拿到（翻到头了 / 响应看不懂），那一次不算一页。警告里报的是这个数。
    var pages: usize = 0;
    // 循环跑满 200 页而没走到任何一个 break 时留下的原因；下面每个 break
    // 之前都会覆盖它。
    var stop_reason: []const u8 = "page guard exhausted (200 pages)";

    while (guard < 200) : (guard += 1) {
        const page = try fetchPage(deps, a, gid, before);
        if (page.stop) |why| {
            stop_reason = why;
            break;
        }
        try pool.appendSlice(a, page.msgs);
        logPage(gid, pages, page.msgs);
        pages += 1;

        const oldest = oldestTime(page.msgs) orelse {
            stop_reason = "page carried no usable timestamp";
            break;
        };
        const next_before = oldestId(page.msgs) orelse {
            stop_reason = "page carried no usable message_id";
            break;
        };
        if (before != null and next_before == before.?) { // 不再前进，防死循环
            stop_reason = "pagination anchor stopped advancing (NapCat returned the same page again)";
            break;
        }
        before = next_before;

        // reached_start 单独一个标志就足以实现"再多拉一页"：本次迭代刚拉到的
        // 这一页就是缓冲页——上一轮已经看到过窗口外的消息了，这里再 break 出去。
        if (reached_start) break;
        if (oldest < win_start) reached_start = true;
    }

    // 翻页没走到窗口起点 = 这一轮只看到了窗口的一部分，而 runOnce 之后照样会
    // setLastRun，漏掉的那一段永远不会被重扫。漏掉的不只是语录（那还有明天的
    // 窗口兜一次），还有作废指令——💦 只会被看到一次，漏了就是永久漏了。
    // 所以这里必须留下可见的痕迹，而不是安静地按截断后的结果报 Successfully.。
    if (!reached_start) {
        std.log.warn(
            "group {d}: history window NOT fully covered — stopped after {d} page(s) with {d} message(s) pooled, before reaching window start {d}; reason: {s}. Messages and 💦 revocations older than this run's oldest page were never examined and will not be revisited.",
            .{ gid, pages, pool.items.len, win_start, stop_reason },
        );
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
        if (napcat.hasStarReaction(data)) {
            try star_ids.append(a, m.message_id);
            continue;
        }
        // design.md §3.3 要求把未匹配的 emoji_id 打进日志，README 线上假设 #4
        // 靠它核对 ✨ 的真实 emoji_id：这个常量要是错了，扫描器一条都收不到，
        // 现象跟"今天真的没人贴 ✨"一模一样，不会报任何错。只在这条消息确实有
        // 表情回应、且一个都没匹配上时打，避免给没有任何回应的消息刷屏。
        const seen = napcat.emojiIdsSummary(a, data) catch continue;
        if (seen.len > 0) std.log.info(
            "group {d}: message {d} carries emoji reactions but none matched star_emoji_id={s}: {s}",
            .{ gid, m.message_id, napcat.star_emoji_id, seen },
        );
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
    var trouble: Trouble = .{};
    for (outcome.revoked) |rid| {
        deps.st.revoke(rid) catch |e| {
            // 作废失败必须跟入库失败一样压掉 Successfully. 与 setLastRun。
            // 它其实更严重：这条 💦 明天就滑出 24h 窗口，之后任何一次扫描都
            // 不会再看到它，撤稿请求就此永久丢失，而那条语录仍然公开可查。
            // 只打一条 warn 然后照常报 Successfully. 是这个产品里最坏的失败模式。
            std.log.warn("group {d}: revoke {d} failed: {s}", .{ gid, rid, @errorName(e) });
            trouble.revoke_failed += 1;
            trouble.last_err = @errorName(e);
        };
    }

    // ---- 7. 过滤并入库 ----
    const from = groupName(deps, a, gid);
    const from_who = observedCard(deps, a, gid);
    // 归属信息没问出来就一条都不写：buildQuote 把 from/from_who 原样烧进每一条
    // 语录，而设计里没有任何事后编辑的路径——一次 get_group_info 抖动会让这一批
    // 语录永远带着空的 from/from_who 对外服务。宁可整批不写、这个群算失败、
    // 不 setLastRun，等重启补跑或者下一次扫描重来：候选仍在窗口里，
    // isTombstoned/exists 保证重扫是幂等的。
    const attributed = from != null and from_who != null;

    var added: usize = 0;
    var skipped: usize = 0;

    if (attributed) {
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
                .from = from.?,
                .from_who = from_who.?,
                .created_at = if (target) |t| t.time else win_end,
                .message_id = cand.message_id,
                .group_id = gid,
                .user_id = if (target) |t| t.user_id else deps.observed_qq,
            });
            defer freeQuote(deps.gpa, q);

            // store.add 失败与"被关卡拦下"是两码事（spec §7 的 skipped 特指后者），
            // 单独计数，不混进 skipped。
            deps.st.add(q) catch |e| {
                std.log.warn("group {d}: add {d} failed: {s}", .{ gid, cand.message_id, @errorName(e) });
                trouble.add_failed += 1;
                trouble.last_err = @errorName(e);
                continue;
            };
            added += 1;
        }
    } else {
        trouble.unattributed = outcome.candidates.len;
    }

    const result = try resultLine(deps.gpa, added, skipped);
    defer deps.gpa.free(result);
    sendLine(deps, gid, result);

    // 出过岔子就不能用 Successfully. 收尾——那是运营方唯一的"这次跑成功了"信号。
    // 改发 Failed 行，带上各类失败的条数与最后一次的错误原因。
    if (trouble.any()) {
        const reason = try troubleReason(deps.gpa, trouble);
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

test "Trouble.any 只在真出过岔子时为真" {
    try std.testing.expect(!(Trouble{}).any());
    try std.testing.expect((Trouble{ .revoke_failed = 1 }).any());
    try std.testing.expect((Trouble{ .add_failed = 1 }).any());
    try std.testing.expect((Trouble{ .unattributed = 1 }).any());
    // last_err 单独存在不算岔子（它只是给上面三类计数配的说明）
    try std.testing.expect(!(Trouble{ .last_err = "ReadFailed" }).any());
}

test "troubleReason：作废失败单独成句，且一定出现在 Failed 行里" {
    const gpa = std.testing.allocator;
    const r = try troubleReason(gpa, .{ .revoke_failed = 2, .last_err = "ConnectionFailed" });
    defer gpa.free(r);
    try std.testing.expectEqualStrings("2 revocation(s) failed (last error: ConnectionFailed)", r);
}

test "troubleReason：入库失败沿用原来的措辞" {
    const gpa = std.testing.allocator;
    const r = try troubleReason(gpa, .{ .add_failed = 3, .last_err = "RedisError" });
    defer gpa.free(r);
    try std.testing.expectEqualStrings("3 quote(s) failed to save (last error: RedisError)", r);
}

test "troubleReason：多类同时发生时串成一行，顺序固定" {
    const gpa = std.testing.allocator;
    const r = try troubleReason(gpa, .{
        .revoke_failed = 1,
        .add_failed = 2,
        .unattributed = 4,
        .last_err = "WriteFailed",
    });
    defer gpa.free(r);
    try std.testing.expectEqualStrings(
        "1 revocation(s) failed; 2 quote(s) failed to save; 4 quote(s) not written: group attribution unavailable (last error: WriteFailed)",
        r,
    );
}

test "troubleReason：归属拿不到时没有 last_err，不带尾巴" {
    const gpa = std.testing.allocator;
    const r = try troubleReason(gpa, .{ .unattributed = 5 });
    defer gpa.free(r);
    try std.testing.expectEqualStrings("5 quote(s) not written: group attribution unavailable", r);
}

fn troubleReasonUnderFailingAllocator(gpa: std.mem.Allocator) !void {
    const r = try troubleReason(gpa, .{ .revoke_failed = 1, .add_failed = 1, .unattributed = 1, .last_err = "X" });
    gpa.free(r);
}

test "OOM 回归：troubleReason 在任意分配点失败都不泄漏" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, troubleReasonUnderFailingAllocator, .{});
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

fn jsonVal(arena: std.mem.Allocator, src: []const u8) !std.json.Value {
    const p = try std.json.parseFromSlice(std.json.Value, arena, src, .{});
    return p.value;
}

test "pageStopReason 区分「翻到头了」与「响应看不懂」" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    // 正常页：能继续翻
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        pageStopReason(try jsonVal(a, "{\"messages\":[{}]}"), 1),
    );

    // 空数组 = 群历史到头了，属于正常收尾
    try std.testing.expectEqualStrings(
        "empty page (reached the start of the group's history)",
        pageStopReason(try jsonVal(a, "{\"messages\":[]}"), 0).?,
    );

    // 下面三种都是"响应看不懂"，跟到头了必须能分辨——原先它们全都退化成同一个
    // `&.{}`，日志里看不出区别，而这三种意味着窗口没被完整覆盖。
    try std.testing.expectEqualStrings(
        "page carried messages but none of them could be parsed",
        pageStopReason(try jsonVal(a, "{\"messages\":[{\"nope\":1},{\"nope\":2}]}"), 0).?,
    );
    try std.testing.expectEqualStrings(
        "get_group_msg_history reply has no messages field",
        pageStopReason(try jsonVal(a, "{\"data\":[]}"), 0).?,
    );
    try std.testing.expectEqualStrings(
        "get_group_msg_history reply was not an object",
        pageStopReason(try jsonVal(a, "[]"), 0).?,
    );
    try std.testing.expectEqualStrings(
        "get_group_msg_history messages field is not an array",
        pageStopReason(try jsonVal(a, "{\"messages\":\"nope\"}"), 0).?,
    );
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
