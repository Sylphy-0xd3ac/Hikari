const std = @import("std");
const napcat = @import("../napcat.zig");
const onebot = @import("../onebot.zig");
const rules = @import("rules.zig");
const store = @import("../store.zig");
const uuid = @import("../uuid.zig");
const scheduler = @import("../scheduler.zig");
const redis = @import("../redis/client.zig");
const resp = @import("../redis/resp.zig");

pub const page_size: usize = 200;

pub const banner = [3][]const u8{
    "Hikari!",
    "Made with ❤️ by CuzTeam, AmethystDevs-Lab",
    "Thanks to collaborators: 恩恩hhh, apanzinc, Lonely, 小晴同学, Sylphy",
};
pub const processing_line = "Processing...";

pub fn willProcessLine(gpa: std.mem.Allocator, n: usize) ![]u8 {
    return std.fmt.allocPrint(gpa, "Will process {d} messages.", .{n});
}

pub fn resultLine(gpa: std.mem.Allocator, added: usize, skipped: usize) ![]u8 {
    return std.fmt.allocPrint(gpa, "Added {d} messages, skipped {d} messages.", .{ added, skipped });
}

pub fn failedLine(gpa: std.mem.Allocator, reason: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "Failed: {s}", .{reason});
}

/// 收尾行，带上这个群这一轮扫描花了多少整秒——运营方要求的改动，同一枚硬币
/// 的另一面是 `Failed:` 那一行故意不带耗时（一次失败跑的耗时不提供任何信息，
/// 见 scanGroup 里 trouble.any() 分支）。`elapsed_s` 允许是负数（时钟被 NTP
/// 往回拨、或者注入的测试时钟本身没保证单调）时钳制到 0——打印一个负的耗时
/// 比"看起来耗时为 0"更让人费解，0 至少是个诚实的"测不出来"信号。跟其他三个
/// builder（willProcessLine/resultLine/failedLine）同一种签名形状、同一种
/// allocator 纪律：一次 allocPrint，失败原样把 OOM error 交给调用方。
pub fn successLine(gpa: std.mem.Allocator, elapsed_s: i64) ![]u8 {
    const clamped: i64 = if (elapsed_s > 0) elapsed_s else 0;
    return std.fmt.allocPrint(gpa, "Successfully in {d}s.", .{clamped});
}

/// 一个群这一轮里出的岔子。三类分开计数，因为它们的后果不一样，运营方需要
/// 从群里那一行 `Failed:` 直接看出是哪一类：
///   - revoke_failed：撤稿没落盘。**最严重的一类**——它跟其他两类一样会让
///     这个群这一轮判失败、不写 setLastRun，所以下一次扫描（受 7 天回看
///     上限约束）还会覆盖到这条消息、有机会重放撤稿；但那个上限一过，
///     这条 💦 就永久丢了，而语录还在公网上可以被随机到，所以仍然要单独
///     计数、单独在 Failed 行里报出来。
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
    // 默认 "hikari"：扫描器的调用点全部不设置这个字段，行为不变。
    // import.zig 显式传 "import"，让手工导入的语录在库里和 API 响应里都能
    // 跟扫描产生的语录区分开。
    commit_from: []const u8 = "hikari",
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
    q.commit_from = try gpa.dupe(u8, a.commit_from);
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
    observed_qqs: []const u64,
    admin_qqs: []const u64,
    group_ids: []const u64,
    /// getMsg 单次重试前的等待时长。生产上 24/2300 探针在负载压力下失败，紧接着
    /// 立刻重试大概率撞上同一波拥堵（这轮扫描本身就在跟 get_group_info/
    /// get_group_member_info/回复补拉/合并转发挤同一条 NapCat 连接），留几百毫秒
    /// 给它消退。默认 300ms。测试把它设成 0：既不依赖真实时钟就能覆盖"先失败一次、
    /// 重试成功"的路径，也不会为了跑测试套件真的等一次 300ms。
    get_msg_retry_delay_ns: u64 = 300 * std.time.ns_per_ms,
    /// scanGroup 拿来量"这个群这一轮扫了多久"的挂钟读数源，默认就是本仓库其它
    /// 地方都在用的 `std.time.timestamp`（main.zig 的调度循环、hikari import
    /// 都是这一个）——特意不引入单独的单调时钟抽象，耗时本来就只要求秒级精度，
    /// 犯不上为它多背一套时钟类型。做成函数指针字段纯粹是为了可测：一次
    /// scanGroup 调用里恰好读两次（进入时、Successfully 那一行成文时），
    /// 生产路径两次读的都是真实墙钟；测试把它换成一个每次调用按固定序列出值
    /// 的桩函数，这样端到端测试锁死的那段 JSON 字节里，耗时数字就不再是
    /// "測出来" 的、跑多慢都不一样的噪声，而是测试自己钦定的确定值。
    clock: *const fn () i64 = std.time.timestamp,
};

/// 需要"某一个具体 QQ"而不是集合的兜底场合：合并转发 node 的头像 id、以及
/// 目标消息缺失时 Quote.user_id 的兜底值。观察全员（空集）时没有那一个人，
/// 返回 null，由调用方各自决定怎么退化。
fn soleObserved(deps: Deps) ?u64 {
    return if (deps.observed_qqs.len == 0) null else deps.observed_qqs[0];
}

/// 一个群这一轮里 getMsg 重试的效果统计：命中过重试的调用次数，以及重试真的把
/// 结果救回来的次数（第二次成功）。只在 scanGroup 这一次调用的作用域内存在、
/// 随之清零——不跨群累积，避免"这个群这一轮到底救回来几次"被前面群的旧数字
/// 稀释掉。
const GetMsgStats = struct {
    retried: usize = 0,
    retry_rescued: usize = 0,
};

/// 把一行文案排进这个群待发的合并转发队列（`lines`）。这条队列在整个
/// scanGroup 运行期间只增不减，直到 runOnce 在这个群的扫描收尾（不管是正常
/// 走完还是中途出 `try` 错误被 catch 住）时一次性打包成一条
/// `send_group_forward_msg` 发出去。
///
/// 失败（本质只会是 arena 背后的 gpa OOM）只打警告、丢这一行，不让整轮扫描
/// 因为排队失败而中断——这个姿态跟旧版 sendLine 网络发送失败时"只 warn 不
/// 中断"是一路的，只是失败点从"发送"挪到了"排队"。
fn pushLine(a: std.mem.Allocator, lines: *std.ArrayList([]const u8), group_id: u64, text: []const u8) void {
    lines.append(a, text) catch |e| {
        std.log.warn("group {d}: failed to queue line into forward message ({s}): {s}", .{ group_id, @errorName(e), text });
    };
}

/// send_group_forward_msg 一个 node 段的三层结构：node → data → content[] →
/// {type:"text", data:{text}}。字段名、嵌套层数、`user_id` 是字符串这几点
/// 都照抄针对生产 NapCat 探测到的真实请求体（见本次改动的设计说明），不是
/// 猜的。
const ForwardTextData = struct { text: []const u8 };
const ForwardContentItem = struct {
    type: []const u8 = "text",
    data: ForwardTextData,
};
const ForwardNodeData = struct {
    user_id: []const u8,
    nickname: []const u8 = "Hikari",
    content: [1]ForwardContentItem,
};
const ForwardNode = struct {
    type: []const u8 = "node",
    data: ForwardNodeData,
};

fn forwardNode(user_id: []const u8, text: []const u8) ForwardNode {
    return .{ .data = .{ .user_id = user_id, .content = .{.{ .data = .{ .text = text } }} } };
}

/// 把 lines 拼成 send_group_forward_msg 的请求体。nodes 数组和最终 JSON 串
/// 全部分配在调用方传入的 arena 里：任何一步分配失败，arena 在 runOnce 那层
/// `defer ar.deinit()` 时会把之前已经分配出去的 node 一并释放——arena 本身
/// 就是 store.zig hashFields / buildQuote 那种手写 errdefer 链在这里的等价物，
/// 不需要再逐个 node 手写一遍。
fn buildForwardBody(a: std.mem.Allocator, group_id: u64, user_id: []const u8, lines: []const []const u8) ![]u8 {
    const nodes = try a.alloc(ForwardNode, lines.len);
    for (lines, 0..) |line, i| nodes[i] = forwardNode(user_id, line);

    var aw: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(.{
        .group_id = group_id,
        .messages = nodes,
    }, .{}, &aw.writer);
    return aw.toOwnedSlice();
}

/// 把这个群排好队的 lines 打包成一条合并转发消息发出去。`lines` 为空时
/// 什么都不发——正常路径下 runOnce 已经无条件排过横幅+Processing 两行，
/// 这个分支只在那两行都排队失败（见 pushLine）的极端情况下才会命中。
fn sendForward(deps: Deps, a: std.mem.Allocator, group_id: u64, bot_qq: u64, lines: []const []const u8) void {
    if (lines.len == 0) return;

    const uid = std.fmt.allocPrint(a, "{d}", .{bot_qq}) catch |e| {
        std.log.warn("group {d}: formatting bot user_id failed ({s}); forward message not sent", .{ group_id, @errorName(e) });
        return;
    };
    const body = buildForwardBody(a, group_id, uid, lines) catch |e| {
        std.log.warn("group {d}: building send_group_forward_msg payload failed ({s}); forward message not sent", .{ group_id, @errorName(e) });
        return;
    };
    _ = deps.nap.callData(a, "send_group_forward_msg", body) catch |e| {
        std.log.warn("send_group_forward_msg failed for group {d}: {s}", .{ group_id, @errorName(e) });
    };
}

/// 每次 runOnce 只问一次 get_login_info，取到的机器人 QQ 供全部群、全部
/// node 复用（design 要求"取一次、逐群逐 node 复用"）。失败——网络、响应
/// 格式不对、字段缺失或不是数字——一律退回 OBSERVED_QQ 并打警告：这个值
/// 只影响合并转发里 node 显示的头像，选错是观感问题，不值得为它中断整轮
/// 扫描，更不该因为取不到就不发日志了。
fn fetchBotQq(deps: Deps) u64 {
    var ar = std.heap.ArenaAllocator.init(deps.gpa);
    defer ar.deinit();
    const a = ar.allocator();

    const data = deps.nap.callData(a, "get_login_info", "{}") catch |e| {
        const fb = soleObserved(deps) orelse 0;
        std.log.warn("get_login_info failed ({s}); forward messages will use {d} as the node avatar", .{ @errorName(e), fb });
        return fb;
    };
    const obj = switch (data) {
        .object => |o| o,
        else => {
            const fb = soleObserved(deps) orelse 0;
            std.log.warn("get_login_info returned a non-object; forward messages will use {d} as the node avatar", .{fb});
            return fb;
        },
    };
    const v = obj.get("user_id") orelse {
        const fb = soleObserved(deps) orelse 0;
        std.log.warn("get_login_info reply has no user_id field; forward messages will use {d} as the node avatar", .{fb});
        return fb;
    };
    const n = onebot.asInt(v) orelse {
        const fb = soleObserved(deps) orelse 0;
        std.log.warn("get_login_info user_id is not a number; forward messages will use {d} as the node avatar", .{fb});
        return fb;
    };
    if (n < 0) {
        const fb = soleObserved(deps) orelse 0;
        std.log.warn("get_login_info user_id is negative ({d}); forward messages will use {d} as the node avatar", .{ n, fb });
        return fb;
    }
    return @intCast(n);
}

