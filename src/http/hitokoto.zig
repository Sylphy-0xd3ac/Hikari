const std = @import("std");
const store = @import("../store.zig");

pub const Encode = enum { json, text, js };

pub const QueryError = error{
    UnsupportedCharset,
    BadLengthRange,
    InvalidNumber,
    InvalidEncode,
    InvalidCallback,
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

/// JSONP callback 名字的合法字符集：字母、数字、下划线、`$`、`.`——这是
/// JSONP 场景下能出现在裸标识符/属性访问表达式里的字符，足够覆盖
/// `foo`、`_bar`、`$baz`、`ns.callback` 这类常见回调名。空字符串同样拒绝：
/// `/?callback=` 会让 q.callback 变成一个非 null 的零长度字符串，
/// render() 会拼出裸的 "({...})"，JSONP 客户端根本没法解析成函数调用。
///
/// 拒绝掉字符集之外的一切输入，是为了堵住经典的 JSONP callback 注入：不做
/// 校验时，`/?callback=alert(document.cookie);//` 会让 callback 原样拼进
/// `std.fmt.allocPrint(gpa, "{s}({s})", .{{ cb, body_json }})`，产出
/// `alert(document.cookie);//({...})`，以 `application/javascript` 的
/// Content-Type 从本服务的 origin 直接吐给浏览器执行——绕过任何信任这个
/// host 的第三方 CSP script-src 白名单。宁可对畸形 callback 返回 400，
/// 也不要静默降级成纯 JSON（客户端本来就是按 JSONP 在解析响应，降级成
/// JSON 它也用不了）。
fn isValidCallback(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '_', '$', '.' => {},
            else => return false,
        }
    }
    return true;
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
            // 先解码出新值、校验 + 成功了再释放旧值：如果 percentDecodeAlloc
            // 失败，或者解码出来的值没通过 isValidCallback 校验，q.callback
            // 必须还指向那个仍然有效的旧分配，好让 errdefer q.deinit(gpa)
            // 释放它恰好一次。反过来（先 free 旧值再 try 解码新值）会在解码
            // 失败时把 q.callback 留在一个已经被释放的指针上，errdefer 再
            // free 一次就是 use-after-free / 双重释放——checkAllAllocationFailures
            // 用一条设置了两次 select、两次 callback 的查询串复现过这个崩溃。
            const decoded = try percentDecodeAlloc(gpa, v_raw);
            errdefer gpa.free(decoded);
            if (!isValidCallback(decoded)) return error.InvalidCallback;
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
fn writeJson(v: anytype, writer: *std.Io.Writer, options: std.json.Stringify.Options) error{OutOfMemory}!void {
    std.json.Stringify.value(v, options, writer) catch return error.OutOfMemory;
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
    }, &aw.writer, .{});
    return aw.toOwnedSlice();
}

/// 用 JSON 字符串转义规则把任意文本编码成带引号的 JS 字符串字面量。
///
/// `escape_unicode = true`：默认选项下 `encodeJsonStringChars` 对 0x20-0xFF
/// 之间除了 `"` `\` 之外的字节一律原样透传，U+2028 (LINE SEPARATOR) /
/// U+2029 (PARAGRAPH SEPARATOR) 也在其中。这两个码点在 ES5~ES2018 里是
/// JS 词法层面的行终止符，字符串字面量里出现未转义的 U+2028/2029 会被
/// 提前截断成 SyntaxError（ES2019 起才把它们从 LineTerminator 里移出）。
/// hitokoto 正文和 select 选择器都来自 QQ 群消息的任意文本，能天然包含
/// 这两个码点，所以不能只做 ASCII 层面的转义。开 escape_unicode 会把所有
/// 非 ASCII 字节转成 `\uXXXX`，连带把这两个码点也转义掉，代价是中文等
/// 非 ASCII 文本在 js 输出里不再是可读的原始 UTF-8，而是 `\uXXXX` 序列——
/// 语义不变（浏览器解析字符串字面量时会还原成同样的字符），只是不便肉眼看。
/// 只在这里开，不动 `jsonBody`：JSON 响应体本身不受“JS 词法行终止符”这条
/// 规则约束，保持可读 UTF-8 更好。
fn jsString(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try writeJson(s, &aw.writer, .{ .escape_unicode = true });
    return aw.toOwnedSlice();
}

pub fn errorBody(gpa: std.mem.Allocator, message: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try writeJson(.{ .message = message }, &aw.writer, .{});
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
        .creator_uid = 123,
        .reviewer = 45,
        .commit_from = "hikari",
        .created_at = "1700000000",
        .length = 7,
        .message_id = 12345,
        .group_id = 999,
        .user_id = 10001,
    };
}

