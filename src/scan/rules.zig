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
    errdefer kept.deinit(gpa);
    for (cands.items) |c| {
        if (contains(revoked.items, c.message_id)) {
            if (c.text_override) |t| gpa.free(t);
            continue;
        }
        try kept.append(gpa, c);
    }
    cands.deinit(gpa);

    return .{
        .revoked = try revoked.toOwnedSlice(gpa),
        .candidates = try kept.toOwnedSlice(gpa),
        .unresolved = try unresolved.toOwnedSlice(gpa),
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

// 注意：这两个 helper 必须是 inline fn。它们的 .segments 指向一个匿名数组字面量
// （`&.{...}`），其内容含运行期参数，存储归属于「构造该字面量的那次函数调用」的栈帧；
// 若 textMsg/replyMsg 是普通函数，该栈帧在函数返回时失效，返回的 Message.segments
// 就成了悬垂指针——某些测试凑巧在栈内存被复用前完成读取而“测试通过”，另一些（比如
// 更深的调用链）会读到被复写的垃圾数据。inline 让字面量直接在调用方（测试函数）的
// 栈帧里构造，其生命周期与外层 `const msgs = [_]onebot.Message{...}` 一致，从根上消除悬垂。
inline fn textMsg(id: i64, uid: u64, txt: []const u8) onebot.Message {
    return .{
        .message_id = id,
        .user_id = uid,
        .time = 0,
        .segments = &.{.{ .text = txt }},
    };
}

inline fn replyMsg(id: i64, uid: u64, target: i64, txt: []const u8) onebot.Message {
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
