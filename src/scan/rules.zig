const std = @import("std");
const onebot = @import("../onebot.zig");

pub const star = "✨";
pub const drop = "💦";

const ws = " \t\r\n";

pub const Path = enum { emoji_reaction, quoted_star, admin_manual, fire_chain };

/// 链式收录最多允许两条相邻合格消息之间隔多少条消息（不看发送者、不看是否有
/// 表情回应，按窗口内**去重后**的消息序列数）。"最多隔 3 条" ⇔ 去重后序列里的
/// 下标差 ≤ 4（下标差 4 时中间恰好夹 3 条）。
const chain_max_gap: usize = 4;

pub const Candidate = struct {
    message_id: i64,
    path: Path,
    /// 路径3专用：已剥掉 ✨ 前缀的正文。路径1、2 为 null，表示按 renderText 从目标消息提取。
    text_override: ?[]u8,
};

pub const Params = struct {
    observed_qq: u64,
    admin_qqs: []const u64,
};

pub const Outcome = struct {
    revoked: []i64,
    candidates: []Candidate,
    unresolved: []i64,

    pub fn deinit(self: *Outcome, gpa: std.mem.Allocator) void {
        for (self.candidates) |c| if (c.text_override) |t| gpa.free(t);
        gpa.free(self.candidates);
        gpa.free(self.revoked);
        gpa.free(self.unresolved);
    }
};

fn isAdmin(p: Params, qq: u64) bool {
    for (p.admin_qqs) |a| if (a == qq) return true;
    return false;
}

/// 路径3格式判定：发送者是管理员、不含 reply 段、渲染文本以 ✨ 开头、剥掉前缀后非空。
/// 命中返回剥掉前缀并 trim 后的正文（新分配，调用方 free），否则 null。
pub fn manualBody(gpa: std.mem.Allocator, m: onebot.Message, p: Params) !?[]u8 {
    if (!isAdmin(p, m.user_id)) return null;
    if (m.replyTarget() != null) return null;
    const rendered = try m.renderText(gpa);
    defer gpa.free(rendered);
    if (!std.mem.startsWith(u8, rendered, star)) return null;
    const rest = std.mem.trim(u8, rendered[star.len..], ws);
    if (rest.len == 0) return null;
    return try gpa.dupe(u8, rest);
}

fn lookup(pool: []const onebot.Message, id: i64) ?onebot.Message {
    for (pool) |m| if (m.message_id == id) return m;
    return null;
}

fn contains(list: []const i64, id: i64) bool {
    for (list) |x| if (x == id) return true;
    return false;
}

/// 一条已并链的 🔥 chain：members 按时间升序，member[0] 是主键（"句子的开头"）。
/// text 是拼接后的 joined 正文，直到被并入某个 Candidate.text_override 之前
/// 一直非 null；一旦转移所有权，置 null 防止 deinit 时重复释放——跟
/// Candidate.text_override 是同一个套路。
const Chain = struct {
    members: []i64,
    text: ?[]u8,

    fn deinit(self: *Chain, gpa: std.mem.Allocator) void {
        gpa.free(self.members);
        if (self.text) |t| gpa.free(t);
    }
};

fn isChainMember(m: onebot.Message, star_ids: []const i64, fire_ids: []const i64, observed_qq: u64) bool {
    return m.user_id == observed_qq and contains(star_ids, m.message_id) and contains(fire_ids, m.message_id);
}

/// window 按 message_id 去重后的序列，只保留每个 id 首次出现的那条。
///
/// 陷阱（本文件加的测试专门覆盖）：NapCat 分页是闭区间，相邻两页会把锚点消息
/// 重复拉一遍，同一条消息因此可能在 window 里出现两次。链式收录的"隔多少条"
/// 必须按这个去重后的序列算下标差，不能按 window 的原始数组下标算——否则一次
/// 页边界重叠会让间距虚高，两条本该相连的消息在页边界附近静默连不上，且几乎
/// 不可复现（只有页边界恰好落在两条消息之间时才会触发）。
fn distinctWindow(gpa: std.mem.Allocator, window: []const onebot.Message) ![]onebot.Message {
    var out: std.ArrayList(onebot.Message) = .empty;
    errdefer out.deinit(gpa);
    outer: for (window) |m| {
        for (out.items) |x| if (x.message_id == m.message_id) continue :outer;
        try out.append(gpa, m);
    }
    return out.toOwnedSlice(gpa);
}

