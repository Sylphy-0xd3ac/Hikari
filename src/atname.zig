//! at 段在**存储文本**里的占位表示，以及渲染时的展开。
//!
//! 问题：`onebot.Message.renderText` 过去把 at 段直接烧成 `@昵称`，QQ 号就此
//! 丢失。于是一条语录入库之后，正文里的 `@某人` 永远停在收录当天那个名字上——
//! 那个人改名（或者，像本仓库上线初期那样，那个名字压根是群名片而不是 QQ 原始
//! 昵称）之后，历史语录再没有任何办法把它修正回来，因为文本里已经没有任何东西
//! 能指认"这四个字当初指的是谁"。`from_who` / `from` 早就靠
//! `hikari:username` / `hikari:groupname` 做到了渲染时解析，正文里的 at 是最后
//! 一处仍然被冻死的名字。
//!
//! 做法：存储文本里 at 段不再写名字，写一个带 QQ 号的占位
//! `\x01{uid}\x02`；`store.Store.resolveDisplayNames` 在渲染时用当前的
//! `hikari:username:{uid}` 把它展开成 `@昵称`（查不到就退回 `@QQ号`，跟改动
//! 之前昵称缺失时的表现一致）。于是"改一次名反映到全部历史语录"这条承诺从
//! `from_who` 扩展到正文本身。
//!
//! 为什么用 U+0001 / U+0002 这两个控制字符：它们在 QQ 聊天文本里不可能自然
//! 出现，又是合法的 UTF-8 单字节、Redis 二进制安全、不需要转义。**渲染路径
//! 一定会把它们全部消费掉**（`resolveDisplayNames` 是所有读路径的必经之地，
//! 见 store.zig `fetchById`），所以它们不会漏进 HTTP 响应。
//!
//! 防伪造：文本段里如果**原样**带着这两个字节，`renderText` / `renderSegments`
//! 会在拼接时把它们丢掉（见 `appendSanitized`）。否则任何人只要发一条内容为
//! `\x01{别人的QQ}\x02` 的消息，就能让自己的语录在渲染时冒充成 at 了那个人。
//! 占位只能由真正的 at 段产生。

const std = @import("std");

pub const open: u8 = 0x01;
pub const close: u8 = 0x02;

/// 一条语录正文里最多展开这么多个**不同**的 QQ。超出的占位原样退回 `@QQ号`。
///
/// 这是一道对 `MGET` 规模的护栏：`resolveDisplayNames` 把正文里的 at 跟
/// `from_who`/`from`/`creator` 合进同一次 MGET，键数量直接由消息内容决定，
/// 而消息内容是外部输入。一条正常语录里的 at 是个位数；64 已经远在任何真实
/// 用法之上，同时把"一条 @全群 三百人的消息"这种极端输入挡在固定成本里。
pub const max_uids: usize = 64;

/// 十进制 u64 最长 20 位，24 字节的栈缓冲永远够用（`bufPrint` 因此可以
/// `catch unreachable`，跟 store.zig 那几个 key 构造函数同一套写法）。
fn digits(buf: *[24]u8, uid: u64) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{uid}) catch unreachable;
}

/// 把一个数字 QQ 的 at 段写成占位。
pub fn append(gpa: std.mem.Allocator, list: *std.ArrayList(u8), uid: u64) !void {
    var buf: [24]u8 = undefined;
    try list.append(gpa, open);
    try list.appendSlice(gpa, digits(&buf, uid));
    try list.append(gpa, close);
}

/// 追加一段**文本段**内容，途中丢掉占位用的控制字节。见文件头「防伪造」。
pub fn appendSanitized(gpa: std.mem.Allocator, list: *std.ArrayList(u8), text: []const u8) !void {
    var rest = text;
    while (std.mem.indexOfAny(u8, rest, &.{ open, close })) |i| {
        try list.appendSlice(gpa, rest[0..i]);
        rest = rest[i + 1 ..];
    }
    try list.appendSlice(gpa, rest);
}

/// 文本里下一个占位的位置与它携带的 QQ。
pub const Hit = struct {
    /// 占位在 `text` 里的起止（含 open、close 两个字节）。
    start: usize,
    end: usize,
    uid: u64,
};

/// 从 `from` 开始找下一个**格式完好**的占位：`\x01` + 至少一位十进制数字 +
/// `\x02`，且数字能装进 u64。格式不完好的 `\x01`（没有闭合、中间夹了非数字、
/// 数字溢出）不是占位，跳过它继续往后找——这样一段被截断或被拼接坏了的文本
/// 最多是少展开一个 at，不会让整条语录渲染失败。
pub fn next(text: []const u8, from: usize) ?Hit {
    var i = from;
    while (std.mem.indexOfScalarPos(u8, text, i, open)) |s| {
        const close_at = std.mem.indexOfScalarPos(u8, text, s + 1, close) orelse return null;
        const body = text[s + 1 .. close_at];
        if (body.len > 0 and allDigits(body)) {
            if (std.fmt.parseInt(u64, body, 10)) |uid| {
                return .{ .start = s, .end = close_at + 1, .uid = uid };
            } else |_| {}
        }
        i = s + 1;
    }
    return null;
}

