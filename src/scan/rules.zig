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
    /// 路径3、路径4专用：已经算好、不需要再从目标消息提取的正文。路径3是剥掉
    /// ✨ 前缀后的内容；路径4是链上各成员依次取正文（同样剥过各自的 ✨ 前缀，
    /// 见 finalizeChain）后用空格拼接的结果。路径1、2 为 null，表示按
    /// renderText 从目标消息提取。
    text_override: ?[]u8,
    /// 路径4专用：这条链的**全部**成员 message_id（时间升序，
    /// `chain_members[0] == message_id`，即主键）。路径1/2/3 为 null。
    ///
    /// 这份数据是从 Chain.members dupe 出来的独立分配（不是转移所有权）：
    /// Chain.members 在整个 classify() 执行期间还要继续被 chainOf 用来判定
    /// "某个 window 里的消息是不是链成员"（Pass B 主循环、Pass A 的 💦 展开），
    /// 不能在插入 fire_chain 候选时就被掏空。
    ///
    /// runner.zig 靠这个字段把整条链的成员列表持久化进 Redis
    /// （`store.Store.addChain`）：rules.classify 只能在当次扫描窗口里重建出
    /// 链，💦 撤稿一条早先已经入库的链语录时，引用目标很可能落在窗口外
    /// （缓冲池 / get_msg 回补），chainOf 在那种情况下必然返回 null——没有这份
    /// 持久化，非主键成员就永远等不到被跨窗口撤稿。见 store.zig 顶部
    /// key_chainmember_prefix 的注释。
    chain_members: ?[]i64,
};

pub const Params = struct {
    /// 被观察者集合。**空切片 = 观察所有人**。
    observed_qqs: []const u64,
    admin_qqs: []const u64,

    /// "这个 QQ 算不算被观察者" 的**唯一**判定点。四条收录路径、Pass A 的
    /// 撤稿目标判定、🔥 链的成员资格全部走这一个函数，不允许任何一处再写
    /// 一份自己的 `for (observed_qqs) |o| ...`——"空集合 = 全部" 这条规则
    /// 抄四遍就是四次抄错的机会，而抄错的后果分别是：漏收（判成 false）、
    /// 或者把不该作废的消息永久 tombstone（判成 true）。
    pub fn isObserved(self: Params, qq: u64) bool {
        if (self.observed_qqs.len == 0) return true;
        for (self.observed_qqs) |o| if (o == qq) return true;
        return false;
    }
};