/// 把 members（时间升序）拼成一条 Chain 并追加到 chains。
fn finalizeChain(gpa: std.mem.Allocator, chains: *std.ArrayList(Chain), members: []const onebot.Message) !void {
    var ids: std.ArrayList(i64) = .empty;
    errdefer ids.deinit(gpa);
    for (members) |m| try ids.append(gpa, m.message_id);
    const ids_owned = try ids.toOwnedSlice(gpa);
    errdefer gpa.free(ids_owned);

    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    for (members, 0..) |m, i| {
        const rendered = try m.renderText(gpa);
        defer gpa.free(rendered);
        if (i > 0) try text.append(gpa, ' ');
        try text.appendSlice(gpa, rendered);
    }
    const text_owned = try text.toOwnedSlice(gpa);
    errdefer gpa.free(text_owned);

    try chains.append(gpa, .{ .members = ids_owned, .text = text_owned });
}

/// 扫出窗口内全部满足"≥2 个成员、相邻成员间隔在 chain_max_gap 内"的 🔥 chain。
/// 只有真正合并成链（≥2 个成员）的才会出现在返回值里；孤零零一个合格消息
/// （没有邻居能并）不产生 Chain，调用方据此让它退回普通路径1候选。
fn buildChains(
    gpa: std.mem.Allocator,
    window: []const onebot.Message,
    star_ids: []const i64,
    fire_ids: []const i64,
    observed_qq: u64,
) ![]Chain {
    const distinct = try distinctWindow(gpa, window);
    defer gpa.free(distinct);

    var chains: std.ArrayList(Chain) = .empty;
    errdefer {
        for (chains.items) |*c| c.deinit(gpa);
        chains.deinit(gpa);
    }

    var run: std.ArrayList(onebot.Message) = .empty;
    defer run.deinit(gpa);
    var last_pos: usize = 0;

    for (distinct, 0..) |m, pos| {
        if (!isChainMember(m, star_ids, fire_ids, observed_qq)) continue;
        if (run.items.len > 0 and pos - last_pos <= chain_max_gap) {
            try run.append(gpa, m);
        } else {
            if (run.items.len >= 2) try finalizeChain(gpa, &chains, run.items);
            run.clearRetainingCapacity();
            try run.append(gpa, m);
        }
        last_pos = pos;
    }
    if (run.items.len >= 2) try finalizeChain(gpa, &chains, run.items);

    return chains.toOwnedSlice(gpa);
}

/// rid 若落在某条链里（不管是不是主键成员），返回那条链；否则 null。
fn chainOf(chains: []const Chain, id: i64) ?*const Chain {
    for (chains) |*c| {
        for (c.members) |mid| if (mid == id) return c;
    }
    return null;
}