/// 取群名。**null 与空串是两回事**：空串表示"问到了，这个群就是没名字"，
/// null 表示"这次没问出来"（请求失败 / 响应不是对象 / 没有 group_name 字段 /
/// 值不是字符串）。调用方靠这个区分要不要把这批语录写进库——buildQuote 会把
/// from 原样烧进每一条语录，而设计里没有任何事后编辑的路径，一次 API 抖动
/// 就会让这一批语录永远带着空归属对外服务。
pub fn groupName(deps: Deps, arena: std.mem.Allocator, group_id: u64) ?[]const u8 {
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
pub fn observedCard(deps: Deps, arena: std.mem.Allocator, group_id: u64) ?[]const u8 {
    // 观察全员时没有"那一个被观察者"可查群名片。逐条语录按作者解析显示名是
    // 下一步（hikari:username:{user_id} 查表）的事，这里先老实返回 null，让
    // 既有的"归属取不到就让这个群失败"逻辑接手，而不是编一个名字出来。
    const who = soleObserved(deps) orelse return null;
    var aw: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(.{
        .group_id = group_id,
        .user_id = who,
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
        // 线上探针实测：NapCat 把 reverse_order 解成"从锚点往哪个方向走"，
        // 不是"结果要不要倒序"。reverse_order=false 从锚点往新的方向走，
        // 拿 before_id（上一页最老的 message_id）当锚点时会原地把上一页
        // 整页原样再拿一遍——生产上第一轮就是这么卡死在第 2 页的（同一页
        // message_id/time 完全重复）。往回翻必须传 reverse_order=true。
        // 另外 message_seq 是闭区间：锚点消息本身会再出现在这一页里，
        // 这是刻意接受的重复（见 rules.appendCandidate 的去重与
        // README 线上假设 #2），不在这里处理。
        try std.json.Stringify.value(.{
            .group_id = group_id,
            .message_seq = bid,
            .count = page_size,
            .reverse_order = true,
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

/// 单次 get_msg 调用，失败**恰好重试一次**——policy 跟 redis.Client.command 的
/// "传输层失败拆连接重拨、只重试一次"是同一个纪律：生产实测显示这类失败是
/// 跟同一时间窗口内其它 NapCat 调用挤在一起造成的瞬时拥堵，不是消息真的没了
/// （431/431 事后逐条 get_msg 都拿到了 status: ok），所以值得再试一次；但
/// 无限重试/退避梯度换不来更多确定性，只会在真出问题时把一次卡顿放大成
/// 扫描线程长时间不动。第二次还失败就如实返回 null，调用方原有的警告照常
/// 触发，行为跟改动前一致。
///
/// 重试前的等待只发生在第一次失败之后——成功路径（生产里 431 次探针的绝大
/// 多数）不付一分钱延迟：`deps.get_msg_retry_delay_ns` 默认 300ms，
/// 431 次都睡这么久会平白给每天的扫描加 129.3 秒（≈2.15 分钟），这里的分支结构保证了
/// sleep 只在真的要重试时才执行。
///
/// arena 归属：两次尝试（包括请求体的 Stringify 与 callData 内部的 HTTP 响应/
/// JSON 解析）全部分配在调用方传入的同一份 arena 里，never freed individually——
/// 这正是本文件里 fetchPage/buildForwardBody 等函数一贯的用法。第一次失败留下
/// 的那些中间缓冲区不会被显式释放，但也不会被重复释放或造成悬垂引用：它们只是
/// 跟着 arena 活到 scanGroup 收尾时一次性 deinit，不是逐次 malloc/free 意义上的
/// 内存泄漏，是这套代码里其它多次调用同一个 arena 的函数（比如翻页循环里每页
/// 都往同一个 pool 追加）共享的同一种权衡。
fn getMsg(deps: Deps, arena: std.mem.Allocator, message_id: i64, stats: *GetMsgStats) ?std.json.Value {
    var aw: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(.{ .message_id = message_id }, .{}, &aw.writer) catch return null;
    const body = aw.written();

    if (deps.nap.callData(arena, "get_msg", body)) |v| return v else |_| {}

    stats.retried += 1;
    if (deps.get_msg_retry_delay_ns > 0) std.Thread.sleep(deps.get_msg_retry_delay_ns);

    const retried = deps.nap.callData(arena, "get_msg", body) catch return null;
    stats.retry_rescued += 1;
    return retried;
}

/// 单个群这一轮该不该写它自己的 `hikari:lastrun:{group_id}`：只在这个群
/// 本身成功（`ok == true`）时写。抽成独立函数，一是让 runOnce 的循环体
/// 读起来是"扫、然后按结果决定写不写"这一步一步，二是让这条"失败的群不写、
/// 成功的群写"的规则能绕开 scanGroup（依赖真实 NapCat HTTP，测试环境起不来）
/// 直接单测：只需要一个 *Store，不需要一整套 Deps/NapCat。
fn applyLastRun(st: *store.Store, group_id: u64, ok: bool, run_at: i64) void {
    if (!ok) return;
    st.setLastRun(group_id, run_at) catch |e| {
        std.log.warn("group {d}: setLastRun failed: {s}", .{ group_id, @errorName(e) });
    };
}

/// 单个群这一轮扫描窗口的起点：读它自己的 `hikari:lastrun:{group_id}`交给
/// `scheduler.windowStart` 算。抽成独立函数的理由跟 applyLastRun 一样——
/// 绕开 scanGroup 依赖的真实 NapCat HTTP，只用一个 *Store 就能单测。
///
/// Redis 读失败时退化成 `null`（等价于"这个群从未跑过"，回退到固定 24h
/// 窗口）而不是让这个群直接判失败——一次读抖动不该白白跳过整个群。但这个
/// 退化必须留痕：不打警告的话，"该扫 5 天却只扫了 24h" 跟 "这个群真的
/// 从未跑过" 在日志里长得一模一样，没人会去怀疑扫描范围不对。
///
/// `clamped`（停机跨度超过 7 天回看上限）也在这里报警：那一段里的 💦
/// 撤稿指令永久不可恢复，运营方需要知道是哪个群、丢了哪一段时间。
fn resolveWindowStart(st: *store.Store, group_id: u64, run_at: i64) i64 {
    const last_run = st.getLastRun(group_id) catch |e| blk: {
        std.log.warn(
            "group {d}: getLastRun failed ({s}); falling back to a fixed 24h window instead of the real catch-up span since last run",
            .{ group_id, @errorName(e) },
        );
        break :blk null;
    };
    const win = scheduler.windowStart(run_at, last_run);
    if (win.clamped) {
        std.log.warn(
            "group {d}: downtime since last run ({d}s) exceeds the {d}s lookback cap — window clamped to start at {d}; the dropped span [{d}, {d}) will never be rescanned and any 💦 revocations in it are unrecoverable",
            .{ group_id, run_at - last_run.?, scheduler.max_lookback_seconds, win.start, last_run.?, win.start },
        );
    }
    return win.start;
}

/// 跑一次完整扫描。失败不抛出，改为在日志里发 Failed 行。
///
/// `hikari:lastrun:{group_id}` 是逐群独立的键（见 store.zig lastRunKey）：
/// 每个群只在它自己这一轮成功时才写自己的键，失败的群完全不写，不受同一轮
/// 里其他群成不成功影响。这样一个群的失败不会被兄弟群的成功掩盖——重启补跑
/// （main.zig）逐群读这个键，只有失败的那个群会被判定为"漏跑"而重新扫描。
///
/// 扫描窗口的起点逐群计算（`resolveWindowStart`），不在循环外算一次共用：
/// `last_run` 本身就是逐群独立的状态，固定在循环外算等于假装所有群这一轮
/// 该回看的跨度都一样——它们并不一样。
pub fn runOnce(deps: Deps, run_at: i64) void {
    // design.md §7 要求这个 QQ 每轮只问一次、逐群逐 node 复用；放在两个 for
    // 循环之前，早于任何一个群的扫描。
    const bot_qq = fetchBotQq(deps);

    for (deps.group_ids) |gid| {
        // 每个群一份独立的 arena，寿命跨过 scanGroup 的成功/失败两条路径，
        // 直到这个群的合并转发发出去才 deinit——这是"崩溃不等于安静"这条
        // 约束的关键：scanGroup 中途 `try` 出错时，它自己再也没有机会碰这份
        // 内存了，但只要 arena 还活着，已经排进 lines 的那几行（横幅、
        // Processing...、也许还有 Will process）连同后面补上的 Failed 行
        // 依然能被 sendForward 打包发出去，而不是随 scanGroup 的报错一起
        // 消失。
        var ar = std.heap.ArenaAllocator.init(deps.gpa);
        defer ar.deinit();
        const a = ar.allocator();

        var lines: std.ArrayList([]const u8) = .empty;
        for (banner) |line| pushLine(a, &lines, gid, line);
        pushLine(a, &lines, gid, processing_line);

        const win_start = resolveWindowStart(deps.st, gid, run_at);
        const ok = scanGroup(deps, a, &lines, gid, win_start, run_at) catch |e| catch_blk: {
            const msg = failedLine(a, @errorName(e)) catch {
                // 格式化 Failed 行本身失败（理论上只会是 arena 背后的 gpa
                // OOM）：不能因此中断整个 runOnce——那样会连带跳过其余尚未
                // 处理的群。已经排进 lines 的内容仍会照常合并转发出去，只是
                // 少了最后一行的说明；只记警告，把这个群计为失败，继续处理
                // 下一个群。
                std.log.warn("group {d}: scanGroup failed ({s}) and failedLine formatting also failed", .{ gid, @errorName(e) });
                break :catch_blk false;
            };
            pushLine(a, &lines, gid, msg);
            break :catch_blk false;
        };
        applyLastRun(deps.st, gid, ok, run_at);

        // 不管这一轮是正常收尾还是在 scanGroup 中途被 catch 住，lines 里已经
        // 排队的内容都要发出去：哪怕只排进了横幅四行就崩了，群里也会看到那
        // 四行 + 一行 Failed，而不是彻底沉默。
        sendForward(deps, a, gid, bot_qq, lines.items);
    }
}

/// 翻页时锚点没能前进（`next_before == before`）：判断这是"翻到群历史最开头
/// 了"这种合法终止，还是 NapCat 真的出了岔子。`message_seq` 是闭区间，锚点
/// 消息本身会重复出现在锚定的那一页里，所以"锚点没前进"现在（`reverse_order:
/// true` 修好之后）有两种截然不同的成因：
///   - 这一页**只有锚点自己一条**：往回已经没有更老的消息了，翻到了群历史
///     的最开头，是正常收尾。
///   - 这一页不止一条，或者那一条不是锚点本身：锚点没有真的推进过，这是
///     生产上第一轮踩到的那种 NapCat 原样返回同一页的真异常。
/// 精确判据要求"只有一条，且就是锚点本身"而不是只看长度——单看长度==1
/// 挡不住"长度恰好是 1 但内容不是锚点"这种仍然异常的情况被悄悄放过。
///
/// 抽成纯函数的理由同 pageStopReason：这个判断本身不发 HTTP，能单测；
/// scanGroup 只根据返回值决定要不要打 `NOT fully covered ... will not be
/// revisited` 那行警告——合法到达历史开头时绝不能打这行，那正是重跑之后
/// 运营方拿来确认这次翻页方向修复是否生效的日志，一次假警报就会把人指向
/// 一个不存在的 NapCat 问题。
pub const NoAdvanceOutcome = struct {
    reached_start: bool,
    stop_reason: []const u8,
};

pub fn noAdvanceOutcome(msgs: []const onebot.Message, anchor: i64) NoAdvanceOutcome {
    if (msgs.len == 1 and msgs[0].message_id == anchor) {
        return .{
            .reached_start = true,
            .stop_reason = "anchor-only page (reached the start of the group's history)",
        };
    }
    return .{
        .reached_start = false,
        .stop_reason = "pagination anchor stopped advancing (NapCat returned the same page again)",
    };
}

/// 扫单个群。返回值不是错误通道——它是 runOnce 判断是否调用 setLastRun 用的
/// 成功信号：true = 这个群从头到尾没出岔子（哪怕 Added/skipped 都是 0）；
/// false = 落库阶段出现了至少一次 store.add 失败（已经在函数内部发了
/// Failed 行，不需要 runOnce 再发一次）。真正的硬失败（分页/判定阶段的
/// `try` 出错）仍然走 `!bool` 的错误通道，由 runOnce 的 catch 处理。
fn scanGroup(deps: Deps, a: std.mem.Allocator, lines: *std.ArrayList([]const u8), gid: u64, win_start: i64, win_end: i64) !bool {
    // `a` 与 `lines` 由 runOnce 传入并拥有——它们的寿命跨过这次调用本身
    // （包括这次调用以 `try` 错误告终的情形），理由见 runOnce 里对应注释。

    // "这个群这一轮扫了多久"从这里开始计时——scanGroup 一进来就是"这个群的
    // 处理"真正开始的地方（resolveWindowStart 那次 Redis 读已经在 runOnce
    // 里做完了，不计入这段耗时，它反映的是这个群该看多远，不是这个群本身
    // 处理花了多久）。收尾时（Successfully 那一行成文、也就是 sendForward
    // 真正打包这批 node 之前的最后一刻）再读一次同一个 deps.clock，两次之差
    // 就是要打进第七行的数字。Failed 路径不读第二次——那几个 return false
    // 分支都在这次读之前，耗时对一次失败的跑没有意义，spec 明确不要。
    const started_at = deps.clock();

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
        if (before != null and next_before == before.?) { // 不再前进：判断是不是翻到头了
            const outcome = noAdvanceOutcome(page.msgs, before.?);
            stop_reason = outcome.stop_reason;
            if (outcome.reached_start) reached_start = true;
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
    // 所以这里必须留下可见的痕迹，而不是安静地按截断后的结果报 Successfully in Ns.。
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

    const line = try willProcessLine(a, window.items.len);
    pushLine(a, lines, gid, line);

    // getMsg 重试统计的作用域正好跨过下面这两步——它们是这个群里仅有的两处
    // getMsg 调用点。声明在这里、用到步骤 4 结束，理由跟 pages/stop_reason
    // 一样：一份局部状态，随 scanGroup 这次调用生生灭灭，不需要活得更久。
    var get_msg_stats: GetMsgStats = .{};

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
        const data = getMsg(deps, a, rid, &get_msg_stats) orelse continue;
        if (try onebot.parseMessage(a, data)) |parsed| try pool.append(a, parsed);
    }

    // ---- 4. 逐条查被观察者消息的表情回应（✨ 与 🔥 共用同一次 get_msg，不额外调用）----
    var star_ids: std.ArrayList(i64) = .empty;
    var fire_ids: std.ArrayList(i64) = .empty;
    const probe_params: rules.Params = .{
        .observed_qqs = deps.observed_qqs,
        .admin_qqs = deps.admin_qqs,
    };
    for (window.items) |m| {
        if (!probe_params.isObserved(m.user_id)) continue;
        const data = getMsg(deps, a, m.message_id, &get_msg_stats) orelse {
            std.log.warn("group {d}: star-reaction probe for message {d} failed", .{ gid, m.message_id });
            continue;
        };
        var matched = false;
        if (napcat.hasStarReaction(data)) {
            try star_ids.append(a, m.message_id);
            matched = true;
        }
        if (napcat.hasFireReaction(data)) {
            try fire_ids.append(a, m.message_id);
            matched = true;
        }
        if (matched) continue;
        // design.md §3.3 要求把未匹配的 emoji_id 打进日志，README 线上假设 #4
        // 靠它核对 ✨ 的真实 emoji_id：这个常量要是错了，扫描器一条都收不到，
        // 现象跟"今天真的没人贴 ✨"一模一样，不会报任何错。只在这条消息确实有
        // 表情回应、且一个都没匹配上时打，避免给没有任何回应的消息刷屏。
        const seen = napcat.emojiIdsSummary(a, data) catch continue;
        if (seen.len > 0) std.log.info(
            "group {d}: message {d} carries emoji reactions but none matched star_emoji_id={s} or fire_emoji_id={s}: {s}",
            .{ gid, m.message_id, napcat.star_emoji_id, napcat.fire_emoji_id, seen },
        );
    }

    // getMsg 重试统计只进日志，不进合并转发（spec 明确要求：运营方在群里看到
    // 的七行是产品行为的信号，重试是不是生效是运维诊断信息，两者不共用一个
    // 通道）。只在这个群这一轮真的发生过重试时才打——没发生就是没什么可报的，
    // 跟上面 emojiIdsSummary "只在没匹配上时才打" 是同一个不刷屏的原则；
    // 发生了就把命中次数和救回次数都报出来，这正是判断这次修复在生产上到底
    // 有没有起作用所需要的那两个数字。
    if (get_msg_stats.retried > 0) std.log.info(
        "group {d}: get_msg retries: {d} call(s) needed a retry, {d} succeeded on retry",
        .{ gid, get_msg_stats.retried, get_msg_stats.retry_rescued },
    );

    // ---- 5. 判定 ----
    var outcome = try rules.classify(deps.gpa, window.items, pool.items, star_ids.items, fire_ids.items, .{
        .observed_qqs = deps.observed_qqs,
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
            // 作废失败必须跟入库失败一样压掉 Successfully in Ns. 与 setLastRun。
            // 压掉 setLastRun 现在还带一个好处：resolveWindowStart 按 last_run
            // 算窗口起点，这个群的 last_run 不动，下一次扫描（无论是重启补跑
            // 还是正常触发）的窗口会从旧起点重新覆盖到这条消息（受 7 天回看
            // 上限约束），撤稿请求还有机会重放，不是"这条 💦 明天就永久丢失"
            // 了——那是固定 24h 窗口时代的行为。只打一条 warn 然后照常报
            // Successfully in Ns. 才是这个产品里最坏的失败模式，所以必须压掉。
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
    // 不写这个群自己的 setLastRun：resolveWindowStart 按 last_run 算窗口起点，
    // 这个群的 last_run 就停在上一次成功的时刻不动，所以不管是重启补跑还是
    // 下一次正常触发，窗口都会从那个旧起点重新覆盖到这一批候选（受 7 天回看
    // 上限约束），不需要靠"固定 run_at - 24h"时代那种只有重启补跑才补得上
    // 的特殊路径。候选仍在窗口里，isTombstoned/exists 保证重扫是幂等的。
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
            // 第三道关卡：这个 id 是不是某条早先已经入库的 🔥 链的成员——不管
            // 是不是主键。非主键成员从未被单独写进 hikari:index（只有主键会），
            // 单靠 exists() 拦不住它们。这不是理论风险：一个群这一轮若因为
            // 其它候选 add 失败而判失败，lastrun 不会前移，下一次触发时窗口
            // 会原样重扫这批消息（受 7 天回看上限约束）——若这中间群里的 🔥
            // 被加/减，链的组成可能跟第一次算出来的不一样，导致同一个非主键
            // 成员这次被算成独立候选（或另一条不同的链）。isChainMember 挡住
            // 这种情形：一条消息一旦被某条链吸收，就永远不再被当成独立语录或
            // 另一条不同的链重新收录，除非这条链本身先被 💦 撤稿（撤稿会清理
            // 映射，见 store.zig revokeChainLocked）。这跟"不做语录编辑接口"
            // 是同一个哲学：语录一旦入库，形态就固定了，改主意只能先撤再等
            // 它作为新候选重新出现。
            if (try deps.st.isChainMember(cand.message_id)) {
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
                .user_id = if (target) |t| t.user_id else (soleObserved(deps) orelse 0),
            });
            defer freeQuote(deps.gpa, q);

            // store.add 失败与"被关卡拦下"是两码事（spec §7 的 skipped 特指后者），
            // 单独计数，不混进 skipped。
            //
            // 路径4（fire_chain）的候选带 chain_members，走 addChain：除了
            // 落一条语录，还把"成员 → 链主键"的映射持久化进 Redis（见
            // store.zig key_chainmember_prefix 的注释）——这是让 💦 撤稿脱离
            // "当次窗口能不能重建出链"这个约束的关键，没有这份持久化，💦
            // 引用一条早先已入库的链的非主键成员时，revoke() 只会删掉一个
            // 从未被索引过的 id，真正被索引的那份语录不会被删除。其它三条
            // 路径没有 chain_members，走原来的 add()。
            if (cand.chain_members) |members| {
                deps.st.addChain(q, members) catch |e| {
                    std.log.warn("group {d}: addChain {d} failed: {s}", .{ gid, cand.message_id, @errorName(e) });
                    trouble.add_failed += 1;
                    trouble.last_err = @errorName(e);
                    continue;
                };
            } else {
                deps.st.add(q) catch |e| {
                    std.log.warn("group {d}: add {d} failed: {s}", .{ gid, cand.message_id, @errorName(e) });
                    trouble.add_failed += 1;
                    trouble.last_err = @errorName(e);
                    continue;
                };
            }
            added += 1;
        }
    } else {
        trouble.unattributed = outcome.candidates.len;
    }

    const result = try resultLine(a, added, skipped);
    pushLine(a, lines, gid, result);

    // 出过岔子就不能用 Successfully in Ns. 收尾——那是运营方唯一的"这次跑成功了"信号。
    // 改发 Failed 行，带上各类失败的条数与最后一次的错误原因。
    if (trouble.any()) {
        const reason = try troubleReason(a, trouble);
        const msg = try failedLine(a, reason);
        pushLine(a, lines, gid, msg);
        return false;
    }

    const elapsed_s = deps.clock() - started_at;
    const msg = try successLine(a, elapsed_s);
    pushLine(a, lines, gid, msg);
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

test "successLine 格式：正常耗时、零耗时、负数被钳制到 0" {
    const gpa = std.testing.allocator;

    const a = try successLine(gpa, 42);
    defer gpa.free(a);
    try std.testing.expectEqualStrings("Successfully in 42s.", a);

    const b = try successLine(gpa, 0);
    defer gpa.free(b);
    try std.testing.expectEqualStrings("Successfully in 0s.", b);

    // 时钟被往回拨（或者注入的测试时钟没保证单调）时 elapsed_s 可能是负的：
    // 钳制到 0，不能把负号原样打进运营方看到的那一行。
    const c = try successLine(gpa, -5);
    defer gpa.free(c);
    try std.testing.expectEqualStrings("Successfully in 0s.", c);
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

// ---------------------------------------------------------------------------
// fetchPage 发出的 get_group_msg_history 请求体：线上曾经把 reverse_order 传
// 反过（锚点翻页传了 false，NapCat 把 false 解成"从锚点往新的方向走"，于是
// 原地把上一页整页重复拿一遍，生产上第一轮就卡在第 2 页）。这里直接起一个
// 假 HTTP 服务器接住 fetchPage 真正发出的请求体，逐字段锁死——尤其是
// reverse_order 的值——不满足于"JSON 能解析"这种弱断言，避免同类参数写反
// 再次不被测试挡住。Fake 服务器沿用 napcat.zig「call 发出带 Bearer token
// 的 POST 请求」那个测试的写法。

const FetchPageFake = struct {
    listener: std.net.Server,
    gpa: std.mem.Allocator,
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

        var body_buf: [4096]u8 = undefined;
        const body_reader = req.readerExpectNone(&body_buf);
        self.body = body_reader.allocRemaining(self.gpa, .unlimited) catch null;

        req.respond("{\"status\":\"ok\",\"retcode\":0,\"data\":{\"messages\":[]}}", .{
            .status = .ok,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        }) catch return;
    }

    fn start(gpa: std.mem.Allocator) !struct { fake: *FetchPageFake, thread: std.Thread, base: []u8 } {
        const self = try gpa.create(FetchPageFake);
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        self.* = .{
            .listener = try addr.listen(.{ .reuse_address = true }),
            .gpa = gpa,
        };
        const th = try std.Thread.spawn(.{}, serve, .{self});
        const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{self.listener.listen_address.getPort()});
        return .{ .fake = self, .thread = th, .base = base };
    }

    fn finish(self: *FetchPageFake, gpa: std.mem.Allocator, th: std.Thread) void {
        th.join();
        if (self.body) |b| gpa.free(b);
        self.listener.deinit();
        gpa.destroy(self);
    }
};

test "fetchPage 翻页锚点：reverse_order=true（往回翻），message_seq 传 before_id" {
    const gpa = std.testing.allocator;
    const started = try FetchPageFake.start(gpa);
    defer gpa.free(started.base);
    defer started.fake.finish(gpa, started.thread);

    var nap = napcat.Client.init(gpa, started.base, "t");
    defer nap.deinit();

    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();

    const deps: Deps = .{
        .gpa = gpa,
        .nap = &nap,
        .st = undefined, // fetchPage 不碰 deps.st
        .observed_qqs = &.{1},
        .admin_qqs = &.{},
        .group_ids = &.{},
    };

    _ = try fetchPage(deps, ar.allocator(), 999, 555);

    try std.testing.expect(started.fake.body != null);
    // 锁死整个请求体，而不是只查子串——查子串挡不住 reverse_order 那个 bool
    // 被写反（"reverse_order":false 也会命中 "reverse_order" 子串匹配）。
    try std.testing.expectEqualStrings(
        "{\"group_id\":999,\"message_seq\":555,\"count\":200,\"reverse_order\":true}",
        started.fake.body.?,
    );
}

test "fetchPage 首页（没有锚点）：不带 message_seq，reverse_order 仍是 false" {
    const gpa = std.testing.allocator;
    const started = try FetchPageFake.start(gpa);
    defer gpa.free(started.base);
    defer started.fake.finish(gpa, started.thread);

    var nap = napcat.Client.init(gpa, started.base, "t");
    defer nap.deinit();

    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();

    const deps: Deps = .{
        .gpa = gpa,
        .nap = &nap,
        .st = undefined,
        .observed_qqs = &.{1},
        .admin_qqs = &.{},
        .group_ids = &.{},
    };

    _ = try fetchPage(deps, ar.allocator(), 999, null);

    try std.testing.expect(started.fake.body != null);
    try std.testing.expectEqualStrings(
        "{\"group_id\":999,\"count\":200,\"reverse_order\":false}",
        started.fake.body.?,
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

// ---------------------------------------------------------------------------
// noAdvanceOutcome：翻页锚点没能前进时，区分"翻到群历史最开头了"（合法收尾，
// 不该打 NOT fully covered 警告）与"NapCat 真的又出岔子了"（异常，该打）。
// reverse_order 改成 true 之前，锚点没前进只可能是后一种；改完之后闭区间锚点
// 让前一种变得可达，这里锁死两条分支各自的 reached_start 与 stop_reason，
// 不满足于只断言其中一个字段——那样挡不住"该 true 却传了 false"或反过来。

test "noAdvanceOutcome：页面只有锚点自己一条 → 判定为翻到历史开头，reached_start=true" {
    const anchor_id: i64 = 555;
    const msgs = [_]onebot.Message{
        .{ .message_id = anchor_id, .user_id = 1, .time = 100, .segments = &.{} },
    };
    const outcome = noAdvanceOutcome(&msgs, anchor_id);
    try std.testing.expectEqual(true, outcome.reached_start);
    try std.testing.expectEqualStrings(
        "anchor-only page (reached the start of the group's history)",
        outcome.stop_reason,
    );
}

test "noAdvanceOutcome：页面不止一条（即便都没前进）→ 判定为真异常，reached_start=false" {
    const anchor_id: i64 = 555;
    // 锚点本身仍在页里（闭区间），但还带着别的消息——如果锚点真的没推进过，
    // 这不是"翻到头了"，是 NapCat 原样返回了同一页。
    const msgs = [_]onebot.Message{
        .{ .message_id = anchor_id, .user_id = 1, .time = 100, .segments = &.{} },
        .{ .message_id = 42, .user_id = 1, .time = 90, .segments = &.{} },
    };
    const outcome = noAdvanceOutcome(&msgs, anchor_id);
    try std.testing.expectEqual(false, outcome.reached_start);
    try std.testing.expectEqualStrings(
        "pagination anchor stopped advancing (NapCat returned the same page again)",
        outcome.stop_reason,
    );
}

test "noAdvanceOutcome：单条但不是锚点本身 → 仍判定为真异常（不能只看长度）" {
    const anchor_id: i64 = 555;
    const msgs = [_]onebot.Message{
        .{ .message_id = 999, .user_id = 1, .time = 100, .segments = &.{} },
    };
    const outcome = noAdvanceOutcome(&msgs, anchor_id);
    try std.testing.expectEqual(false, outcome.reached_start);
    try std.testing.expectEqualStrings(
        "pagination anchor stopped advancing (NapCat returned the same page again)",
        outcome.stop_reason,
    );
}

// ---------------------------------------------------------------------------
// applyLastRun：只需要一个 *Store，不需要真的驱动 scanGroup（那要真实 NapCat
// HTTP，测试环境起不来）。沿用 store.zig 的单连接 FakeServer 思路——每个测试
// 文件各自起一份私有拷贝，而不是从 store.zig 导出复用（那边的 FakeServer 本来
// 就没打算 pub）。

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
        _ = conn.stream.writeAll(self.script) catch return;
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

    fn stop(self: *FakeServer) void {
        if (self.stopped) return;
        self.stopped = true;
        self.listener.deinit();
        self.thread.join();
    }
};

test "applyLastRun：失败的群不写 setLastRun，成功的兄弟群照写——互不影响" {
    const gpa = std.testing.allocator;
    // 脚本只放一条 "+OK\r\n"：失败的那次 applyLastRun 调用必须完全不发命令
    // （否则这唯一一条回复会被那次调用吃掉，成功的那次就读不到回复而报错，
    // 测试会失败——这正是"脚本大小按实际会发生的命令数配"的意义所在）。
    const srv = try FakeServer.start(gpa, "+OK\r\n");
    defer {
        srv.stop();
        srv.received.deinit(gpa);
        gpa.destroy(srv);
    }
    var c = try redis.Client.connect(gpa, "127.0.0.1", srv.port(), null, 0);
    defer c.deinit();
    var st = store.Store.init(gpa, &c);

    // 先处理失败的群：不该有任何字节发给 Redis。
    applyLastRun(&st, 200, false, 1700000000);
    // 再处理成功的群：应该看到完整的 SET hikari:lastrun:100 1700000000 帧。
    applyLastRun(&st, 100, true, 1700000000);

    c.deinit();
    srv.stop();

    const expected_frame = try resp.encodeCommand(gpa, &.{ "SET", "hikari:lastrun:100", "1700000000" });
    defer gpa.free(expected_frame);
    try std.testing.expectEqualSlices(u8, expected_frame, srv.received.items);

    // 失败的群（200）完全没有对应的键出现在发出去的字节里。
    try std.testing.expect(std.mem.indexOf(u8, srv.received.items, "hikari:lastrun:200") == null);
}

// ---------------------------------------------------------------------------
// resolveWindowStart：同样只需要一个 *Store。四条分支对应 scheduler.windowStart
// 的四条分支（首次运行 / 已跟上 / 正常回补 / 截断），外加它自己特有的一条——
// getLastRun 读失败时退化成 24h 窗口而不是让整个群失败。

test "resolveWindowStart：正常回补——窗口起点就是 Redis 里的 last_run" {
    const gpa = std.testing.allocator;
    const run_at: i64 = 1_700_100_000;
    const last_run: i64 = run_at - 3 * 86400; // 3 天前，没有超过 7 天上限
    const srv = try FakeServer.start(gpa, "$10\r\n1699840800\r\n");
    defer {
        srv.stop();
        srv.received.deinit(gpa);
        gpa.destroy(srv);
    }
    var c = try redis.Client.connect(gpa, "127.0.0.1", srv.port(), null, 0);
    defer c.deinit();
    var st = store.Store.init(gpa, &c);

    try std.testing.expectEqual(last_run, resolveWindowStart(&st, 100, run_at));
}

test "resolveWindowStart：Redis 里没有这个群的键（nil）→ 退化成固定 24h 窗口" {
    const gpa = std.testing.allocator;
    const run_at: i64 = 1_700_100_000;
    const srv = try FakeServer.start(gpa, "$-1\r\n");
    defer {
        srv.stop();
        srv.received.deinit(gpa);
        gpa.destroy(srv);
    }
    var c = try redis.Client.connect(gpa, "127.0.0.1", srv.port(), null, 0);
    defer c.deinit();
    var st = store.Store.init(gpa, &c);

    try std.testing.expectEqual(run_at - 86400, resolveWindowStart(&st, 100, run_at));
}

test "resolveWindowStart：getLastRun 读失败 → 退化成固定 24h 窗口，不让这个群直接崩" {
    const gpa = std.testing.allocator;
    const run_at: i64 = 1_700_100_000;
    const srv = try FakeServer.start(gpa, "$10\r\n1699840800\r\n");
    defer {
        srv.stop();
        srv.received.deinit(gpa);
        gpa.destroy(srv);
    }
    var c = try redis.Client.connect(gpa, "127.0.0.1", srv.port(), null, 0);
    // 立刻 deinit：之后任何命令都直接返回 error.ConnectionFailed（client.zig
    // 的 dead 标志），不需要真的模拟一次网络层错误。
    c.deinit();
    var st = store.Store.init(gpa, &c);

    try std.testing.expectEqual(run_at - 86400, resolveWindowStart(&st, 100, run_at));
}

test "resolveWindowStart：停机超过 7 天上限 → 截断到上限（clamped 的 warn 只影响日志，不影响返回值）" {
    const gpa = std.testing.allocator;
    const run_at: i64 = 1_700_100_000;
    const last_run: i64 = run_at - scheduler.max_lookback_seconds - 100; // 超过上限 100 秒
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{last_run}) catch unreachable;
    const script = try std.fmt.allocPrint(gpa, "${d}\r\n{s}\r\n", .{ s.len, s });
    defer gpa.free(script);
    const srv = try FakeServer.start(gpa, script);
    defer {
        srv.stop();
        srv.received.deinit(gpa);
        gpa.destroy(srv);
    }
    var c = try redis.Client.connect(gpa, "127.0.0.1", srv.port(), null, 0);
    defer c.deinit();
    var st = store.Store.init(gpa, &c);

    try std.testing.expectEqual(run_at - scheduler.max_lookback_seconds, resolveWindowStart(&st, 100, run_at));
}

// ---------------------------------------------------------------------------
// buildForwardBody：七行文案改用一条 send_group_forward_msg 之后最容易踩的坑
// 就是"顺序被打乱"或"某一行被悄悄改写"——本项目已经有过一轮两个独立
// indexOf 存在性检查放过参数换位的先例（见 napcat.zig call 测试注释），这里
// 直接锁死整段 JSON 的逐字节内容，不满足于挨个 indexOf 找子串。

test "buildForwardBody：七行按顺序原样打进 node 数组，Failed 行替换 Successfully 那一个位置" {
    const gpa = std.testing.allocator;
    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();
    const a = ar.allocator();

    var lines: std.ArrayList([]const u8) = .empty;
    for (banner) |line| try lines.append(a, line);
    try lines.append(a, processing_line);
    try lines.append(a, try willProcessLine(a, 1234));
    try lines.append(a, try resultLine(a, 12, 34));
    try lines.append(a, try failedLine(a, "NapCatError"));

    const body = try buildForwardBody(a, 1039716984, "2131597992", lines.items);

    try std.testing.expectEqualStrings(
        "{\"group_id\":1039716984,\"messages\":[" ++
            "{\"type\":\"node\",\"data\":{\"user_id\":\"2131597992\",\"nickname\":\"Hikari\",\"content\":[{\"type\":\"text\",\"data\":{\"text\":\"Hikari!\"}}]}}," ++
            "{\"type\":\"node\",\"data\":{\"user_id\":\"2131597992\",\"nickname\":\"Hikari\",\"content\":[{\"type\":\"text\",\"data\":{\"text\":\"Made with ❤️ by CuzTeam, AmethystDevs-Lab\"}}]}}," ++
            "{\"type\":\"node\",\"data\":{\"user_id\":\"2131597992\",\"nickname\":\"Hikari\",\"content\":[{\"type\":\"text\",\"data\":{\"text\":\"Thanks to collaborators: 恩恩hhh, apanzinc, Lonely, 小晴同学, Sylphy\"}}]}}," ++
            "{\"type\":\"node\",\"data\":{\"user_id\":\"2131597992\",\"nickname\":\"Hikari\",\"content\":[{\"type\":\"text\",\"data\":{\"text\":\"Processing...\"}}]}}," ++
            "{\"type\":\"node\",\"data\":{\"user_id\":\"2131597992\",\"nickname\":\"Hikari\",\"content\":[{\"type\":\"text\",\"data\":{\"text\":\"Will process 1234 messages.\"}}]}}," ++
            "{\"type\":\"node\",\"data\":{\"user_id\":\"2131597992\",\"nickname\":\"Hikari\",\"content\":[{\"type\":\"text\",\"data\":{\"text\":\"Added 12 messages, skipped 34 messages.\"}}]}}," ++
            "{\"type\":\"node\",\"data\":{\"user_id\":\"2131597992\",\"nickname\":\"Hikari\",\"content\":[{\"type\":\"text\",\"data\":{\"text\":\"Failed: NapCatError\"}}]}}" ++
            "]}",
        body,
    );
}

test "buildForwardBody：正常收尾时最后一个 node 是 Successfully，不是 Failed" {
    const gpa = std.testing.allocator;
    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();
    const a = ar.allocator();

    var lines: std.ArrayList([]const u8) = .empty;
    for (banner) |line| try lines.append(a, line);
    try lines.append(a, processing_line);
    try lines.append(a, try willProcessLine(a, 0));
    try lines.append(a, try resultLine(a, 0, 0));
    try lines.append(a, try successLine(a, 7));

    const body = try buildForwardBody(a, 1, "1", lines.items);
    try std.testing.expect(std.mem.endsWith(
        u8,
        body,
        "{\"type\":\"node\",\"data\":{\"user_id\":\"1\",\"nickname\":\"Hikari\",\"content\":[{\"type\":\"text\",\"data\":{\"text\":\"Successfully in 7s.\"}}]}}]}",
    ));
}

test "buildForwardBody：空 lines 产出空 messages 数组，不崩" {
    const gpa = std.testing.allocator;
    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();
    const a = ar.allocator();

    const body = try buildForwardBody(a, 42, "1", &.{});
    try std.testing.expectEqualStrings("{\"group_id\":42,\"messages\":[]}", body);
}

// ---------------------------------------------------------------------------
// runOnce 端到端：改成合并转发之后最需要守住的两件事——
//   (a) 七行原样按顺序落进真实发出去的 send_group_forward_msg 请求体；
//   (b) 一个群在 scanGroup 内部出岔子（不管是 Trouble 那种"软失败"还是
//       `try` 传播的"硬失败"）时，Failed 行仍然作为这条合并转发的最后一个
//       node 被发出去，而不是这个群那一轮彻底沉默——这正是这次改动被要求
//       重点守住的行为。
// 起一对真实 TCP fake server（NapCat + Redis），完整跑一遍 runOnce，直接抓
// 落地的原始请求体逐字节断言。

const FakeNapcatServer = struct {
    listener: std.net.Server,
    thread: std.Thread,
    replies: []const []const u8,
    bodies: std.ArrayList([]u8),
    gpa: std.mem.Allocator,
    stopped: bool,

    fn serve(self: *FakeNapcatServer) void {
        const conn = self.listener.accept() catch return;
        defer conn.stream.close();
        var rbuf: [8192]u8 = undefined;
        var wbuf: [8192]u8 = undefined;
        var sr = conn.stream.reader(&rbuf);
        var sw = conn.stream.writer(&wbuf);
        var hs = std.http.Server.init(sr.interface(), &sw.interface);
        for (self.replies) |body| {
            var req = hs.receiveHead() catch return;
            var body_buf: [8192]u8 = undefined;
            const body_reader = req.readerExpectNone(&body_buf);
            if (body_reader.allocRemaining(self.gpa, .unlimited) catch null) |b| {
                self.bodies.append(self.gpa, b) catch self.gpa.free(b);
            }
            req.respond(body, .{
                .status = .ok,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            }) catch return;
        }
    }

    fn start(gpa: std.mem.Allocator, replies: []const []const u8) !*FakeNapcatServer {
        const self = try gpa.create(FakeNapcatServer);
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        self.* = .{
            .listener = try addr.listen(.{ .reuse_address = true }),
            .thread = undefined,
            .replies = replies,
            .bodies = .empty,
            .gpa = gpa,
            .stopped = false,
        };
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    fn port(self: *FakeNapcatServer) u16 {
        return self.listener.listen_address.getPort();
    }

    fn stop(self: *FakeNapcatServer) void {
        if (self.stopped) return;
        self.stopped = true;
        self.listener.deinit();
        self.thread.join();
    }

    fn destroy(self: *FakeNapcatServer) void {
        for (self.bodies.items) |b| self.gpa.free(b);
        self.bodies.deinit(self.gpa);
        self.gpa.destroy(self);
    }
};

test "runOnce：群归属拿不到导致 Trouble 时，Failed 是七个 node 里最后一个，合并转发确实发出去了" {
    const gpa = std.testing.allocator;
    const run_at: i64 = 1_700_100_000;

    // hikari:lastrun 未命中（nil）：退化成固定 24h 窗口，
    // win_start = run_at - 86400 = 1_700_013_600。
    const redis_srv = try FakeServer.start(gpa, "$-1\r\n");
    defer {
        redis_srv.stop();
        redis_srv.received.deinit(gpa);
        gpa.destroy(redis_srv);
    }

    // 七次 NapCat 调用，按 runOnce 实际发生的顺序：
    //   1. get_login_info（runOnce 开头，逐群复用）
    //   2. get_group_msg_history 第一页：1 条被观察者发的消息，落在窗口内
    //   3. get_group_msg_history 第二页：空页，翻页收尾
    //   4. get_msg：那条消息的表情回应探测，命中 ✨（路径 1 候选）
    //   5. get_group_info：故意失败，让 groupName 返回 null → attributed=false
    //   6. get_group_member_info：正常返回（但已经不影响 attributed 的结果）
    //   7. send_group_forward_msg：最终发出的合并转发
    const nap_srv = try FakeNapcatServer.start(gpa, &.{
        "{\"status\":\"ok\",\"retcode\":0,\"data\":{\"user_id\":2131597992,\"nickname\":\"A2Bot\"}}",
        "{\"status\":\"ok\",\"retcode\":0,\"data\":{\"messages\":[{\"message_id\":1,\"user_id\":10001,\"time\":1700050000,\"message\":[{\"type\":\"text\",\"data\":{\"text\":\"今天也是好天气\"}}]}]}}",
        "{\"status\":\"ok\",\"retcode\":0,\"data\":{\"messages\":[]}}",
        "{\"status\":\"ok\",\"retcode\":0,\"data\":{\"emoji_likes_list\":[{\"emoji_id\":\"10024\",\"likes_cnt\":1}]}}",
        "{\"status\":\"failed\",\"retcode\":100,\"data\":null}",
        "{\"status\":\"ok\",\"retcode\":0,\"data\":{\"card\":\"\",\"nickname\":\"晴\"}}",
        "{\"status\":\"ok\",\"retcode\":0,\"data\":{\"message_id\":242408478,\"res_id\":\"tPWS\",\"forward_id\":\"tPWS\"}}",
    });
    defer {
        nap_srv.stop();
        nap_srv.destroy();
    }

    var rc = try redis.Client.connect(gpa, "127.0.0.1", redis_srv.port(), null, 0);
    var st = store.Store.init(gpa, &rc);

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{nap_srv.port()});
    defer gpa.free(base);
    var nap = napcat.Client.init(gpa, base, "test-token");
    defer nap.deinit();

    const deps: Deps = .{
        .gpa = gpa,
        .nap = &nap,
        .st = &st,
        .observed_qqs = &.{10001},
        .admin_qqs = &.{},
        .group_ids = &.{55},
    };

    runOnce(deps, run_at);

    // 显式收尾后再读两边抓到的字节，避免读到服务端线程还没来得及写完的数据
    // ——这是本文件里 applyLastRun 测试已经在用的同一个顺序。
    rc.deinit();
    redis_srv.stop();
    nap_srv.stop();

    // 这个群这一轮判失败：applyLastRun 不该再补一次 SET。
    try std.testing.expect(std.mem.indexOf(u8, redis_srv.received.items, "SET") == null);

    try std.testing.expectEqual(@as(usize, 7), nap_srv.bodies.items.len);
    try std.testing.expectEqualStrings(
        "{\"group_id\":55,\"messages\":[" ++
            "{\"type\":\"node\",\"data\":{\"user_id\":\"2131597992\",\"nickname\":\"Hikari\",\"content\":[{\"type\":\"text\",\"data\":{\"text\":\"Hikari!\"}}]}}," ++
            "{\"type\":\"node\",\"data\":{\"user_id\":\"2131597992\",\"nickname\":\"Hikari\",\"content\":[{\"type\":\"text\",\"data\":{\"text\":\"Made with ❤️ by CuzTeam, AmethystDevs-Lab\"}}]}}," ++
            "{\"type\":\"node\",\"data\":{\"user_id\":\"2131597992\",\"nickname\":\"Hikari\",\"content\":[{\"type\":\"text\",\"data\":{\"text\":\"Thanks to collaborators: 恩恩hhh, apanzinc, Lonely, 小晴同学, Sylphy\"}}]}}," ++
            "{\"type\":\"node\",\"data\":{\"user_id\":\"2131597992\",\"nickname\":\"Hikari\",\"content\":[{\"type\":\"text\",\"data\":{\"text\":\"Processing...\"}}]}}," ++
            "{\"type\":\"node\",\"data\":{\"user_id\":\"2131597992\",\"nickname\":\"Hikari\",\"content\":[{\"type\":\"text\",\"data\":{\"text\":\"Will process 1 messages.\"}}]}}," ++
            "{\"type\":\"node\",\"data\":{\"user_id\":\"2131597992\",\"nickname\":\"Hikari\",\"content\":[{\"type\":\"text\",\"data\":{\"text\":\"Added 0 messages, skipped 0 messages.\"}}]}}," ++
            "{\"type\":\"node\",\"data\":{\"user_id\":\"2131597992\",\"nickname\":\"Hikari\",\"content\":[{\"type\":\"text\",\"data\":{\"text\":\"Failed: 1 quote(s) not written: group attribution unavailable\"}}]}}" ++
            "]}",
        nap_srv.bodies.items[6],
    );
}

test "runOnce：scanGroup 中途硬失败（try 传播的错误）时仍然发出合并转发，Failed 是最后一个 node，不是彻底沉默" {
    const gpa = std.testing.allocator;
    const run_at: i64 = 1_700_100_000;

    const redis_srv = try FakeServer.start(gpa, "$-1\r\n");
    defer {
        redis_srv.stop();
        redis_srv.received.deinit(gpa);
        gpa.destroy(redis_srv);
    }

    // 只有三次 NapCat 调用：get_login_info、失败的 get_group_msg_history
    // （触发 fetchPage 里的 `try`，让 scanGroup 直接把 error.NapCatError
    // 传播给 runOnce 的 catch）、以及最终仍然要发出去的合并转发。注意这里
    // 排进 lines 的只有横幅三行 + Processing 四行——"Will process" 和
    // "Added/skipped" 这两行从未被算出来，因为程序根本没走到那一步；这正是
    // "崩溃不等于安静"这条约束要求的最诚实的行为：把已经排队的都发出去，
    // 不假装凑出一份完整的七行。
    const nap_srv = try FakeNapcatServer.start(gpa, &.{
        "{\"status\":\"ok\",\"retcode\":0,\"data\":{\"user_id\":2131597992,\"nickname\":\"A2Bot\"}}",
        "{\"status\":\"failed\",\"retcode\":1404,\"data\":null}",
        "{\"status\":\"ok\",\"retcode\":0,\"data\":{\"message_id\":1,\"res_id\":\"x\",\"forward_id\":\"x\"}}",
    });
    defer {
        nap_srv.stop();
        nap_srv.destroy();
    }

    var rc = try redis.Client.connect(gpa, "127.0.0.1", redis_srv.port(), null, 0);
    var st = store.Store.init(gpa, &rc);

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{nap_srv.port()});
    defer gpa.free(base);
    var nap = napcat.Client.init(gpa, base, "test-token");
    defer nap.deinit();

    const deps: Deps = .{
        .gpa = gpa,
        .nap = &nap,
        .st = &st,
        .observed_qqs = &.{10001},
        .admin_qqs = &.{},
        .group_ids = &.{77},
    };

    runOnce(deps, run_at);

    rc.deinit();
    redis_srv.stop();
    nap_srv.stop();

    try std.testing.expect(std.mem.indexOf(u8, redis_srv.received.items, "SET") == null);

    try std.testing.expectEqual(@as(usize, 3), nap_srv.bodies.items.len);
    try std.testing.expectEqualStrings(
        "{\"group_id\":77,\"messages\":[" ++
            "{\"type\":\"node\",\"data\":{\"user_id\":\"2131597992\",\"nickname\":\"Hikari\",\"content\":[{\"type\":\"text\",\"data\":{\"text\":\"Hikari!\"}}]}}," ++
            "{\"type\":\"node\",\"data\":{\"user_id\":\"2131597992\",\"nickname\":\"Hikari\",\"content\":[{\"type\":\"text\",\"data\":{\"text\":\"Made with ❤️ by CuzTeam, AmethystDevs-Lab\"}}]}}," ++
            "{\"type\":\"node\",\"data\":{\"user_id\":\"2131597992\",\"nickname\":\"Hikari\",\"content\":[{\"type\":\"text\",\"data\":{\"text\":\"Thanks to collaborators: 恩恩hhh, apanzinc, Lonely, 小晴同学, Sylphy\"}}]}}," ++
            "{\"type\":\"node\",\"data\":{\"user_id\":\"2131597992\",\"nickname\":\"Hikari\",\"content\":[{\"type\":\"text\",\"data\":{\"text\":\"Processing...\"}}]}}," ++
            "{\"type\":\"node\",\"data\":{\"user_id\":\"2131597992\",\"nickname\":\"Hikari\",\"content\":[{\"type\":\"text\",\"data\":{\"text\":\"Failed: NapCatError\"}}]}}" ++
            "]}",
        nap_srv.bodies.items[2],
    );
}

// ---------------------------------------------------------------------------
// deps.clock 的测试桩：runOnce 端到端测试要锁死 Successfully in Ns. 这一行
// 的确切字节，不能让耗时取决于测试机跑多快。scanGroup 一次成功的调用恰好读
// 两次 deps.clock（进入时、Successfully 成文时），这个桩按顺序把测试指定的
// 读数吐回去，第三次及以后的调用重复最后一个值（防御性的——目前没有任何
// 调用会读第三次，但把越界访问换成饱和读比让测试直接 panic 更容易定位问题）。

var stub_clock_values: []const i64 = &.{};
var stub_clock_calls: usize = 0;

fn stubClock() i64 {
    const idx = @min(stub_clock_calls, stub_clock_values.len - 1);
    stub_clock_calls += 1;
    return stub_clock_values[idx];
}

test "runOnce：正常收尾（没有 Trouble）时第七个 node 是 Successfully in Ns.，耗时由注入的 clock 决定" {
    const gpa = std.testing.allocator;
    const run_at: i64 = 1_700_100_000;

    // hikari:lastrun 未命中（nil）→ 退化成固定 24h 窗口；这个群这一轮判成功，
    // applyLastRun 会补一次 SET，所以脚本要连着准备两条回复。
    const redis_srv = try FakeServer.start(gpa, "$-1\r\n+OK\r\n");
    defer {
        redis_srv.stop();
        redis_srv.received.deinit(gpa);
        gpa.destroy(redis_srv);
    }

    // 五次 NapCat 调用：
    //   1. get_login_info
    //   2. get_group_msg_history 第一页就是空页——window 里没有消息，
    //      不需要 get_msg 补拉或表情探测，把这个测试聚焦在 Successfully
    //      那一行上，不掺进跟这条改动无关的分支。
    //   3. get_group_info：成功
    //   4. get_group_member_info：成功 → attributed=true，且没有候选，
    //      trouble.any()==false，真正走到 Successfully 分支（不是 Failed）。
    //   5. send_group_forward_msg：最终发出的合并转发
    const nap_srv = try FakeNapcatServer.start(gpa, &.{
        "{\"status\":\"ok\",\"retcode\":0,\"data\":{\"user_id\":2131597992,\"nickname\":\"A2Bot\"}}",
        "{\"status\":\"ok\",\"retcode\":0,\"data\":{\"messages\":[]}}",
        "{\"status\":\"ok\",\"retcode\":0,\"data\":{\"group_name\":\"测试群\"}}",
        "{\"status\":\"ok\",\"retcode\":0,\"data\":{\"card\":\"\",\"nickname\":\"晴\"}}",
        "{\"status\":\"ok\",\"retcode\":0,\"data\":{\"message_id\":1,\"res_id\":\"x\",\"forward_id\":\"x\"}}",
    });
    defer {
        nap_srv.stop();
        nap_srv.destroy();
    }

    var rc = try redis.Client.connect(gpa, "127.0.0.1", redis_srv.port(), null, 0);
    var st = store.Store.init(gpa, &rc);

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{nap_srv.port()});
    defer gpa.free(base);
    var nap = napcat.Client.init(gpa, base, "test-token");
    defer nap.deinit();

    // 两次读数相差 3——scanGroup 进入时读到 1_700_100_000，Successfully
    // 成文时读到 1_700_100_003，第七行应该是 "Successfully in 3s."。
    stub_clock_values = &.{ 1_700_100_000, 1_700_100_003 };
    stub_clock_calls = 0;
    defer {
        stub_clock_values = &.{};
        stub_clock_calls = 0;
    }

    const deps: Deps = .{
        .gpa = gpa,
        .nap = &nap,
        .st = &st,
        .observed_qqs = &.{10001},
        .admin_qqs = &.{},
        .group_ids = &.{88},
        .clock = &stubClock,
    };

    runOnce(deps, run_at);

    rc.deinit();
    redis_srv.stop();
    nap_srv.stop();

    // 这个群这一轮判成功：applyLastRun 确实补了一次 SET。
    try std.testing.expect(std.mem.indexOf(u8, redis_srv.received.items, "SET") != null);

    try std.testing.expectEqual(@as(usize, 5), nap_srv.bodies.items.len);
    try std.testing.expectEqualStrings(
        "{\"group_id\":88,\"messages\":[" ++
            "{\"type\":\"node\",\"data\":{\"user_id\":\"2131597992\",\"nickname\":\"Hikari\",\"content\":[{\"type\":\"text\",\"data\":{\"text\":\"Hikari!\"}}]}}," ++
            "{\"type\":\"node\",\"data\":{\"user_id\":\"2131597992\",\"nickname\":\"Hikari\",\"content\":[{\"type\":\"text\",\"data\":{\"text\":\"Made with ❤️ by CuzTeam, AmethystDevs-Lab\"}}]}}," ++
            "{\"type\":\"node\",\"data\":{\"user_id\":\"2131597992\",\"nickname\":\"Hikari\",\"content\":[{\"type\":\"text\",\"data\":{\"text\":\"Thanks to collaborators: 恩恩hhh, apanzinc, Lonely, 小晴同学, Sylphy\"}}]}}," ++
            "{\"type\":\"node\",\"data\":{\"user_id\":\"2131597992\",\"nickname\":\"Hikari\",\"content\":[{\"type\":\"text\",\"data\":{\"text\":\"Processing...\"}}]}}," ++
            "{\"type\":\"node\",\"data\":{\"user_id\":\"2131597992\",\"nickname\":\"Hikari\",\"content\":[{\"type\":\"text\",\"data\":{\"text\":\"Will process 0 messages.\"}}]}}," ++
            "{\"type\":\"node\",\"data\":{\"user_id\":\"2131597992\",\"nickname\":\"Hikari\",\"content\":[{\"type\":\"text\",\"data\":{\"text\":\"Added 0 messages, skipped 0 messages.\"}}]}}," ++
            "{\"type\":\"node\",\"data\":{\"user_id\":\"2131597992\",\"nickname\":\"Hikari\",\"content\":[{\"type\":\"text\",\"data\":{\"text\":\"Successfully in 3s.\"}}]}}" ++
            "]}",
        nap_srv.bodies.items[4],
    );
}

// ---------------------------------------------------------------------------
// 🔥链端到端：rules.classify 把两条相邻消息并成一条 fire_chain 候选之后，
// scanGroup 必须走 store.Store.addChain（不是普通 add），把"成员 → 链主键"
// 的映射持久化进 Redis——这是本次改动要补的 gap 本身：只靠内存里的 chains
// 数组撤不了跨窗口的 💦，必须落盘。

test "runOnce：🔥链候选走 addChain，Redis 收到成员映射 + chain 成员集，不是普通 add()" {
    const gpa = std.testing.allocator;
    const run_at: i64 = 1_700_100_000;

    // hikari:lastrun 未命中 → 固定 24h 窗口，win_start = 1_700_013_600。
    // 之后依次是这个群这一轮真正发出的 Redis 命令：isTombstoned / exists /
    // isChainMember 三道关卡（都放行）、nextId、addChain 的六条命令
    // （两个成员各一条 SET 映射、一条 SADD chain 集、HSET/ZADD/SADD 原有三条），
    // 最后是 applyLastRun 的 SET（这个群判成功才会补）。
    const redis_srv = try FakeServer.start(gpa, "$-1\r\n:0\r\n:0\r\n:0\r\n:1\r\n+OK\r\n+OK\r\n+OK\r\n+OK\r\n+OK\r\n+OK\r\n+OK\r\n");
    defer {
        redis_srv.stop();
        redis_srv.received.deinit(gpa);
        gpa.destroy(redis_srv);
    }

    // 8 次 NapCat 调用：get_login_info → 两页历史（第一页两条相邻消息，
    // 均带 ✨+🔥；第二页空页收尾）→ 两次 get_msg 探测（各自命中 ✨ 与 🔥）→
    // get_group_info → get_group_member_info → send_group_forward_msg。
    const nap_srv = try FakeNapcatServer.start(gpa, &.{
        "{\"status\":\"ok\",\"retcode\":0,\"data\":{\"user_id\":2131597992,\"nickname\":\"A2Bot\"}}",
        "{\"status\":\"ok\",\"retcode\":0,\"data\":{\"messages\":[" ++
            "{\"message_id\":1,\"user_id\":10001,\"time\":1700050000,\"message\":[{\"type\":\"text\",\"data\":{\"text\":\"你们有钱\"}}]}," ++
            "{\"message_id\":2,\"user_id\":10001,\"time\":1700050001,\"message\":[{\"type\":\"text\",\"data\":{\"text\":\"你们潇洒\"}}]}" ++
            "]}}",
        "{\"status\":\"ok\",\"retcode\":0,\"data\":{\"messages\":[]}}",
        "{\"status\":\"ok\",\"retcode\":0,\"data\":{\"emoji_likes_list\":[{\"emoji_id\":\"10024\",\"likes_cnt\":1},{\"emoji_id\":\"128293\",\"likes_cnt\":1}]}}",
        "{\"status\":\"ok\",\"retcode\":0,\"data\":{\"emoji_likes_list\":[{\"emoji_id\":\"10024\",\"likes_cnt\":1},{\"emoji_id\":\"128293\",\"likes_cnt\":1}]}}",
        "{\"status\":\"ok\",\"retcode\":0,\"data\":{\"group_name\":\"测试群\"}}",
        "{\"status\":\"ok\",\"retcode\":0,\"data\":{\"card\":\"\",\"nickname\":\"晴\"}}",
        "{\"status\":\"ok\",\"retcode\":0,\"data\":{\"message_id\":1,\"res_id\":\"x\",\"forward_id\":\"x\"}}",
    });
    defer {
        nap_srv.stop();
        nap_srv.destroy();
    }

    var rc = try redis.Client.connect(gpa, "127.0.0.1", redis_srv.port(), null, 0);
    var st = store.Store.init(gpa, &rc);

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{nap_srv.port()});
    defer gpa.free(base);
    var nap = napcat.Client.init(gpa, base, "test-token");
    defer nap.deinit();

    const deps: Deps = .{
        .gpa = gpa,
        .nap = &nap,
        .st = &st,
        .observed_qqs = &.{10001},
        .admin_qqs = &.{},
        .group_ids = &.{77},
    };

    runOnce(deps, run_at);

    rc.deinit();
    redis_srv.stop();
    nap_srv.stop();

    // 这个群这一轮判成功：applyLastRun 补了一次 SET。
    const received = redis_srv.received.items;
    try std.testing.expect(std.mem.indexOf(u8, received, "hikari:lastrun:77") != null);

    // 两个成员各有一条持久化映射，主键（message_id=1）指向自己。
    try std.testing.expect(std.mem.indexOf(u8, received, "SET") != null);
    try std.testing.expect(std.mem.indexOf(u8, received, "hikari:chainmember:1") != null);
    try std.testing.expect(std.mem.indexOf(u8, received, "hikari:chainmember:2") != null);
    // chain 成员集用链主键做 key。
    try std.testing.expect(std.mem.indexOf(u8, received, "hikari:chain:1") != null);
    try std.testing.expect(std.mem.indexOf(u8, received, "SADD") != null);
    // 语录本身仍然以主键为 key（跟普通 add() 的落盘目标一致）。
    try std.testing.expect(std.mem.indexOf(u8, received, "hikari:quote:1") != null);

    try std.testing.expectEqual(@as(usize, 8), nap_srv.bodies.items.len);
    const forward = nap_srv.bodies.items[7];
    // joined 正文（"你们有钱 你们潇洒"）作为一条候选被收录，不是两条碎句。
    try std.testing.expect(std.mem.indexOf(u8, forward, "Will process 2 messages.") != null);
    try std.testing.expect(std.mem.indexOf(u8, forward, "Added 1 messages, skipped 0 messages.") != null);
    try std.testing.expect(std.mem.indexOf(u8, forward, "Successfully in") != null);
}

test "runOnce：isChainMember 拦下一个已属于其它链的候选——即便它这次单独满足路径1格式" {
    const gpa = std.testing.allocator;
    const run_at: i64 = 1_700_100_000;

    // 场景对应 §4.5.1 之外新增的守卫：message_id=5 曾经被某条链吸收（这里
    // 用脚本直接让 isChainMember(5) 返回 1，模拟"上一轮已经把它写进
    // hikari:chainmember:5"），这一轮窗口里它落单、单靠 ✨ 满足路径1格式，
    // 但不应该被当成一条全新的独立语录再收一遍——isChainMember 是
    // tombstone/exists 之后的第三道关卡，必须拦下它，计入 skipped。
    // 四条判定回复（GET lastrun / SISMEMBER tomb / SISMEMBER index / EXISTS
    // chainmember）之后还有一条：这个群这一轮仍然判成功（isChainMember 拦下
    // 候选只影响 skipped 计数，不算失败），applyLastRun 照常补一次 SET，
    // 脚本必须给够这第五条回复——少一条会让 setLastRun 的读卡在
    // ReadFailed 上（连接被这条失败的往返拆掉），而不是显式测试失败。
    const redis_srv = try FakeServer.start(gpa, "$-1\r\n:0\r\n:0\r\n:1\r\n+OK\r\n");
    defer {
        redis_srv.stop();
        redis_srv.received.deinit(gpa);
        gpa.destroy(redis_srv);
    }

    const nap_srv = try FakeNapcatServer.start(gpa, &.{
        "{\"status\":\"ok\",\"retcode\":0,\"data\":{\"user_id\":2131597992,\"nickname\":\"A2Bot\"}}",
        "{\"status\":\"ok\",\"retcode\":0,\"data\":{\"messages\":[" ++
            "{\"message_id\":5,\"user_id\":10001,\"time\":1700050000,\"message\":[{\"type\":\"text\",\"data\":{\"text\":\"落单的一句\"}}]}" ++
            "]}}",
        "{\"status\":\"ok\",\"retcode\":0,\"data\":{\"messages\":[]}}",
        "{\"status\":\"ok\",\"retcode\":0,\"data\":{\"emoji_likes_list\":[{\"emoji_id\":\"10024\",\"likes_cnt\":1}]}}",
        "{\"status\":\"ok\",\"retcode\":0,\"data\":{\"group_name\":\"测试群\"}}",
        "{\"status\":\"ok\",\"retcode\":0,\"data\":{\"card\":\"\",\"nickname\":\"晴\"}}",
        "{\"status\":\"ok\",\"retcode\":0,\"data\":{\"message_id\":1,\"res_id\":\"x\",\"forward_id\":\"x\"}}",
    });
    defer {
        nap_srv.stop();
        nap_srv.destroy();
    }

    var rc = try redis.Client.connect(gpa, "127.0.0.1", redis_srv.port(), null, 0);
    var st = store.Store.init(gpa, &rc);

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{nap_srv.port()});
    defer gpa.free(base);
    var nap = napcat.Client.init(gpa, base, "test-token");
    defer nap.deinit();

    const deps: Deps = .{
        .gpa = gpa,
        .nap = &nap,
        .st = &st,
        .observed_qqs = &.{10001},
        .admin_qqs = &.{},
        .group_ids = &.{78},
    };

    runOnce(deps, run_at);

    rc.deinit();
    redis_srv.stop();
    nap_srv.stop();

    // 没有发出任何 addChain/add 相关的写命令（脚本本身也只准备了四条只读/
    // 判定用的回复，多发一条就会因为脚本耗尽而挂起——这本身就是一种断言）。
    try std.testing.expect(std.mem.indexOf(u8, redis_srv.received.items, "hikari:lastrun:78") != null);

    try std.testing.expectEqual(@as(usize, 7), nap_srv.bodies.items.len);
    const forward = nap_srv.bodies.items[6];
    try std.testing.expect(std.mem.indexOf(u8, forward, "Added 0 messages, skipped 1 messages.") != null);
    try std.testing.expect(std.mem.indexOf(u8, forward, "Successfully in") != null);
}

test "fetchBotQq：get_login_info 失败时退回 OBSERVED_QQ" {
    const gpa = std.testing.allocator;
    const nap_srv = try FakeNapcatServer.start(gpa, &.{
        "{\"status\":\"failed\",\"retcode\":100,\"data\":null}",
    });
    defer {
        nap_srv.stop();
        nap_srv.destroy();
    }

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{nap_srv.port()});
    defer gpa.free(base);
    var nap = napcat.Client.init(gpa, base, "test-token");
    defer nap.deinit();

    const deps: Deps = .{
        .gpa = gpa,
        .nap = &nap,
        .st = undefined, // fetchBotQq 不碰 deps.st
        .observed_qqs = &.{99999},
        .admin_qqs = &.{},
        .group_ids = &.{},
    };

    try std.testing.expectEqual(@as(u64, 99999), fetchBotQq(deps));
}