pub const Outcome = struct {
    revoked: []i64,
    candidates: []Candidate,
    unresolved: []i64,

    pub fn deinit(self: *Outcome, gpa: std.mem.Allocator) void {
        for (self.candidates) |c| {
            if (c.text_override) |t| gpa.free(t);
            if (c.chain_members) |cm| gpa.free(cm);
        }
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

fn isChainMember(m: onebot.Message, star_ids: []const i64, fire_ids: []const i64, p: Params) bool {
    return p.isObserved(m.user_id) and contains(star_ids, m.message_id) and contains(fire_ids, m.message_id);
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
///
/// 拼接每个成员时优先走 manualBody（路径3判定）：若这个成员自己就是合法的
/// "✨ 内容" 管理员手动收录格式（这要求被观察者同时在 ADMIN_QQS 里），拼进
/// joined 正文的是剥掉 ✨ 前缀后的内容，而不是带着 ✨ 的原始渲染文本。✨ 在这个
/// 系统里到处都是控制符不是正文——路径3自己会剥掉它，路径4的联动如果不剥，
/// 会拼出"你们有钱 ✨ 你们潇洒"这种带着控制符残留的语录。manualBody 内部已经
/// 处理了"不含 reply 段"这个前提，链成员本来就不含 reply 段（reply 段是路径2的
/// 语法，和链成员资格互斥的场景在实践中不会出现，即便出现 manualBody 也会
/// 正确返回 null 退回原始渲染文本）。
fn finalizeChain(gpa: std.mem.Allocator, chains: *std.ArrayList(Chain), members: []const onebot.Message, p: Params) !void {
    var ids: std.ArrayList(i64) = .empty;
    errdefer ids.deinit(gpa);
    for (members) |m| try ids.append(gpa, m.message_id);
    const ids_owned = try ids.toOwnedSlice(gpa);
    errdefer gpa.free(ids_owned);

    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    for (members, 0..) |m, i| {
        const piece: []const u8 = if (try manualBody(gpa, m, p)) |body| body else try m.renderText(gpa);
        defer gpa.free(piece);
        if (i > 0) try text.append(gpa, ' ');
        try text.appendSlice(gpa, piece);
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
    p: Params,
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
        if (!isChainMember(m, star_ids, fire_ids, p)) continue;
        // 同一条链的全部成员必须是**同一个人**发的。观察所有人之后这不再是
        // 理论问题：两个人各自的半句话恰好前后脚发出、又都被贴了 ✨+🔥，
        // 不加这条约束就会被拼成一条谁也没说过的话，而这条语录的 `from_who`
        // 也无从谈起（它只能取第一个成员的作者，另一半的作者被静默吞掉）。
        // 发送者一变就断开当前 run，从这条消息重新起一条。
        const same_sender = run.items.len > 0 and run.items[0].user_id == m.user_id;
        if (same_sender and pos - last_pos <= chain_max_gap) {
            try run.append(gpa, m);
        } else {
            if (run.items.len >= 2) try finalizeChain(gpa, &chains, run.items, p);
            run.clearRetainingCapacity();
            try run.append(gpa, m);
        }
        last_pos = pos;
    }
    if (run.items.len >= 2) try finalizeChain(gpa, &chains, run.items, p);

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
    const chains = try buildChains(gpa, window, star_ids, fire_ids, p);
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
        for (cands.items) |c| {
            if (c.text_override) |t| gpa.free(t);
            if (c.chain_members) |cm| gpa.free(cm);
        }
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
        var ok = p.isObserved(target.user_id);
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
    // 是第一个成员的 message_id。放在路径1/2/3 之前插入：下面的主循环会显式
    // 检查每条消息是否是某条链的成员（is_chain_member / chainOf），链成员一律
    // 不再生成路径1/2/3 的候选（见下方主循环里的说明），所以这里插入的顺序
    // 本身不再依赖 appendCandidate 的去重规则来"赢"——不会有路径1/2/3的候选
    // 冲着同一个链成员的 message_id 跑来跟它抢；先插入只是让 chains 的所有权
    // 转移（c.text = null）尽早发生，逻辑上更直接。
    for (chains) |*c| {
        if (c.text) |t| {
            // chain_members 是从 c.members dupe 出来的独立分配，不是转移
            // 所有权：c.members 在下面 Pass B 主循环、以及上面已经跑过的
            // Pass A 里都还要靠 chainOf 反复查——转移所有权（置 c.members
            // 为空切片）会让本函数剩下的全部 chainOf 调用当场失效。c.text
            // 那次是可以转移的，因为 joined 正文只在这里用一次。
            const members_dup = try gpa.dupe(i64, c.members);
            errdefer gpa.free(members_dup);
            try appendCandidate(gpa, &cands, .{
                .message_id = c.members[0],
                .path = .fire_chain,
                .text_override = t,
                .chain_members = members_dup,
            });
            c.text = null; // 所有权转移给 cands 了；防止函数末尾 chains 的 defer 重复释放
        }
    }

    // Pass B：收集候选
    for (window) |m| {
        // 链成员的个体收录资格对全部路径一律让路给路径4：链是更具体的信号
        // （群里明确把这几条标记成一句话），路径1/2/3 只是"这条消息本身也值得
        // 收录"的独立信号，两者同时生效会让语录库里同时存在碎句和整句
        // （"你们潇洒" 与 "你们有钱 你们潇洒"），GET / 随机吐出来的观感比只留
        // 其中一条更差。这条规则对链的第一个成员（主键）也成立，不只是非主键
        // 成员——即便主键那条自己长得也像路径3格式，也不再单独生成路径3候选，
        // 由链的 fire_chain 候选（已经在上面的循环里插入，且已经用 manualBody
        // 剥过它自己的 ✨ 前缀了，见 finalizeChain）代表它。这一条使路径4的
        // 优先级压过路径3，是本次改动特意翻转的：路径3优先于路径1是因为它是
        // 更具体的"作者本人手动指定"信号；路径4优先于路径3/路径1是因为它是
        // 更具体的"分组"信号，而分组这件事没有别的路径能表达。
        const is_chain_member = chainOf(chains, m.message_id) != null;

        // 路径3 优先于路径1（但链成员整体让路给路径4，见上）
        if (!is_chain_member) {
            if (try manualBody(gpa, m, p)) |body| {
                errdefer gpa.free(body);
                try appendCandidate(gpa, &cands, .{
                    .message_id = m.message_id,
                    .path = .admin_manual,
                    .text_override = body,
                    .chain_members = null,
                });
                continue;
            }
        }

        // 路径1：被观察者本人的消息带 ✨ 表情回应，且不是已并入某条 🔥 链的成员
        // （链已经把它的内容拼进 joined 语录了；不排除的话 "你们有钱"、
        // "你们潇洒"、"你们有钱 你们潇洒" 会同时入库）
        if (p.isObserved(m.user_id) and contains(star_ids, m.message_id) and !is_chain_member) {
            try appendCandidate(gpa, &cands, .{
                .message_id = m.message_id,
                .path = .emoji_reaction,
                .text_override = null,
                .chain_members = null,
            });
            continue;
        }

        // 路径2：**别人**引用一条被观察者的消息，且除 reply 外只有一个 ✨ 文本段。
        //
        // "别人" 这个条件过去写成 `if (m.user_id == p.observed_qq) continue;`
        // ——只有一个被观察者时它等价于 "回复的人不是这条消息的作者"，因为
        // 目标本来就必须是那唯一一个被观察者。把它机械地换成
        // `if (p.isObserved(m.user_id)) continue;` 会在空集合（观察所有人）
        // 下让这一条恒为真，**整条路径2直接失效**，而且不会有任何测试以外
        // 的迹象。正确的推广是把它下移到解析出目标之后，判 "回复的人 ≠ 被
        // 引用消息的作者"：单被观察者配置下与旧行为逐字等价（目标必然是那
        // 个被观察者，于是 `m.user_id != target.user_id` ⇔
        // `m.user_id != observed_qq`），多被观察者/观察所有人时表达的也正是
        // 原本的意思——自己给自己的话贴 ✨ 不算数，别人认可才算。
        const rid = m.replyTarget() orelse continue;
        const txt = m.soleTextBesidesReply() orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, txt, ws), star)) continue;
        const target = lookup(pool, rid) orelse {
            if (!contains(unresolved.items, rid)) try unresolved.append(gpa, rid);
            continue;
        };
        if (!p.isObserved(target.user_id)) continue;
        if (m.user_id == target.user_id) continue;
        // 引用目标是链成员时同样让路给路径4：这条 ✨ 回复只是在说"这句话说得好"，
        // 链已经替它把这句话（连同它的邻居）收进 joined 语录了。
        if (chainOf(chains, rid) != null) continue;
        try appendCandidate(gpa, &cands, .{
            .message_id = rid,
            .path = .quoted_star,
            .text_override = null,
            .chain_members = null,
        });
    }

    // 剔除已作废的候选
    var kept: std.ArrayList(Candidate) = .empty;
    errdefer {
        // 存活候选的 text_override / chain_members 所有权在下面的循环里从
        // cands 转移到了 kept（cands 随后被 clearAndFree，不再持有它们）；
        // 若这里只 kept.deinit 而不遍历释放，一旦后面任何一次 toOwnedSlice
        // 触发 OOM，这些内存就会泄漏——本文件加的 checkAllAllocationFailures
        // 回归测试正是靠这条路径抓到的。
        for (kept.items) |c| {
            if (c.text_override) |t| gpa.free(t);
            if (c.chain_members) |cm| gpa.free(cm);
        }
        kept.deinit(gpa);
    }
    for (cands.items) |*c| {
        if (contains(revoked.items, c.message_id)) {
            if (c.text_override) |t| gpa.free(t);
            if (c.chain_members) |cm| gpa.free(cm);
            c.text_override = null; // 防止上方 errdefer 在后续 OOM 时对同一指针重复 free
            c.chain_members = null; // 同理
            continue;
        }
        try kept.append(gpa, c.*);
        c.text_override = null; // 所有权转移给 kept 了；同理防止 cands 的 errdefer 在后续 OOM 时重复 free
        c.chain_members = null; // 同理
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
        for (candidates_owned) |c| {
            if (c.text_override) |t| gpa.free(t);
            if (c.chain_members) |cm| gpa.free(cm);
        }
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
/// 两个分支里的 free 都不能删——但注意它们的写法本身不依赖"哪个路径今天
/// 带不带 text_override/chain_members"这类判断：`if (optional) |x| gpa.free(x)`
/// 只看这个候选自己的字段是不是 null，不看 `path`。这不是巧合，是刻意的写法：
/// 一旦要靠"某个路径的 text_override 恒为 null"这种断言来判断该不该 free，
/// 断言本身就必须永远正确——而这类断言天生跟着新路径的增加而变质。这个模块
/// 已经有过两次因为这类假设过期而产生的 double free；本次改动新增的 fire_chain
/// （非 admin_manual 路径）就正好把"只有 admin_manual 带 text_override"这条
/// 旧断言变成了假话，同时它还带上了 chain_members——两个可选字段都必须无
/// 条件按"非 null 就 free"来处理，不看 c.path/existing.path 是谁。
///
///   - else 分支（丢弃新来的 c）：**今天就会被走到**，且不止一种触发方式。
///     一是同一条管理员消息在 window 里出现了两次（c 与 existing 都是
///     admin_manual）——README 线上假设 #2 说明这很可能是 NapCat 的常态行为
///     （`message_seq` 若是闭区间，相邻两页会重叠）。二是理论上若 fire_chain
///     与另一个候选发生 message_id 碰撞也会落到这里（today 不会真的发生，
///     见下一条），c.chain_members 就会在这个分支被释放。删掉这个 free 就是
///     在团队已经预料会走到的路径上引入泄漏。
///   - if 分支（替换掉 existing）：**today**，走到这个分支时 `existing` 只可能
///     是 star_reaction / quoted_star（text_override/chain_members 恒为
///     null），因为 fire_chain 候选在 Pass B 主循环之前就已经全部插入，而
///     Pass B 主循环对任何链成员的 message_id 都不会再产生 admin_manual/
///     emoji_reaction/quoted_star 候选（见 classify 里 `is_chain_member` 那个
///     判断）——appendCandidate 自己看不到这个约束，它活在调用方（classify
///     的 Pass B 循环结构）里，是一处"距离较远"的不变量，不是本函数能强制的
///     局部条件。正因为不能强制，这里的 free 才特意不依赖它：不管这条不变量
///     将来是否被打破，`if (existing.text_override) |t| gpa.free(t)` 和对
///     chain_members 的同款处理都会正确地释放 existing 身上真正持有的东西，
///     不会因为"理论上不该发生"就漏释放。
fn appendCandidate(gpa: std.mem.Allocator, list: *std.ArrayList(Candidate), c: Candidate) !void {
    for (list.items) |*existing| {
        if (existing.message_id != c.message_id) continue;
        if (c.path == .admin_manual and existing.path != .admin_manual) {
            if (existing.text_override) |t| gpa.free(t);
            if (existing.chain_members) |cm| gpa.free(cm);
            existing.* = c;
        } else {
            if (c.text_override) |t| gpa.free(t);
            if (c.chain_members) |cm| gpa.free(cm);
        }
        return;
    }
    try list.append(gpa, c);
}

const OBSERVED: u64 = 10001;
const ADMIN: u64 = 20001;
const OUTSIDER: u64 = 30001;

fn params() Params {
    return .{ .observed_qqs = &.{OBSERVED}, .admin_qqs = &.{ADMIN} };
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
    try std.testing.expectEqual(@as(?[]i64, null), out.candidates[0].chain_members);
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
    const p: Params = .{ .observed_qqs = &.{OBSERVED}, .admin_qqs = &.{OBSERVED} };
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
    // chain_members 是 runner.zig 用来调用 store.Store.addChain 的关键：必须
    // 带上全部成员（含主键自己），顺序与时间升序一致，这样非主键成员才能被
    // 持久化映射到主键，跨窗口撤稿才有依据（见 store.zig key_chainmember_prefix）。
    try std.testing.expectEqualSlices(i64, &.{ 1, 2 }, out.candidates[0].chain_members.?);
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
    try std.testing.expectEqualSlices(i64, &.{ 1, 2, 3 }, out.candidates[0].chain_members.?);
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

test "🔥链：路径2引用链上成员被抑制——只留 fire_chain 一条候选，不重复收录被引用的碎句" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "你们有钱"),
        textMsg(2, OBSERVED, "你们潇洒"),
        replyMsg(3, OUTSIDER, 2, "✨"), // 有人单独对链上第二个成员回 ✨
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 2 }, &.{ 1, 2 }, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(@as(i64, 1), out.candidates[0].message_id);
    try std.testing.expectEqual(Path.fire_chain, out.candidates[0].path);
    try std.testing.expectEqualStrings("你们有钱 你们潇洒", out.candidates[0].text_override.?);
}