pub fn classify(
    gpa: std.mem.Allocator,
    window: []const onebot.Message,
    pool: []const onebot.Message,
    star_ids: []const i64,
    fire_ids: []const i64,
    p: Params,
) !Outcome {
    // 链必须在 Pass A 之前就构建好：💦 可能引用链上任意一个成员（不一定是
    // 主键那条），Pass A 要能把这次撤稿展开成"整条链的全部成员都要 tombstone"，
    // 就必须已经知道成员→链的映射。构建放在函数最前面，而不是让 Pass A 现算，
    // 是因为 Pass B 插入 fire_chain 候选、排除路径1里的链成员，同样需要这份
    // 映射——算一次，Pass A/Pass B 共用，也避免两处判定逻辑各写一份、悄悄分叉。
    const chains = try buildChains(gpa, window, star_ids, fire_ids, p.observed_qq);
    defer {
        for (chains) |*c| c.deinit(gpa);
        gpa.free(chains);
    }

    var revoked: std.ArrayList(i64) = .empty;
    errdefer revoked.deinit(gpa);
    var unresolved: std.ArrayList(i64) = .empty;
    errdefer unresolved.deinit(gpa);
    var cands: std.ArrayList(Candidate) = .empty;
    errdefer {
        for (cands.items) |c| if (c.text_override) |t| gpa.free(t);
        cands.deinit(gpa);
    }

    // Pass A：收集作废指令
    for (window) |m| {
        if (!isAdmin(p, m.user_id)) continue;
        const rid = m.replyTarget() orelse continue;
        const txt = m.soleTextBesidesReply() orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, txt, ws), drop)) continue;
        const target = lookup(pool, rid) orelse {
            if (!contains(unresolved.items, rid)) try unresolved.append(gpa, rid);
            continue;
        };
        var ok = target.user_id == p.observed_qq;
        if (!ok) {
            if (try manualBody(gpa, target, p)) |body| {
                gpa.free(body);
                ok = true;
            }
        }
        if (!ok) continue;
        // 💦 引用到链上任意一个成员都要作废整条链：把全部成员都塞进 revoked，
        // 不只是 rid 自己。这样：(1) 存的那条语录（主键 = 第一个成员）会被
        // 删掉——即便 💦 引用的是第二个成员；(2) 每个成员的 message_id 都会被
        // tombstone，哪怕它自己从没单独入库过。后者是必须的：往后一旦 🔥 被
        // 撤掉、链散架，幸存成员会退回路径1单独候选资格，若它没被 tombstone，
        // 已经作废的内容就会原样复活。
        if (chainOf(chains, rid)) |c| {
            for (c.members) |mid| {
                if (!contains(revoked.items, mid)) try revoked.append(gpa, mid);
            }
        } else if (!contains(revoked.items, rid)) {
            try revoked.append(gpa, rid);
        }
    }

    // Pass B：先并入 🔥 链候选——每条链一个，正文是拼接好的 joined 文本，主键
    // 是第一个成员的 message_id。放在路径1/2/3 之前插入，这样若某条链的主键
    // 恰好还被路径2/3命中（同一 message_id），下面 appendCandidate 的去重规则
    // （非 admin_manual 的新候选一律让路给已存在的候选）会让这条已经插入的
    // fire_chain 候选留下，除非新来的是 admin_manual（那条规则本来就是"路径3
    // 优先于一切"，不是本次改动新增的）。
    for (chains) |*c| {
        if (c.text) |t| {
            try appendCandidate(gpa, &cands, .{
                .message_id = c.members[0],
                .path = .fire_chain,
                .text_override = t,
            });
            c.text = null; // 所有权转移给 cands 了；防止函数末尾 chains 的 defer 重复释放
        }
    }

    // Pass B：收集候选
    for (window) |m| {
        // 路径3 优先于路径1
        if (try manualBody(gpa, m, p)) |body| {
            errdefer gpa.free(body);
            try appendCandidate(gpa, &cands, .{
                .message_id = m.message_id,
                .path = .admin_manual,
                .text_override = body,
            });
            continue;
        }

        // 路径1：被观察者本人的消息带 ✨ 表情回应，且不是已并入某条 🔥 链的成员
        // （链已经把它的内容拼进 joined 语录了；不排除的话 "你们有钱"、
        // "你们潇洒"、"你们有钱 你们潇洒" 会同时入库）
        if (m.user_id == p.observed_qq and contains(star_ids, m.message_id) and chainOf(chains, m.message_id) == null) {
            try appendCandidate(gpa, &cands, .{
                .message_id = m.message_id,
                .path = .emoji_reaction,
                .text_override = null,
            });
            continue;
        }

        // 路径2：他人引用被观察者的消息，且除 reply 外只有一个 ✨ 文本段
        if (m.user_id == p.observed_qq) continue;
        const rid = m.replyTarget() orelse continue;
        const txt = m.soleTextBesidesReply() orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, txt, ws), star)) continue;
        const target = lookup(pool, rid) orelse {
            if (!contains(unresolved.items, rid)) try unresolved.append(gpa, rid);
            continue;
        };
        if (target.user_id != p.observed_qq) continue;
        try appendCandidate(gpa, &cands, .{
            .message_id = rid,
            .path = .quoted_star,
            .text_override = null,
        });
    }

    // 剔除已作废的候选
    var kept: std.ArrayList(Candidate) = .empty;
    errdefer {
        // 存活候选的 text_override 所有权在下面的循环里从 cands 转移到了 kept
        // （cands 随后被 clearAndFree，不再持有它们）；若这里只 kept.deinit 而不
        // 遍历释放，一旦后面任何一次 toOwnedSlice 触发 OOM，这些字符串就会泄漏
        // ——本文件加的 checkAllAllocationFailures 回归测试正是靠这条路径抓到的。
        for (kept.items) |c| if (c.text_override) |t| gpa.free(t);
        kept.deinit(gpa);
    }
    for (cands.items) |*c| {
        if (contains(revoked.items, c.message_id)) {
            if (c.text_override) |t| gpa.free(t);
            c.text_override = null; // 防止上方 errdefer 在后续 OOM 时对同一指针重复 free
            continue;
        }
        try kept.append(gpa, c.*);
        c.text_override = null; // 所有权转移给 kept 了；同理防止 cands 的 errdefer 在后续 OOM 时重复 free
    }
    // 用 clearAndFree 而非 deinit：deinit 会把 cands 设为 undefined，
    // 若下面 toOwnedSlice 触发 OOM，函数作用域的 errdefer 会遍历 cands.items
    // 读到 undefined 内存并段错误。clearAndFree 让 cands 保持合法的空列表，
    // errdefer 此时只是安全的空操作。
    cands.clearAndFree(gpa);

    // 分三步而不是直接塞进返回结构体字面量：若三次 toOwnedSlice 中某一次
    // 先成功、后一次才因 OOM 失败，成功那次拿到的切片必须有名字才能被
    // errdefer 追上并释放；直接写进 `.field = try ...toOwnedSlice(gpa)` 的话，
    // 先成功的那份内存不会绑定到任何变量，一旦后续字段失败就直接泄漏——
    // 这也是本文件加的 checkAllAllocationFailures 回归测试实际抓到的第三条泄漏路径。
    const revoked_owned = try revoked.toOwnedSlice(gpa);
    errdefer gpa.free(revoked_owned);

    const candidates_owned = try kept.toOwnedSlice(gpa);
    errdefer {
        for (candidates_owned) |c| if (c.text_override) |t| gpa.free(t);
        gpa.free(candidates_owned);
    }

    const unresolved_owned = try unresolved.toOwnedSlice(gpa);

    return .{
        .revoked = revoked_owned,
        .candidates = candidates_owned,
        .unresolved = unresolved_owned,
    };
}