test "fetchBotQq：正常拿到 user_id 时不使用 OBSERVED_QQ" {
    const gpa = std.testing.allocator;
    const nap_srv = try FakeNapcatServer.start(gpa, &.{
        "{\"status\":\"ok\",\"retcode\":0,\"data\":{\"user_id\":2131597992,\"nickname\":\"A2Bot\"}}",
    });
    defer {
        nap_srv.stop();
        nap_srv.destroy();
    }

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{nap_srv.port()});
    defer gpa.free(base);
    var nap = napcat.Client.init(gpa, base, "test-token");
    defer nap.deinit();

    const deps: Deps = .{
        .gpa = gpa,
        .nap = &nap,
        .st = undefined,
        .observed_qqs = &.{99999},
        .admin_qqs = &.{},
        .group_ids = &.{},
    };

    try std.testing.expectEqual(@as(u64, 2131597992), fetchBotQq(deps));
}

// ---------------------------------------------------------------------------
// getMsg 单次重试。三个测试都把 get_msg_retry_delay_ns 设成 0——不依赖真实
// 时钟就能确定性地覆盖"第一次失败要不要重试"这几条分支，也不会为了跑测试
// 套件真的睡一次 300ms。行为断言用的是"服务端总共接到几次 get_msg 请求"和
// GetMsgStats 的计数，不是计时——重试有没有发生、发生几次，从请求次数和
// 计数器上就能精确判定，不需要凭时长猜。fetchBotQq 测试已经证明 `.st =
// undefined` 在不碰 deps.st 的函数里是安全的，getMsg 同样只碰 deps.nap 和
// deps.get_msg_retry_delay_ns，这里沿用同一手法，不用真的起一条 Redis 连接。

