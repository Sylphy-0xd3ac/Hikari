const std = @import("std");
const store = @import("../store.zig");

pub const Encode = enum { json, text, js };

pub const QueryError = error{
    UnsupportedCharset,
    BadLengthRange,
    InvalidNumber,
    InvalidEncode,
    OutOfMemory,
};

pub const Query = struct {
    encode: Encode = .json,
    min_length: ?usize = null,
    max_length: ?usize = null,
    callback: ?[]u8 = null,
    select: []u8,

    pub fn deinit(self: Query, gpa: std.mem.Allocator) void {
        if (self.callback) |c| gpa.free(c);
        gpa.free(self.select);
    }
};

pub const Rendered = struct {
    body: []u8,
    content_type: []const u8,

    pub fn deinit(self: Rendered, gpa: std.mem.Allocator) void {
        gpa.free(self.body);
    }
};

/// 百分号解码到新分配的缓冲区。
///
/// `buf` 从第一次分配起就有 errdefer 兜底：如果 decode 后需要收缩到 `shrunk`
/// 而这第二次分配失败，`buf` 不会被孤儿化——没有它的话，第二次分配失败时
/// `buf` 已经不再被任何变量引用（还没走到 `gpa.free(buf)` 那一行），会在只有
/// 分配失败测试才会走到的路径上泄漏。
fn percentDecodeAlloc(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    const buf = try gpa.dupe(u8, raw);
    errdefer gpa.free(buf);
    const decoded = std.Uri.percentDecodeInPlace(buf);
    if (decoded.len == buf.len) return buf;
    const shrunk = try gpa.dupe(u8, decoded);
    gpa.free(buf);
    return shrunk;
}

/// target 形如 "/" 或 "/?a=b&c=d"。
pub fn parseQuery(gpa: std.mem.Allocator, target: []const u8) QueryError!Query {
    var q: Query = .{ .select = try gpa.dupe(u8, ".hitokoto") };
    errdefer q.deinit(gpa);

    const qmark = std.mem.indexOfScalar(u8, target, '?') orelse return q;
    const qs = target[qmark + 1 ..];

    var it = std.mem.tokenizeScalar(u8, qs, '&');
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        const k = kv[0..eq];
        const v_raw = kv[eq + 1 ..];

        if (std.mem.eql(u8, k, "encode")) {
            if (std.mem.eql(u8, v_raw, "json")) {
                q.encode = .json;
            } else if (std.mem.eql(u8, v_raw, "text")) {
                q.encode = .text;
            } else if (std.mem.eql(u8, v_raw, "js")) {
                q.encode = .js;
            } else return error.InvalidEncode;
        } else if (std.mem.eql(u8, k, "charset")) {
            if (!std.ascii.eqlIgnoreCase(v_raw, "utf-8") and !std.ascii.eqlIgnoreCase(v_raw, "utf8")) {
                return error.UnsupportedCharset;
            }
        } else if (std.mem.eql(u8, k, "min_length")) {
            q.min_length = std.fmt.parseInt(usize, v_raw, 10) catch return error.InvalidNumber;
        } else if (std.mem.eql(u8, k, "max_length")) {
            q.max_length = std.fmt.parseInt(usize, v_raw, 10) catch return error.InvalidNumber;
        } else if (std.mem.eql(u8, k, "callback")) {
            // 先解码出新值、成功了再释放旧值：如果 percentDecodeAlloc 失败,
            // q.callback 必须还指向那个仍然有效的旧分配，好让 errdefer
            // q.deinit(gpa) 释放它恰好一次。反过来（先 free 旧值再 try 解码
            // 新值）会在解码失败时把 q.callback 留在一个已经被释放的指针上，
            // errdefer 再 free 一次就是 use-after-free / 双重释放——
            // checkAllAllocationFailures 用一条设置了两次 select 的查询串
            // 复现过这个崩溃。
            const decoded = try percentDecodeAlloc(gpa, v_raw);
            if (q.callback) |old| gpa.free(old);
            q.callback = decoded;
        } else if (std.mem.eql(u8, k, "select")) {
            const decoded = try percentDecodeAlloc(gpa, v_raw);
            gpa.free(q.select);
            q.select = decoded;
        }
        // 其余参数（含 c）接受但忽略
    }

    if (q.min_length) |lo| {
        if (q.max_length) |hi| {
            if (lo > hi) return error.BadLengthRange;
        }
    }
    return q;
}