/// 按 message_id 去重。已存在时：只有新来的是 admin_manual 而旧的不是，才替换。
///
/// 两个分支里的 free 都不能删——尤其是 else 分支那个，它不是死代码：
///
///   - else 分支（丢弃新来的 c）：**今天就会被走到**。c 是 admin_manual、
///     existing 也是 admin_manual 时落到这里，而 admin_manual 是唯一带
///     text_override 的路径，所以这个 free 真的在释放东西。触发条件是同一条
///     管理员消息在 window 里出现了两次——README 线上假设 #2 正说明这很可能
///     是 NapCat 的常态行为（`message_seq` 若是闭区间，相邻两页会重叠）。
///     删掉它就是在团队已经预料会走到的路径上引入泄漏。
///   - if 分支（替换掉 existing）：今天 existing.path != .admin_manual 意味着
///     它是 star_reaction / quoted_star，两者的 text_override 恒为 null，所以
///     这个 free 目前不会真的释放什么。保留它是为了将来新增带 text_override 的
///     路径时不必回头补一次——代价只有一次 null 判断。
fn appendCandidate(gpa: std.mem.Allocator, list: *std.ArrayList(Candidate), c: Candidate) !void {
    for (list.items) |*existing| {
        if (existing.message_id != c.message_id) continue;
        if (c.path == .admin_manual and existing.path != .admin_manual) {
            if (existing.text_override) |t| gpa.free(t);
            existing.* = c;
        } else {
            if (c.text_override) |t| gpa.free(t);
        }
        return;
    }
    try list.append(gpa, c);
}

const OBSERVED: u64 = 10001;
const ADMIN: u64 = 20001;
const OUTSIDER: u64 = 30001;

fn params() Params {
    return .{ .observed_qq = OBSERVED, .admin_qqs = &.{ADMIN} };
}

// 注意：这两个 helper 的形参必须是 comptime。它们的 .segments 指向一个匿名数组
// 字面量（`&.{...}`）。当实参是 comptime-known 时，Zig 会把该字面量常量提升
// （const-promote）为静态只读数据——它进了二进制镜像，不属于任何栈帧，天然与
// 程序同寿命，因此 `const msgs = [_]onebot.Message{ textMsg(...), ... }` 之后
// 无论怎么读都安全。参数一旦被声明为 comptime，调用方传入运行期值（比如循环变量
// 或 var）会直接编译失败，把这条生命周期不变量交给编译器强制执行，而不是依赖注释。
// （题外话：若形参是运行期参数，`&.{...}` 的存储归属于「构造该字面量的那次函数
// 调用」的栈帧，函数返回后即失效——这正是本文件原先出现过的悬垂指针 bug；单独
// 加 inline 在今天的 codegen 下恰好把它落在调用方栈帧里而“凑巧能用”，但不是编译器
// 保证的语义，故改为 comptime 形参从根上让编译器保证正确性。)
fn textMsg(comptime id: i64, comptime uid: u64, comptime txt: []const u8) onebot.Message {
    return .{
        .message_id = id,
        .user_id = uid,
        .time = 0,
        .segments = &.{.{ .text = txt }},
    };
}