test "getMsg：第一次失败、第二次成功——重试且救回，计数器与返回值都对" {
    const gpa = std.testing.allocator;
    const nap_srv = try FakeNapcatServer.start(gpa, &.{
        "{\"status\":\"failed\",\"retcode\":100,\"data\":null}",
        "{\"status\":\"ok\",\"retcode\":0,\"data\":{\"message_id\":315507131}}",
    });
    defer {
        nap_srv.stop();
        nap_srv.destroy();
    }

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{nap_srv.port()});
    defer gpa.free(base);
    var nap = napcat.Client.init(gpa, base, "test-token");
    defer nap.deinit();

    const deps: Deps = .{
        .gpa = gpa,
        .nap = &nap,
        .st = undefined,
        .observed_qqs = &.{10001},
        .admin_qqs = &.{},
        .group_ids = &.{},
        .get_msg_retry_delay_ns = 0,
    };

    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();

    var stats: GetMsgStats = .{};
    const data = getMsg(deps, ar.allocator(), 315507131, &stats);

    nap_srv.stop();

    try std.testing.expect(data != null);
    try std.testing.expectEqual(@as(i64, 315507131), data.?.object.get("message_id").?.integer);
    try std.testing.expectEqual(@as(usize, 1), stats.retried);
    try std.testing.expectEqual(@as(usize, 1), stats.retry_rescued);
    // 两次都是同一个 message_id 的请求体——重试没有偷偷换成别的消息。
    try std.testing.expectEqual(@as(usize, 2), nap_srv.bodies.items.len);
    try std.testing.expectEqualStrings("{\"message_id\":315507131}", nap_srv.bodies.items[0]);
    try std.testing.expectEqualStrings("{\"message_id\":315507131}", nap_srv.bodies.items[1]);
}