const Payload = struct {
    id: u64,
    uuid: []const u8,
    hitokoto: []const u8,
    type: []const u8,
    from: []const u8,
    from_who: []const u8,
    creator: []const u8,
    creator_uid: u64,
    reviewer: u64,
    commit_from: []const u8,
    created_at: []const u8,
    length: usize,
};

/// `std.json.Stringify.value` 写往 `std.Io.Writer.Allocating` 时，唯一可能的
/// 失败原因就是底层分配器 OOM——`Allocating.drain` 把这个失败包装成了
/// `error.WriteFailed`（`Writer.Error` 就只有这一个成员），不是
/// `error.OutOfMemory` 本身。标准库自己的 `Stringify.valueAlloc` 就是这样把
/// `WriteFailed` 翻译回 `OutOfMemory` 的（见 lib/std/json/Stringify.zig）；这里
/// 照抄同一个套路，否则 `checkAllAllocationFailures` 会把这个 `WriteFailed`
/// 当成“非预期错误”直接判失败，而不是把它当一次正常的注入性 OOM 处理。
fn writeJson(v: anytype, writer: *std.Io.Writer) error{OutOfMemory}!void {
    std.json.Stringify.value(v, .{}, writer) catch return error.OutOfMemory;
}

fn jsonBody(gpa: std.mem.Allocator, q: store.Quote) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try writeJson(Payload{
        .id = q.id,
        .uuid = &q.uuid,
        .hitokoto = q.hitokoto,
        .type = q.kind,
        .from = q.from,
        .from_who = q.from_who,
        .creator = q.creator,
        .creator_uid = q.creator_uid,
        .reviewer = q.reviewer,
        .commit_from = q.commit_from,
        .created_at = q.created_at,
        .length = q.length,
    }, &aw.writer);
    return aw.toOwnedSlice();
}

/// 用 JSON 字符串转义规则把任意文本编码成带引号的 JS 字符串字面量。
fn jsString(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try writeJson(s, &aw.writer);
    return aw.toOwnedSlice();
}

pub fn errorBody(gpa: std.mem.Allocator, message: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try writeJson(.{ .message = message }, &aw.writer);
    return aw.toOwnedSlice();
}

pub fn render(gpa: std.mem.Allocator, q: store.Quote, query: Query) !Rendered {
    if (query.callback) |cb| {
        const body_json = try jsonBody(gpa, q);
        defer gpa.free(body_json);
        const out = try std.fmt.allocPrint(gpa, "{s}({s})", .{ cb, body_json });
        return .{ .body = out, .content_type = "application/javascript; charset=utf-8" };
    }

    return switch (query.encode) {
        .json => .{
            .body = try jsonBody(gpa, q),
            .content_type = "application/json; charset=utf-8",
        },
        .text => .{
            .body = try gpa.dupe(u8, q.hitokoto),
            .content_type = "text/plain; charset=utf-8",
        },
        .js => blk: {
            const sel = try jsString(gpa, query.select);
            defer gpa.free(sel);
            const txt = try jsString(gpa, q.hitokoto);
            defer gpa.free(txt);
            const out = try std.fmt.allocPrint(
                gpa,
                "(function(){{var t={s};document.querySelectorAll({s}).forEach(function(e){{e.innerText=t}})}})()",
                .{ txt, sel },
            );
            break :blk .{ .body = out, .content_type = "application/javascript; charset=utf-8" };
        },
    };
}