fn replyMsg(comptime id: i64, comptime uid: u64, comptime target: i64, comptime txt: []const u8) onebot.Message {
    return .{
        .message_id = id,
        .user_id = uid,
        .time = 0,
        .segments = &.{ .{ .reply = target }, .{ .text = txt } },
    };
}

test "路径1：被观察者的消息带 ✨ 表情回应则入选" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, OBSERVED, "金句"), textMsg(2, OBSERVED, "普通话") };
    var out = try classify(gpa, &msgs, &msgs, &.{1}, &.{}, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(@as(i64, 1), out.candidates[0].message_id);
    try std.testing.expectEqual(Path.emoji_reaction, out.candidates[0].path);
    try std.testing.expectEqual(@as(?[]u8, null), out.candidates[0].text_override);
}

test "路径1：非被观察者的消息即使带 ✨ 也不入选" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{textMsg(1, OUTSIDER, "别人的话")};
    var out = try classify(gpa, &msgs, &msgs, &.{1}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
}

test "路径2：他人引用被观察者的消息并只回一个 ✨ → 收录被引用那条" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, OBSERVED, "金句"), replyMsg(2, OUTSIDER, 1, "✨") };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(@as(i64, 1), out.candidates[0].message_id);
    try std.testing.expectEqual(Path.quoted_star, out.candidates[0].path);
}

test "路径2：✨ 前后带空白仍然算数" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, OBSERVED, "金句"), replyMsg(2, OUTSIDER, 1, "  ✨ \n") };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
}

test "路径2：引用的不是被观察者的消息 → 不收录" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, OUTSIDER, "路人话"), replyMsg(2, OUTSIDER, 1, "✨") };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
}

test "路径2：引用消息夹带图片段 → 不收录" {
    const gpa = std.testing.allocator;
    const dirty: onebot.Message = .{
        .message_id = 2,
        .user_id = OUTSIDER,
        .time = 0,
        .segments = &.{ .{ .reply = 1 }, .{ .text = "✨" }, .other },
    };
    const msgs = [_]onebot.Message{ textMsg(1, OBSERVED, "金句"), dirty };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
}

test "路径2：引用目标在缓冲池里但不在窗口内 → 正常解析" {
    const gpa = std.testing.allocator;
    const old = textMsg(1, OBSERVED, "三天前的金句");
    const window = [_]onebot.Message{replyMsg(2, OUTSIDER, 1, "✨")};
    const pool = [_]onebot.Message{ old, window[0] };
    var out = try classify(gpa, &window, &pool, &.{}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(@as(i64, 1), out.candidates[0].message_id);
}

test "路径2：引用目标彻底解析不了 → 记入 unresolved，不中断" {
    const gpa = std.testing.allocator;
    const window = [_]onebot.Message{replyMsg(2, OUTSIDER, 999, "✨")};
    var out = try classify(gpa, &window, &window, &.{}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
    try std.testing.expectEqualSlices(i64, &.{999}, out.unresolved);
}

test "路径3：管理员发 ✨ 加内容 → 收录，正文剥掉前缀" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{textMsg(5, ADMIN, "✨ 手动补录的一句话")};
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(@as(i64, 5), out.candidates[0].message_id);
    try std.testing.expectEqual(Path.admin_manual, out.candidates[0].path);
    try std.testing.expectEqualStrings("手动补录的一句话", out.candidates[0].text_override.?);
}

test "路径3：✨ 与内容之间没有空格也认" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{textMsg(5, ADMIN, "✨紧贴的内容")};
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqualStrings("紧贴的内容", out.candidates[0].text_override.?);
}

test "路径3：管理员只发一个 ✨ → 剥完为空，不收录" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{textMsg(5, ADMIN, "✨   ")};
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
}

test "路径3：非管理员发 ✨ 加内容 → 不收录" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{textMsg(5, OUTSIDER, "✨ 我也想加一句")};
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
}

test "路径3：管理员发 ✨ 加内容但带了 reply 段 → 走路径2判定，不收录" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, OBSERVED, "金句"), replyMsg(5, ADMIN, 1, "✨ 加点评") };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
}