test "getMsg：两次都失败——恰好重试一次后如实返回 null，不会有第三次尝试" {
    const gpa = std.testing.allocator;
    const nap_srv = try FakeNapcatServer.start(gpa, &.{
        "{\"status\":\"failed\",\"retcode\":100,\"data\":null}",
        "{\"status\":\"failed\",\"retcode\":100,\"data\":null}",
    });
    defer {
        nap_srv.stop();
        nap_srv.destroy();
    }

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{nap_srv.port()});
    defer gpa.free(base);
    var nap = napcat.Client.init(gpa, base, "test-token");
    defer nap.deinit();

    const deps: Deps = .{
        .gpa = gpa,
        .nap = &nap,
        .st = undefined,
        .observed_qqs = &.{10001},
        .admin_qqs = &.{},
        .group_ids = &.{},
        .get_msg_retry_delay_ns = 0,
    };

    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();

    var stats: GetMsgStats = .{};
    const data = getMsg(deps, ar.allocator(), 1, &stats);

    nap_srv.stop();

    try std.testing.expect(data == null);
    try std.testing.expectEqual(@as(usize, 1), stats.retried);
    try std.testing.expectEqual(@as(usize, 0), stats.retry_rescued);
    try std.testing.expectEqual(@as(usize, 2), nap_srv.bodies.items.len);
}