fn sample() store.Quote {
    return .{
        .id = 42,
        .uuid = "550e8400-e29b-41d4-a716-446655440000".*,
        .hitokoto = "今天也是好天气",
        .kind = "g",
        .from = "测试群",
        .from_who = "小明",
        .creator = "Hikari",
        .creator_uid = 0,
        .reviewer = 0,
        .commit_from = "hikari",
        .created_at = "1700000000",
        .length = 7,
        .message_id = 12345,
        .group_id = 999,
        .user_id = 10001,
    };
}

test "parseQuery 默认值" {
    const gpa = std.testing.allocator;
    const q = try parseQuery(gpa, "/");
    defer q.deinit(gpa);
    try std.testing.expectEqual(Encode.json, q.encode);
    try std.testing.expectEqual(@as(?usize, null), q.min_length);
    try std.testing.expectEqual(@as(?usize, null), q.max_length);
    try std.testing.expectEqual(@as(?[]u8, null), q.callback);
    try std.testing.expectEqualStrings(".hitokoto", q.select);
}

test "parseQuery 解析 encode / 长度 / callback / select" {
    const gpa = std.testing.allocator;
    const q = try parseQuery(gpa, "/?encode=text&min_length=3&max_length=20&callback=moe&select=%23box");
    defer q.deinit(gpa);
    try std.testing.expectEqual(Encode.text, q.encode);
    try std.testing.expectEqual(@as(?usize, 3), q.min_length);
    try std.testing.expectEqual(@as(?usize, 20), q.max_length);
    try std.testing.expectEqualStrings("moe", q.callback.?);
    try std.testing.expectEqualStrings("#box", q.select);
}

test "parseQuery 接受但忽略 c 参数" {
    const gpa = std.testing.allocator;
    const q = try parseQuery(gpa, "/?c=a&c=b");
    defer q.deinit(gpa);
    try std.testing.expectEqual(Encode.json, q.encode);
}

test "parseQuery 只接受 utf-8 的 charset" {
    const gpa = std.testing.allocator;
    const a = try parseQuery(gpa, "/?charset=utf-8");
    defer a.deinit(gpa);
    const b = try parseQuery(gpa, "/?charset=UTF-8");
    defer b.deinit(gpa);
    try std.testing.expectError(error.UnsupportedCharset, parseQuery(gpa, "/?charset=gbk"));
}

test "parseQuery 拒绝非法 encode 与非数字长度" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidEncode, parseQuery(gpa, "/?encode=xml"));
    try std.testing.expectError(error.InvalidNumber, parseQuery(gpa, "/?min_length=abc"));
}

test "parseQuery 拒绝 min > max" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.BadLengthRange, parseQuery(gpa, "/?min_length=10&max_length=3"));
}

test "render json 输出 hitokoto 规范字段" {
    const gpa = std.testing.allocator;
    const q = try parseQuery(gpa, "/");
    defer q.deinit(gpa);
    const r = try render(gpa, sample(), q);
    defer r.deinit(gpa);

    try std.testing.expectEqualStrings("application/json; charset=utf-8", r.content_type);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, r.body, .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 42), o.get("id").?.integer);
    try std.testing.expectEqualStrings("今天也是好天气", o.get("hitokoto").?.string);
    try std.testing.expectEqualStrings("g", o.get("type").?.string);
    try std.testing.expectEqualStrings("测试群", o.get("from").?.string);
    try std.testing.expectEqualStrings("小明", o.get("from_who").?.string);
    try std.testing.expectEqualStrings("Hikari", o.get("creator").?.string);
    try std.testing.expectEqualStrings("hikari", o.get("commit_from").?.string);
    try std.testing.expectEqualStrings("1700000000", o.get("created_at").?.string);
    try std.testing.expectEqual(@as(i64, 7), o.get("length").?.integer);
    try std.testing.expectEqualStrings("550e8400-e29b-41d4-a716-446655440000", o.get("uuid").?.string);
}