test "路径3 优先于路径1：被观察者兼任管理员时按路径3处理" {
    const gpa = std.testing.allocator;
    const p: Params = .{ .observed_qq = OBSERVED, .admin_qqs = &.{OBSERVED} };
    const msgs = [_]onebot.Message{textMsg(5, OBSERVED, "✨ 我自己补一句")};
    var out = try classify(gpa, &msgs, &msgs, &.{5}, &.{}, p);
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(Path.admin_manual, out.candidates[0].path);
    try std.testing.expectEqualStrings("我自己补一句", out.candidates[0].text_override.?);
}

test "作废：管理员 💦 引用被观察者的消息" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, OBSERVED, "失言"), replyMsg(2, ADMIN, 1, "💦") };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqualSlices(i64, &.{1}, out.revoked);
}

test "作废：非管理员发 💦 无效" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, OBSERVED, "失言"), replyMsg(2, OUTSIDER, 1, "💦") };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), out.revoked.len);
}

test "作废：💦 引用管理员发的普通消息 → 不作废" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, ADMIN, "随便说说"), replyMsg(2, ADMIN, 1, "💦") };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), out.revoked.len);
}

test "作废：💦 引用一条路径3手动收录的指令消息 → 应当作废" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, ADMIN, "✨ 手动补录"), replyMsg(2, ADMIN, 1, "💦") };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqualSlices(i64, &.{1}, out.revoked);
    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
}

test "作废优先于收录：同一窗口内被 ✨ 又被 💦 → 不入库" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "争议发言"),
        replyMsg(2, OUTSIDER, 1, "✨"),
        replyMsg(3, ADMIN, 1, "💦"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{1}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqualSlices(i64, &.{1}, out.revoked);
    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
}

test "去重：同一条消息被表情回应与引用 ✨ 同时命中 → 只出现一次" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, OBSERVED, "金句"), replyMsg(2, OUTSIDER, 1, "✨") };
    var out = try classify(gpa, &msgs, &msgs, &.{1}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(@as(i64, 1), out.candidates[0].message_id);
}

test "重复页：同一条路径3消息在窗口里出现两次 → 只留一条候选，且不泄漏 text_override" {
    const gpa = std.testing.allocator;
    // README 线上假设 #2：`message_seq` 若是闭区间，相邻两页会重叠，同一条
    // 消息就会在 window 里出现两次。此时 appendCandidate 会为第二次也算出一份
    // text_override，然后走 else 分支把它丢掉——那个 free 少了的话，
    // std.testing.allocator 会在这个测试上报泄漏。这就是为什么那行不是死代码。
    const m = textMsg(1, ADMIN, "✨ 手动补录测试");
    const msgs = [_]onebot.Message{ m, m };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqualStrings("手动补录测试", out.candidates[0].text_override.?);
}

test "manualBody 单独可用" {
    const gpa = std.testing.allocator;
    const ok = (try manualBody(gpa, textMsg(1, ADMIN, "✨ abc"), params())).?;
    defer gpa.free(ok);
    try std.testing.expectEqualStrings("abc", ok);
    try std.testing.expectEqual(@as(?[]u8, null), try manualBody(gpa, textMsg(1, OUTSIDER, "✨ abc"), params()));
    try std.testing.expectEqual(@as(?[]u8, null), try manualBody(gpa, textMsg(1, ADMIN, "abc"), params()));
}

