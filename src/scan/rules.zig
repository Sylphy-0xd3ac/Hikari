const std = @import("std");
const onebot = @import("../onebot.zig");

pub const star = "✨";
pub const drop = "💦";

const ws = " \t\r\n";

pub const Path = enum { emoji_reaction, quoted_star, admin_manual };

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

pub fn classify(
    gpa: std.mem.Allocator,
    window: []const onebot.Message,
    pool: []const onebot.Message,
    star_ids: []const i64,
    p: Params,
) !Outcome {
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
        if (ok and !contains(revoked.items, rid)) try revoked.append(gpa, rid);
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

        // 路径1：被观察者本人的消息带 ✨ 表情回应
        if (m.user_id == p.observed_qq and contains(star_ids, m.message_id)) {
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
    var out = try classify(gpa, &msgs, &msgs, &.{1}, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(@as(i64, 1), out.candidates[0].message_id);
    try std.testing.expectEqual(Path.emoji_reaction, out.candidates[0].path);
    try std.testing.expectEqual(@as(?[]u8, null), out.candidates[0].text_override);
}

test "路径1：非被观察者的消息即使带 ✨ 也不入选" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{textMsg(1, OUTSIDER, "别人的话")};
    var out = try classify(gpa, &msgs, &msgs, &.{1}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
}

test "路径2：他人引用被观察者的消息并只回一个 ✨ → 收录被引用那条" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, OBSERVED, "金句"), replyMsg(2, OUTSIDER, 1, "✨") };
    var out = try classify(gpa, &msgs, &msgs, &.{}, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(@as(i64, 1), out.candidates[0].message_id);
    try std.testing.expectEqual(Path.quoted_star, out.candidates[0].path);
}

test "路径2：✨ 前后带空白仍然算数" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, OBSERVED, "金句"), replyMsg(2, OUTSIDER, 1, "  ✨ \n") };
    var out = try classify(gpa, &msgs, &msgs, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
}

test "路径2：引用的不是被观察者的消息 → 不收录" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, OUTSIDER, "路人话"), replyMsg(2, OUTSIDER, 1, "✨") };
    var out = try classify(gpa, &msgs, &msgs, &.{}, params());
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
    var out = try classify(gpa, &msgs, &msgs, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
}

test "路径2：引用目标在缓冲池里但不在窗口内 → 正常解析" {
    const gpa = std.testing.allocator;
    const old = textMsg(1, OBSERVED, "三天前的金句");
    const window = [_]onebot.Message{replyMsg(2, OUTSIDER, 1, "✨")};
    const pool = [_]onebot.Message{ old, window[0] };
    var out = try classify(gpa, &window, &pool, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(@as(i64, 1), out.candidates[0].message_id);
}

test "路径2：引用目标彻底解析不了 → 记入 unresolved，不中断" {
    const gpa = std.testing.allocator;
    const window = [_]onebot.Message{replyMsg(2, OUTSIDER, 999, "✨")};
    var out = try classify(gpa, &window, &window, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
    try std.testing.expectEqualSlices(i64, &.{999}, out.unresolved);
}

test "路径3：管理员发 ✨ 加内容 → 收录，正文剥掉前缀" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{textMsg(5, ADMIN, "✨ 手动补录的一句话")};
    var out = try classify(gpa, &msgs, &msgs, &.{}, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(@as(i64, 5), out.candidates[0].message_id);
    try std.testing.expectEqual(Path.admin_manual, out.candidates[0].path);
    try std.testing.expectEqualStrings("手动补录的一句话", out.candidates[0].text_override.?);
}

test "路径3：✨ 与内容之间没有空格也认" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{textMsg(5, ADMIN, "✨紧贴的内容")};
    var out = try classify(gpa, &msgs, &msgs, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqualStrings("紧贴的内容", out.candidates[0].text_override.?);
}

test "路径3：管理员只发一个 ✨ → 剥完为空，不收录" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{textMsg(5, ADMIN, "✨   ")};
    var out = try classify(gpa, &msgs, &msgs, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
}

test "路径3：非管理员发 ✨ 加内容 → 不收录" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{textMsg(5, OUTSIDER, "✨ 我也想加一句")};
    var out = try classify(gpa, &msgs, &msgs, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
}

test "路径3：管理员发 ✨ 加内容但带了 reply 段 → 走路径2判定，不收录" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, OBSERVED, "金句"), replyMsg(5, ADMIN, 1, "✨ 加点评") };
    var out = try classify(gpa, &msgs, &msgs, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
}

test "路径3 优先于路径1：被观察者兼任管理员时按路径3处理" {
    const gpa = std.testing.allocator;
    const p: Params = .{ .observed_qq = OBSERVED, .admin_qqs = &.{OBSERVED} };
    const msgs = [_]onebot.Message{textMsg(5, OBSERVED, "✨ 我自己补一句")};
    var out = try classify(gpa, &msgs, &msgs, &.{5}, p);
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(Path.admin_manual, out.candidates[0].path);
    try std.testing.expectEqualStrings("我自己补一句", out.candidates[0].text_override.?);
}

test "作废：管理员 💦 引用被观察者的消息" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, OBSERVED, "失言"), replyMsg(2, ADMIN, 1, "💦") };
    var out = try classify(gpa, &msgs, &msgs, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqualSlices(i64, &.{1}, out.revoked);
}

test "作废：非管理员发 💦 无效" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, OBSERVED, "失言"), replyMsg(2, OUTSIDER, 1, "💦") };
    var out = try classify(gpa, &msgs, &msgs, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), out.revoked.len);
}

test "作废：💦 引用管理员发的普通消息 → 不作废" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, ADMIN, "随便说说"), replyMsg(2, ADMIN, 1, "💦") };
    var out = try classify(gpa, &msgs, &msgs, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), out.revoked.len);
}

test "作废：💦 引用一条路径3手动收录的指令消息 → 应当作废" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, ADMIN, "✨ 手动补录"), replyMsg(2, ADMIN, 1, "💦") };
    var out = try classify(gpa, &msgs, &msgs, &.{}, params());
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
    var out = try classify(gpa, &msgs, &msgs, &.{1}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqualSlices(i64, &.{1}, out.revoked);
    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
}

test "去重：同一条消息被表情回应与引用 ✨ 同时命中 → 只出现一次" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, OBSERVED, "金句"), replyMsg(2, OUTSIDER, 1, "✨") };
    var out = try classify(gpa, &msgs, &msgs, &.{1}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(@as(i64, 1), out.candidates[0].message_id);
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
    var out = try classify(gpa, &msgs, &msgs, &.{}, params());
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
    var out = try classify(gpa, &msgs, &msgs, &.{}, params());
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