test "🔥链：非主键成员自身是路径3格式时被抑制为个体候选，joined正文剥掉它的✨前缀" {
    const gpa = std.testing.allocator;
    // 被观察者同时在 ADMIN_QQS 里，这样第二个成员的 "✨ 你们潇洒" 才满足路径3格式。
    const p: Params = .{ .observed_qqs = &.{OBSERVED}, .admin_qqs = &.{OBSERVED} };
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "你们有钱"),
        textMsg(2, OBSERVED, "✨ 你们潇洒"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 2 }, &.{ 1, 2 }, p);
    defer out.deinit(gpa);

    // 只有一条：fire_chain。若没有抑制，会多出一条路径3候选（message_id=2，
    // 正文"你们潇洒"）；若没有剥 ✨，joined 正文会是"你们有钱 ✨ 你们潇洒"。
    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(@as(i64, 1), out.candidates[0].message_id);
    try std.testing.expectEqual(Path.fire_chain, out.candidates[0].path);
    try std.testing.expectEqualStrings("你们有钱 你们潇洒", out.candidates[0].text_override.?);
}

test "🔥链：主键自身是路径3格式时同样被抑制，链仍然赢（路径4压过路径3）" {
    const gpa = std.testing.allocator;
    const p: Params = .{ .observed_qqs = &.{OBSERVED}, .admin_qqs = &.{OBSERVED} };
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "✨ 你们有钱"),
        textMsg(2, OBSERVED, "你们潇洒"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 2 }, &.{ 1, 2 }, p);
    defer out.deinit(gpa);

    // 若路径3仍然优先（旧规则），这里会得到 message_id=1、path=admin_manual、
    // 正文"你们有钱"（丢了"你们潇洒"）。新规则下链赢，两段都在，✨ 也被剥掉了。
    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(@as(i64, 1), out.candidates[0].message_id);
    try std.testing.expectEqual(Path.fire_chain, out.candidates[0].path);
    try std.testing.expectEqualStrings("你们有钱 你们潇洒", out.candidates[0].text_override.?);
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