fn classifyUnderFailingAllocator(gpa: std.mem.Allocator) !void {
    // id=1：路径3候选，随后被 id=2 的 💦 作废 → 命中 :146/:151 附近的
    // free-then-maybe-double-free 路径；id=3：路径3候选且存活 → 让
    // 「剔除已作废候选」循环里 kept.append 之后还有后续工作（toOwnedSlice 等），
    // 从而在更多分配点上练到 :151 的 errdefer 复用问题。
    const msgs = [_]onebot.Message{
        textMsg(1, ADMIN, "✨ aaa"),
        replyMsg(2, ADMIN, 1, "💦"),
        textMsg(3, ADMIN, "✨ bbb"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    out.deinit(gpa);
}

test "OOM 回归：作废与存活的路径3候选混在一起时，任意分配点失败都不能段错误或重复释放" {
    // 覆盖 review 发现的两个缺陷：
    // 1) cands.deinit 把 cands 设为 undefined 后，若后续 toOwnedSlice 触发 OOM，
    //    errdefer 会遍历 undefined 内存并段错误（修复：改用 clearAndFree）。
    // 2) 剔除已作废候选时 free 了 text_override 却没有把它设为 null，若循环里
    //    后续的 append 触发 OOM，errdefer 会对同一指针 free 第二次（修复：free 后置 null）。
    // std.testing.allocator 单独跑无法触及这两条路径——只有在每个分配点都真实失败一次
    // 的穷举下才会暴露，所以用 checkAllAllocationFailures。
    try std.testing.checkAllAllocationFailures(std.testing.allocator, classifyUnderFailingAllocator, .{});
}

fn classifyManySurvivorsUnderFailingAllocator(gpa: std.mem.Allocator) !void {
    // 8 条互不作废的路径3候选，全部存活进 kept。第一次 kept.append 由
    // ArrayList 的初始容量吃掉，之后每次 append 都可能触发一次真正的分配
    // （扩容）。只有存活候选数够多、逼出至少一次「append 之后还有更多 append」
    // 的场景，才能覆盖到「c.* 被拷进 kept 后，cands 里原件的 text_override
    // 必须同步置 null，否则 append 失败时 kept 与 cands 的两个 errdefer
    // 会对同一指针各 free 一次」这条路径——单个存活候选的场景到不了这里。
    const msgs = [_]onebot.Message{
        textMsg(1, ADMIN, "✨ one"),
        textMsg(2, ADMIN, "✨ two"),
        textMsg(3, ADMIN, "✨ three"),
        textMsg(4, ADMIN, "✨ four"),
        textMsg(5, ADMIN, "✨ five"),
        textMsg(6, ADMIN, "✨ six"),
        textMsg(7, ADMIN, "✨ seven"),
        textMsg(8, ADMIN, "✨ eight"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    out.deinit(gpa);
}

test "OOM 回归：≥3 个存活的路径3候选（无作废）时，kept.append 扩容失败不能重复释放" {
    // 覆盖上一轮修复引入的新缺陷：给 kept 的 errdefer 加上按元素遍历释放
    // text_override 后，"剔除已作废候选" 循环里 try kept.append(gpa, c.*)
    // 成功之后，如果不把 cands 里那份原件的 text_override 同步置 null，
    // cands 的原件与 kept 里的拷贝会短暂共享同一个指针；只要循环里后面
    // 还有一次 kept.append 触发 OOM，两个 errdefer 就会各 free 一次，
    // 造成 double free。修复：append 成功后立刻把源指针置 null。
    try std.testing.checkAllAllocationFailures(std.testing.allocator, classifyManySurvivorsUnderFailingAllocator, .{});
}

// ---- 🔥 链式收录 ----

test "🔥链：两条相邻合格消息合并为一条候选，正文空格拼接，且不再各自单独入选" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "你们有钱"),
        textMsg(2, OBSERVED, "你们潇洒"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 2 }, &.{ 1, 2 }, params());
    defer out.deinit(gpa);

    // 只有一条候选（joined），不是三条（两条独立 + 一条 joined）。
    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(@as(i64, 1), out.candidates[0].message_id);
    try std.testing.expectEqual(Path.fire_chain, out.candidates[0].path);
    try std.testing.expectEqualStrings("你们有钱 你们潇洒", out.candidates[0].text_override.?);
}

test "🔥链：三条依次相连的消息合并成一条（不设两条的上限）" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "第一段"),
        textMsg(2, OBSERVED, "第二段"),
        textMsg(3, OBSERVED, "第三段"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 2, 3 }, &.{ 1, 2, 3 }, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(@as(i64, 1), out.candidates[0].message_id);
    try std.testing.expectEqual(Path.fire_chain, out.candidates[0].path);
    try std.testing.expectEqualStrings("第一段 第二段 第三段", out.candidates[0].text_override.?);
}

test "🔥链：间隔恰好3条消息仍相连" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "开头"),
        textMsg(2, OUTSIDER, "闲聊1"),
        textMsg(3, OUTSIDER, "闲聊2"),
        textMsg(4, OUTSIDER, "闲聊3"),
        textMsg(5, OBSERVED, "结尾"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 5 }, &.{ 1, 5 }, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(Path.fire_chain, out.candidates[0].path);
    try std.testing.expectEqualStrings("开头 结尾", out.candidates[0].text_override.?);
}