/// 测试专用：取 `s` 里 `start_marker` 之后、`end_marker` 之前的那一段。
/// 用来把 js 输出里 `var t=<JSON字符串字面量>;document...` 中间那段 JSON
/// 字符串切出来，再用 `std.json.parseFromSlice` 解码——因为 `jsString` 开了
/// `escape_unicode`，非 ASCII 文本在 js 源码里不再是原始 UTF-8 子串，没法
/// 直接用 `std.mem.indexOf` 去找，必须真的解码回来再比较。
fn sliceBetween(s: []const u8, start_marker: []const u8, end_marker: []const u8) []const u8 {
    const start = (std.mem.indexOf(u8, s, start_marker) orelse unreachable) + start_marker.len;
    const end = (std.mem.indexOf(u8, s[start..], end_marker) orelse unreachable) + start;
    return s[start..end];
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

test "parseQuery 拒绝非法字符集或为空的 callback（JSONP callback 注入防护）" {
    const gpa = std.testing.allocator;
    // 经典的 JSONP callback 注入 payload：企图把任意 JS 语句拼进响应体。
    try std.testing.expectError(
        error.InvalidCallback,
        parseQuery(gpa, "/?callback=alert(document.cookie);%2F%2F"),
    );
    // 空 callback：q.callback 会是非 null 的零长度串，render() 会拼出裸的
    // "({...})"，JSONP 客户端根本解析不了，不如直接拒绝。
    try std.testing.expectError(error.InvalidCallback, parseQuery(gpa, "/?callback="));
    // 合法字符集：字母、数字、下划线、$、. 都应该放行。
    const q = try parseQuery(gpa, "/?callback=_ns.moe%2499");
    defer q.deinit(gpa);
    try std.testing.expectEqualStrings("_ns.moe$99", q.callback.?);
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
    try std.testing.expectEqual(@as(i64, 123), o.get("creator_uid").?.integer);
    try std.testing.expectEqual(@as(i64, 45), o.get("reviewer").?.integer);
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
    // "#box" 全是 ASCII 可打印字符，escape_unicode 不会动它，可以直接找子串。
    try std.testing.expect(std.mem.indexOf(u8, r.body, "#box") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "querySelectorAll") != null);

    // hitokoto 正文含非 ASCII 字符，jsString 开了 escape_unicode 之后会变成
    // \uXXXX 序列，不能再用 indexOf 找原始 UTF-8 子串——切出 JSON 字符串
    // 字面量、按 JSON 解码回来，才是验证内容正确的办法。
    const t_literal = sliceBetween(r.body, "var t=", ";document");
    const parsed_t = try std.json.parseFromSlice([]const u8, gpa, t_literal, .{});
    defer parsed_t.deinit();
    try std.testing.expectEqualStrings("今天也是好天气", parsed_t.value);
}

test "render js 转义引号、换行，且恶意 select 不破坏脚本结构" {
    const gpa = std.testing.allocator;
    var q = sample();
    q.hitokoto = "他说\"你好\"\n然后走了";
    // select 里塞一个双引号 + "evil"，模拟企图提前闭合 JS 字符串字面量的输入。
    const query = try parseQuery(gpa, "/?encode=js&select=%22evil");
    defer query.deinit(gpa);
    const r = try render(gpa, q, query);
    defer r.deinit(gpa);

    try std.testing.expectEqualStrings("application/javascript; charset=utf-8", r.content_type);

    const t_literal = sliceBetween(r.body, "var t=", ";document");
    const parsed_t = try std.json.parseFromSlice([]const u8, gpa, t_literal, .{});
    defer parsed_t.deinit();
    try std.testing.expectEqualStrings("他说\"你好\"\n然后走了", parsed_t.value);

    const sel_literal = sliceBetween(r.body, "querySelectorAll(", ").forEach");
    const parsed_sel = try std.json.parseFromSlice([]const u8, gpa, sel_literal, .{});
    defer parsed_sel.deinit();
    try std.testing.expectEqualStrings("\"evil", parsed_sel.value);
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
    // 这条查询串把 select 和 callback 都各设置两次——覆盖“select/callback
    // 在循环中途被替换、旧值恰好释放一次”这条路径，而不仅仅是从未被设置过
    // 的默认路径。此前这里只重复了 select，callback 分支的
    // `if (q.callback) |old| gpa.free(old);` 永远只会看到 null，那条替换
    // 路径没有被这个 checkAllAllocationFailures 覆盖到。
    const q = try parseQuery(gpa, target);
    q.deinit(gpa);
}

test "parseQuery 在分配失败时不泄漏、不重复释放（checkAllAllocationFailures）" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkParseQueryAlloc,
        .{"/?select=%23a&callback=moe&select=%23b&callback=nya"},
    );
}

test "parseQuery 在 select/callback 已被替换后遇到非 OOM 错误仍恰好释放一次" {
    // 普通测试只走“成功返回”或者“errdefer 触发一次”的路径；这条专门验证
    // select/callback 已经被替换过（各自的旧分配已经释放过一次）之后，
    // 再遇到一个跟分配无关的错误（min > max）时，errdefer q.deinit(gpa)
    // 释放的是最新的（已替换的）那份内存,而不是已经被释放掉的旧指针。
    // std.testing.allocator 本身的泄漏检测就足以验证这条路径。
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        error.BadLengthRange,
        parseQuery(gpa, "/?select=%23a&callback=moe&min_length=10&max_length=3"),
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