// ---------------------------------------------------------------------------
// 观察所有人（OBSERVED_QQS 为空）——这是部署上的常态配置，不是兜底分支。
// 下面这组测试逐条路径确认 Params.isObserved 的"空集合 = 全部"语义真的贯穿到
// 了四条收录路径、撤稿目标判定和链构建，而不是只改了其中几处。

const everyone: Params = .{ .observed_qqs = &.{}, .admin_qqs = &.{ADMIN} };
const subset: Params = .{ .observed_qqs = &.{ OBSERVED, OUTSIDER }, .admin_qqs = &.{ADMIN} };
const THIRD: u64 = 40001;

test "isObserved：空集合对任何人都为真，非空集合只对集合内的人为真" {
    try std.testing.expect(everyone.isObserved(OBSERVED));
    try std.testing.expect(everyone.isObserved(OUTSIDER));
    try std.testing.expect(everyone.isObserved(0));
    try std.testing.expect(subset.isObserved(OBSERVED));
    try std.testing.expect(subset.isObserved(OUTSIDER));
    try std.testing.expect(!subset.isObserved(THIRD));
}

test "观察所有人 · 路径1：任何人的消息带 ✨ 都入选" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, OUTSIDER, "路人甲的金句"), textMsg(2, THIRD, "路人乙的话") };
    var out = try classify(gpa, &msgs, &msgs, &.{1}, &.{}, everyone);
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(@as(i64, 1), out.candidates[0].message_id);
    try std.testing.expectEqual(Path.emoji_reaction, out.candidates[0].path);
}