test "🔥链：间隔4条消息不再相连，各自按路径1单独入选" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "开头"),
        textMsg(2, OUTSIDER, "闲聊1"),
        textMsg(3, OUTSIDER, "闲聊2"),
        textMsg(4, OUTSIDER, "闲聊3"),
        textMsg(5, OUTSIDER, "闲聊4"),
        textMsg(6, OBSERVED, "结尾"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 6 }, &.{ 1, 6 }, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), out.candidates.len);
    for (out.candidates) |c| {
        try std.testing.expectEqual(Path.emoji_reaction, c.path);
        try std.testing.expectEqual(@as(?[]u8, null), c.text_override);
    }
}

test "🔥链：只有✨没有🔥的消息不参与链，仍按路径1单独入选" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "只有星星"),
        textMsg(2, OBSERVED, "星星加火"),
    };
    // msg 1 只有 ✨，msg 2 星火俱全——但 2 落单（没有第二个"星火俱全"的伙伴），
    // 所以两条都退回路径1单独候选，互不合并。
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 2 }, &.{2}, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), out.candidates.len);
    for (out.candidates) |c| try std.testing.expectEqual(Path.emoji_reaction, c.path);
}

test "🔥链：只有🔥没有✨的消息什么都不产生" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{textMsg(1, OBSERVED, "只有火")};
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{1}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
}

test "🔥链：窗口内的重复消息（分页重叠）不会让间距虚高" {
    const gpa = std.testing.allocator;
    // 若按 window 的原始数组下标算间距：message_id=1 在下标0，message_id=5 在
    // 下标5，差5，会被误判成"隔了4条"而不相连。NapCat 分页是闭区间，相邻两页
    // 会把锚点消息本身重复拉一遍，这里用重复的 message_id=3 模拟这种页边界
    // 重叠。按去重后的序列（1,2,3,4,5，位置0..4）算：1和5间距为4，应当相连。
    const filler3 = textMsg(3, OUTSIDER, "闲聊2");
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "开头"),
        textMsg(2, OUTSIDER, "闲聊1"),
        filler3,
        filler3,
        textMsg(4, OUTSIDER, "闲聊3"),
        textMsg(5, OBSERVED, "结尾"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 5 }, &.{ 1, 5 }, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(Path.fire_chain, out.candidates[0].path);
    try std.testing.expectEqualStrings("开头 结尾", out.candidates[0].text_override.?);
}

test "🔥链撤稿：💦 引用链上第二个成员，作废整条链，两个成员都进 revoked（都会被 tombstone）" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "你们有钱"),
        textMsg(2, OBSERVED, "你们潇洒"),
        replyMsg(3, ADMIN, 2, "💦"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 2 }, &.{ 1, 2 }, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
    try std.testing.expectEqualSlices(i64, &.{ 1, 2 }, out.revoked);
}

test "🔥链撤稿：💦 引用链上第一个成员（主键），同样作废整条链且两个成员都进 revoked" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "你们有钱"),
        textMsg(2, OBSERVED, "你们潇洒"),
        replyMsg(3, ADMIN, 1, "💦"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 2 }, &.{ 1, 2 }, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
    try std.testing.expectEqualSlices(i64, &.{ 1, 2 }, out.revoked);
}

fn classifyChainUnderFailingAllocator(gpa: std.mem.Allocator) !void {
    // 三条相连的合格消息：练到 distinctWindow、finalizeChain（ids 与 text 两次
    // ArrayList 构建）、buildChains 里 chains 列表的扩容，以及 Pass B 把 chain
    // 候选并入 cands 时的所有权转移，这些都是本次改动新增的分配点。
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "你们有钱"),
        textMsg(2, OBSERVED, "你们潇洒"),
        textMsg(3, OBSERVED, "还挺开心"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 2, 3 }, &.{ 1, 2, 3 }, params());
    out.deinit(gpa);
}

test "OOM 回归：🔥链构建（buildChains/finalizeChain）在任意分配点失败都不能段错误或重复释放" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, classifyChainUnderFailingAllocator, .{});
}

fn classifyChainRevokedUnderFailingAllocator(gpa: std.mem.Allocator) !void {
    // 链建好之后又被 💦 撤稿：额外练到 Pass A 里 chainOf 命中后把全部成员
    // 循环塞进 revoked 这条路径。
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "你们有钱"),
        textMsg(2, OBSERVED, "你们潇洒"),
        replyMsg(3, ADMIN, 2, "💦"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 2 }, &.{ 1, 2 }, params());
    out.deinit(gpa);
}

test "OOM 回归：🔥链被 💦 撤稿（revoked 展开为全部成员）时任意分配点失败都不能段错误或重复释放" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, classifyChainRevokedUnderFailingAllocator, .{});
}