test "render text 只返回正文" {
    const gpa = std.testing.allocator;
    const q = try parseQuery(gpa, "/?encode=text");
    defer q.deinit(gpa);
    const r = try render(gpa, sample(), q);
    defer r.deinit(gpa);
    try std.testing.expectEqualStrings("今天也是好天气", r.body);
    try std.testing.expectEqualStrings("text/plain; charset=utf-8", r.content_type);
}

test "render js 生成注入选择器的脚本" {
    const gpa = std.testing.allocator;
    const q = try parseQuery(gpa, "/?encode=js&select=%23box");
    defer q.deinit(gpa);
    const r = try render(gpa, sample(), q);
    defer r.deinit(gpa);
    try std.testing.expectEqualStrings("application/javascript; charset=utf-8", r.content_type);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "#box") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "querySelectorAll") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "今天也是好天气") != null);
}

test "callback 存在时输出 JSONP" {
    const gpa = std.testing.allocator;
    const q = try parseQuery(gpa, "/?callback=moe");
    defer q.deinit(gpa);
    const r = try render(gpa, sample(), q);
    defer r.deinit(gpa);
    try std.testing.expectEqualStrings("application/javascript; charset=utf-8", r.content_type);
    try std.testing.expect(std.mem.startsWith(u8, r.body, "moe({"));
    try std.testing.expect(std.mem.endsWith(u8, r.body, "})"));
}

test "正文里的引号和换行被正确转义" {
    const gpa = std.testing.allocator;
    var q = sample();
    q.hitokoto = "他说\"你好\"\n然后走了";
    const query = try parseQuery(gpa, "/");
    defer query.deinit(gpa);
    const r = try render(gpa, q, query);
    defer r.deinit(gpa);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, r.body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("他说\"你好\"\n然后走了", parsed.value.object.get("hitokoto").?.string);
}

test "errorBody 是合法 JSON" {
    const gpa = std.testing.allocator;
    const b = try errorBody(gpa, "no sentence available");
    defer gpa.free(b);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, b, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("no sentence available", parsed.value.object.get("message").?.string);
}

// ---------------------------------------------------------------------------
// checkAllAllocationFailures：跟 store.zig 里那五个已修复的缺陷同样的思路——
// 普通测试只走分配全部成功的路径，只有在每一步分配都强制失败一次的情况下，
// 才能验证 errdefer 链真的把已经拿到的堆内存全部释放、不多不少。

fn checkParseQueryAlloc(gpa: std.mem.Allocator, target: []const u8) !void {
    // 这条查询串先设置 select，再设置 callback，最后又把 select 换成一个新值
    // ——覆盖“select/callback 在循环中途被替换、旧值恰好释放一次”这条路径，
    // 而不仅仅是从未被设置过的默认路径。
    const q = try parseQuery(gpa, target);
    q.deinit(gpa);
}

test "parseQuery 在分配失败时不泄漏、不重复释放（checkAllAllocationFailures）" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkParseQueryAlloc,
        .{"/?select=%23a&callback=moe&select=%23b"},
    );
}

fn checkRenderAlloc(gpa: std.mem.Allocator, q: store.Quote, query: Query) !void {
    const r = try render(gpa, q, query);
    r.deinit(gpa);
}

test "render(js) 在分配失败时不泄漏、不孤儿化中间缓冲区（checkAllAllocationFailures）" {
    const gpa = std.testing.allocator;
    // js 分支是三段分配里最长的一条：jsString(select) -> jsString(hitokoto) ->
    // 最终 allocPrint，任意一段失败都不能让前面已经分配好的缓冲区悬空。
    const query = try parseQuery(gpa, "/?encode=js&select=%23box");
    defer query.deinit(gpa);
    try std.testing.checkAllAllocationFailures(gpa, checkRenderAlloc, .{ sample(), query });
}

test "render(callback) 在分配失败时不泄漏 jsonBody 中间结果（checkAllAllocationFailures）" {
    const gpa = std.testing.allocator;
    const query = try parseQuery(gpa, "/?callback=moe");
    defer query.deinit(gpa);
    try std.testing.checkAllAllocationFailures(gpa, checkRenderAlloc, .{ sample(), query });
}