fn allDigits(s: []const u8) bool {
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// 文本里是否至少有一个格式完好的占位。渲染路径用它决定"这条语录需不需要
/// 走展开"，绝大多数存量语录在这里直接返回 false，不额外付出任何代价。
pub fn has(text: []const u8) bool {
    return next(text, 0) != null;
}

/// 收集正文里出现的**不同** QQ，按首次出现顺序，最多 `max_uids` 个。
/// 调用方负责 free 返回的切片。
pub fn collectUids(gpa: std.mem.Allocator, text: []const u8) ![]u64 {
    var out: std.ArrayList(u64) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (next(text, i)) |hit| {
        i = hit.end;
        if (std.mem.indexOfScalar(u64, out.items, hit.uid) != null) continue;
        if (out.items.len >= max_uids) continue;
        try out.append(gpa, hit.uid);
    }
    return out.toOwnedSlice(gpa);
}

/// 把占位展开成 `@昵称`。`uids` / `names` 是等长的平行数组（`collectUids` 的
/// 结果，加上调用方各自查到的名字）：`names[k]` 为 null 或空串表示"这个人的
/// 昵称查不到"，退回 `@{uid}`——跟改动之前 `at.name` 缺失时 `renderText` 的
/// 表现逐字一致。`uids` 里没有的 QQ（超出 `max_uids` 的那些）同样退回 `@{uid}`。
///
/// 调用方负责 free 返回的切片。文本里没有占位时返回的仍是一份新拷贝，让调用
/// 方的释放纪律不必区分两种情况。
pub fn expand(
    gpa: std.mem.Allocator,
    text: []const u8,
    uids: []const u64,
    names: []const ?[]const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (next(text, i)) |hit| {
        try out.appendSlice(gpa, text[i..hit.start]);
        try out.append(gpa, '@');
        var buf: [24]u8 = undefined;
        try out.appendSlice(gpa, lookup(hit.uid, uids, names) orelse digits(&buf, hit.uid));
        i = hit.end;
    }
    try out.appendSlice(gpa, text[i..]);
    return out.toOwnedSlice(gpa);
}

fn lookup(uid: u64, uids: []const u64, names: []const ?[]const u8) ?[]const u8 {
    const idx = std.mem.indexOfScalar(u64, uids, uid) orelse return null;
    if (idx >= names.len) return null;
    const name = names[idx] orelse return null;
    return if (name.len > 0) name else null;
}

// ---------------------------------------------------------------- tests ----

const testing = std.testing;

fn renderOne(gpa: std.mem.Allocator, uid: u64) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try append(gpa, &list, uid);
    return gpa.dupe(u8, list.items);
}

test "append 写出的占位能被 next 原样读回来" {
    const gpa = testing.allocator;
    const s = try renderOne(gpa, 1393309348);
    defer gpa.free(s);
    try testing.expectEqualStrings("\x011393309348\x02", s);
    const hit = next(s, 0).?;
    try testing.expectEqual(@as(u64, 1393309348), hit.uid);
    try testing.expectEqual(@as(usize, 0), hit.start);
    try testing.expectEqual(s.len, hit.end);
}

test "appendSanitized 丢掉文本段里原样带着的占位字节（防伪造）" {
    const gpa = testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    // 用户手打了一段看起来像占位的东西：控制字节被吃掉，只剩下裸数字，
    // 于是它在渲染时不可能被展开成任何人的昵称。
    try appendSanitized(gpa, &list, "\x011393309348\x02 你好");
    try testing.expectEqualStrings("1393309348 你好", list.items);
    try testing.expect(!has(list.items));
}

test "next 跳过格式不完好的占位：无闭合、夹非数字、空数字、溢出" {
    try testing.expect(next("\x01123", 0) == null); // 没有闭合
    try testing.expect(next("\x01\x02", 0) == null); // 空数字
    try testing.expect(next("\x0112a3\x02", 0) == null); // 夹了非数字
    try testing.expect(next("\x0118446744073709551616\x02", 0) == null); // u64 溢出
    // 坏占位后面还有好占位时不能被前者带跑：继续往后找。
    const hit = next("\x0112a3\x02\x0177\x02", 0).?;
    try testing.expectEqual(@as(u64, 77), hit.uid);
}

test "collectUids 去重、保序，并在 max_uids 处封顶" {
    const gpa = testing.allocator;
    {
        const uids = try collectUids(gpa, "\x0122\x02 a \x0111\x02 b \x0122\x02");
        defer gpa.free(uids);
        try testing.expectEqualSlices(u64, &.{ 22, 11 }, uids);
    }
    {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(gpa);
        for (0..max_uids + 5) |k| try append(gpa, &text, @intCast(k + 1));
        const uids = try collectUids(gpa, text.items);
        defer gpa.free(uids);
        try testing.expectEqual(max_uids, uids.len);
        try testing.expectEqual(@as(u64, 1), uids[0]);
        try testing.expectEqual(@as(u64, max_uids), uids[max_uids - 1]);
    }
}

test "expand：查到名字用 @昵称，查不到/空串/不在表里都退回 @QQ号" {
    const gpa = testing.allocator;
    const text = "\x0110001\x02 说 \x0110002\x02 和 \x0110003\x02 还有 \x0110004\x02";
    const out = try expand(
        gpa,
        text,
        &.{ 10001, 10002, 10003 },
        &.{ "Sylphy", null, "" },
    );
    defer gpa.free(out);
    // 10004 压根不在 uids 里（比如超出了 max_uids），同样退回 @QQ号。
    try testing.expectEqualStrings("@Sylphy 说 @10002 和 @10003 还有 @10004", out);
}

test "expand：没有占位时原样返回一份新拷贝（存量语录走的就是这条）" {
    const gpa = testing.allocator;
    const out = try expand(gpa, "今天也是好天气", &.{}, &.{});
    defer gpa.free(out);
    try testing.expectEqualStrings("今天也是好天气", out);
}

test "expand：坏占位原样保留，不吞掉周围的正文" {
    const gpa = testing.allocator;
    const out = try expand(gpa, "a\x0112a3\x02b\x0177\x02c", &.{77}, &.{"名"});
    defer gpa.free(out);
    try testing.expectEqualStrings("a\x0112a3\x02b@名c", out);
}