test "getMsg：第一次就成功——不重试，服务端只接到一次请求（证明成功路径不付延迟）" {
    const gpa = std.testing.allocator;
    // 只挂一条回复：如果实现在成功之后还是多打了一次 get_msg，第二次请求
    // 会落在已经跑完 for 循环、连接已被关掉的服务端上，得到的绝不会是
    // 这里断言的"仅一次成功"结果——用请求次数本身当断言，不用计时器。
    const nap_srv = try FakeNapcatServer.start(gpa, &.{
        "{\"status\":\"ok\",\"retcode\":0,\"data\":{\"message_id\":42}}",
    });
    defer {
        nap_srv.stop();
        nap_srv.destroy();
    }

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{nap_srv.port()});
    defer gpa.free(base);
    var nap = napcat.Client.init(gpa, base, "test-token");
    defer nap.deinit();

    // 故意留着默认的 300ms 延迟（不覆盖 get_msg_retry_delay_ns）：成功路径
    // 根本不应该碰到 sleep 分支，这个测试要能在毫秒级跑完才算真的证明了这
    // 一点——如果哪天 sleep 被误挪到了 if 判断之外，这个测试会因为超时变慢
    // 而不只是逻辑断言失败。
    const deps: Deps = .{
        .gpa = gpa,
        .nap = &nap,
        .st = undefined,
        .observed_qqs = &.{10001},
        .admin_qqs = &.{},
        .group_ids = &.{},
    };

    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();

    var stats: GetMsgStats = .{};
    const data = getMsg(deps, ar.allocator(), 42, &stats);

    nap_srv.stop();

    try std.testing.expect(data != null);
    try std.testing.expectEqual(@as(i64, 42), data.?.object.get("message_id").?.integer);
    try std.testing.expectEqual(@as(usize, 0), stats.retried);
    try std.testing.expectEqual(@as(usize, 0), stats.retry_rescued);
    try std.testing.expectEqual(@as(usize, 1), nap_srv.bodies.items.len);
}