test "观察所有人 · 路径2：任何人引用任何**别人**的消息回 ✨ 都收录被引用那条" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, OUTSIDER, "路人甲的金句"), replyMsg(2, THIRD, 1, "✨") };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, everyone);
    defer out.deinit(gpa);
    // 机械地把 `m.user_id == observed_qq` 换成 `isObserved(m.user_id)` 会让
    // 这条恒为真、整条路径2静默失效——这个测试就是那条回归的守卫。
    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(@as(i64, 1), out.candidates[0].message_id);
    try std.testing.expectEqual(Path.quoted_star, out.candidates[0].path);
}

test "观察所有人 · 路径2：自己给自己的话回 ✨ 不算数（自吹不是他人认可）" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, OUTSIDER, "我说得真好"), replyMsg(2, OUTSIDER, 1, "✨") };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, everyone);
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
}

test "配置了子集时 · 路径2：集合内的 A 认可集合内的 B → 收录（单人配置下这一条退化成旧行为）" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, OBSERVED, "B 的金句"), replyMsg(2, OUTSIDER, 1, "✨") };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, subset);
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(@as(i64, 1), out.candidates[0].message_id);
}

test "配置了子集时 · 路径1：集合外的人带 ✨ 仍然不入选" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{textMsg(1, THIRD, "集合外的人")};
    var out = try classify(gpa, &msgs, &msgs, &.{1}, &.{}, subset);
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
}

test "观察所有人 · 路径3：管理员手动收录不受影响（ADMIN_QQS 与观察集合是两回事）" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{textMsg(1, ADMIN, "✨ 手动补录")};
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, everyone);
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(Path.admin_manual, out.candidates[0].path);
    try std.testing.expectEqualStrings("手动补录", out.candidates[0].text_override.?);
}

test "观察所有人 · 路径4：任何人的连续消息带 ✨+🔥 都能并成链" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{
        textMsg(1, OUTSIDER, "你们有钱"),
        textMsg(2, OUTSIDER, "你们潇洒"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 2 }, &.{ 1, 2 }, everyone);
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(Path.fire_chain, out.candidates[0].path);
    try std.testing.expectEqualStrings("你们有钱 你们潇洒", out.candidates[0].text_override.?);
}

test "观察所有人 · 撤稿：管理员 💦 引用任何人的消息都能作废" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, THIRD, "路人的话"), replyMsg(2, ADMIN, 1, "💦") };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, everyone);
    defer out.deinit(gpa);
    try std.testing.expectEqualSlices(i64, &.{1}, out.revoked);
}

test "配置了子集时 · 撤稿：💦 引用集合外的人的普通消息 → 不作废（旧行为原样保留）" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, THIRD, "集合外的话"), replyMsg(2, ADMIN, 1, "💦") };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, subset);
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), out.revoked.len);
}

// ---------------------------------------------------------------------------
// 🔥 链的同一发送者约束。

test "🔥链：发送者中途变化 → 断链，两个人各自的半句不会被拼成一条" {
    const gpa = std.testing.allocator;
    // 两条相邻、都带 ✨+🔥，但分别是两个人发的。观察所有人之后这不是理论
    // 情形：任何两个人前后脚说话都可能撞上。合并会产出一条谁都没说过的
    // 语录，`from_who` 也只能取其中一个人——必须断开。
    const msgs = [_]onebot.Message{
        textMsg(1, OUTSIDER, "你们有钱"),
        textMsg(2, THIRD, "你们潇洒"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 2 }, &.{ 1, 2 }, everyone);
    defer out.deinit(gpa);

    // 两条都退回路径1单独收录，没有任何 fire_chain 候选。
    try std.testing.expectEqual(@as(usize, 2), out.candidates.len);
    for (out.candidates) |c| {
        try std.testing.expectEqual(Path.emoji_reaction, c.path);
        try std.testing.expectEqual(@as(?[]i64, null), c.chain_members);
    }
}

test "🔥链：A A B B → 断成两条各自成链，成员不跨作者混入" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{
        textMsg(1, OUTSIDER, "甲上"),
        textMsg(2, OUTSIDER, "甲下"),
        textMsg(3, THIRD, "乙上"),
        textMsg(4, THIRD, "乙下"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 2, 3, 4 }, &.{ 1, 2, 3, 4 }, everyone);
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), out.candidates.len);
    try std.testing.expectEqual(Path.fire_chain, out.candidates[0].path);
    try std.testing.expectEqualStrings("甲上 甲下", out.candidates[0].text_override.?);
    try std.testing.expectEqualSlices(i64, &.{ 1, 2 }, out.candidates[0].chain_members.?);
    try std.testing.expectEqual(Path.fire_chain, out.candidates[1].path);
    try std.testing.expectEqualStrings("乙上 乙下", out.candidates[1].text_override.?);
    try std.testing.expectEqualSlices(i64, &.{ 3, 4 }, out.candidates[1].chain_members.?);
}

test "🔥链：A B A（中间夹一条别人的合格消息）→ 两端的 A 不会跨过 B 连起来" {
    const gpa = std.testing.allocator;
    // 间距上 1 与 3 是能连的（下标差 2 ≤ 4），但中间那条是别人发的，
    // run 在 B 处被打断，A 的两条各自落单，全部退回路径1。
    const msgs = [_]onebot.Message{
        textMsg(1, OUTSIDER, "甲上"),
        textMsg(2, THIRD, "乙插话"),
        textMsg(3, OUTSIDER, "甲下"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 2, 3 }, &.{ 1, 2, 3 }, everyone);
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), out.candidates.len);
    for (out.candidates) |c| try std.testing.expectEqual(Path.emoji_reaction, c.path);
}

fn classifyEveryoneChainUnderFailingAllocator(gpa: std.mem.Allocator) !void {
    // 观察所有人 + 同一发送者约束下的链构建：A A B B B，两条链各自成立，
    // 练 buildChains 里"发送者变化时先 finalize 旧 run 再起新 run"这条
    // 新分支上的每一个分配点（ids/text 两次 ArrayList、chains 扩容、
    // Pass B 转移所有权时的 chain_members dupe）。
    const msgs = [_]onebot.Message{
        textMsg(1, OUTSIDER, "甲上"),
        textMsg(2, OUTSIDER, "甲下"),
        textMsg(3, THIRD, "乙上"),
        textMsg(4, THIRD, "乙中"),
        textMsg(5, THIRD, "乙下"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 2, 3, 4, 5 }, &.{ 1, 2, 3, 4, 5 }, everyone);
    out.deinit(gpa);
}

test "OOM 回归：同一发送者约束下的多条链构建，任意分配点失败都不泄漏也不重复释放" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, classifyEveryoneChainUnderFailingAllocator, .{});
}
