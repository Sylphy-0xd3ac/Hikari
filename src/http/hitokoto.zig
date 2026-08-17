const std = @import("std");
const store = @import("../store.zig");

pub const Encode = enum { json, text, js };

pub const QueryError = error{
    UnsupportedCharset,
    BadLengthRange,
    InvalidNumber,
    InvalidEncode,
    InvalidCallback,
    InvalidUserId,
    InvalidFromWho,
    OutOfMemory,
};

pub const Query = struct {
    encode: Encode = .json,
    min_length: ?usize = null,
    max_length: ?usize = null,
    callback: ?[]u8 = null,
    select: []u8,
    user_id: ?u64 = null,
    from_who: ?[]u8 = null,

    pub fn deinit(self: Query, gpa: std.mem.Allocator) void {
        if (self.callback) |c| gpa.free(c);
        if (self.from_who) |name| gpa.free(name);
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
        } else if (std.mem.eql(u8, k, "user_id")) {
            // QQ 号是非负整数；语法上不合法（负号、非数字、溢出 u64）一律
            // 400，不是"这个人没有语录"——后者是一个合法的空结果（404/[]]），
            // 前者是一个格式错误的请求，两者不能混为一谈。
            q.user_id = std.fmt.parseInt(u64, v_raw, 10) catch return error.InvalidUserId;
        } else if (std.mem.eql(u8, k, "from_who")) {
            const decoded = try percentDecodeAlloc(gpa, v_raw);
            errdefer gpa.free(decoded);
            if (decoded.len == 0 or !std.unicode.utf8ValidateSlice(decoded)) return error.InvalidFromWho;
            if (q.from_who) |old| gpa.free(old);
            q.from_who = decoded;
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

/// `/extra/all` 与 `/extra/batch/:count` 认的数组形态编码——没有 `js`：
/// `js` 是"往 `select` 选中的 DOM 元素里写正文"的自执行脚本，这个概念
/// 本身要求"恰好一条语录、恰好一个 DOM 目标"，对一个数组没有意义（往哪个
/// 元素写哪一条？），`select` 参数因此在这两个端点上也被忽略。
pub const ExtraEncode = enum { json, text };

pub const ExtraQueryError = error{
    UnsupportedCharset,
    BadLengthRange,
    InvalidNumber,
    InvalidEncode,
    /// `encode=js` 语法上合法（`/` 认得这个值），但这两个数组端点不支持
    /// 它——故意用一个跟 `InvalidEncode`（值本身就不认识，比如 `encode=xml`）
    /// 不同的错误名字，好让 server.zig 能给出一条更精确的消息："js 不是
    /// 数组端点支持的编码"而不是笼统的"不认识这个 encode"。两者都映射到
    /// 400，区别只在错误消息的措辞。
    UnsupportedEncode,
    InvalidCallback,
    InvalidUserId,
    InvalidFromWho,
    OutOfMemory,
};

pub const ExtraQuery = struct {
    encode: ExtraEncode = .json,
    min_length: ?usize = null,
    max_length: ?usize = null,
    user_id: ?u64 = null,
    from_who: ?[]u8 = null,
    callback: ?[]u8 = null,

    pub fn deinit(self: ExtraQuery, gpa: std.mem.Allocator) void {
        if (self.callback) |c| gpa.free(c);
        if (self.from_who) |name| gpa.free(name);
    }
};

/// `/extra/all` 与 `/extra/batch/:count` 的查询串解析。跟 `parseQuery`
/// （`/` 用的那个）结构上几乎是镜像，但故意是一个独立的函数、独立的
/// 结构体，不是共用一份代码加 if 分支：两个端点认的参数集合、`encode`
/// 的合法取值、`select` 要不要处理，这些都不一样，共用一份实现只会把
/// "这个端点到底支不支持这个参数"这件事变成运行时才能确定的东西。
///
/// `select` 被有意跳过、不解码也不校验——它落进最后"其余参数接受但忽略"
/// 那一支，不占用任何分配，这也是它跟 `parseQuery` 里 `select` 处理
/// 唯一的区别所在。
pub fn parseExtraQuery(gpa: std.mem.Allocator, target: []const u8) ExtraQueryError!ExtraQuery {
    var q: ExtraQuery = .{};
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
                return error.UnsupportedEncode;
            } else return error.InvalidEncode;
        } else if (std.mem.eql(u8, k, "charset")) {
            if (!std.ascii.eqlIgnoreCase(v_raw, "utf-8") and !std.ascii.eqlIgnoreCase(v_raw, "utf8")) {
                return error.UnsupportedCharset;
            }
        } else if (std.mem.eql(u8, k, "min_length")) {
            q.min_length = std.fmt.parseInt(usize, v_raw, 10) catch return error.InvalidNumber;
        } else if (std.mem.eql(u8, k, "max_length")) {
            q.max_length = std.fmt.parseInt(usize, v_raw, 10) catch return error.InvalidNumber;
        } else if (std.mem.eql(u8, k, "user_id")) {
            q.user_id = std.fmt.parseInt(u64, v_raw, 10) catch return error.InvalidUserId;
        } else if (std.mem.eql(u8, k, "from_who")) {
            const decoded = try percentDecodeAlloc(gpa, v_raw);
            errdefer gpa.free(decoded);
            if (decoded.len == 0 or !std.unicode.utf8ValidateSlice(decoded)) return error.InvalidFromWho;
            if (q.from_who) |old| gpa.free(old);
            q.from_who = decoded;
        } else if (std.mem.eql(u8, k, "callback")) {
            const decoded = try percentDecodeAlloc(gpa, v_raw);
            errdefer gpa.free(decoded);
            if (!isValidCallback(decoded)) return error.InvalidCallback;
            if (q.callback) |old| gpa.free(old);
            q.callback = decoded;
        }
        // 其余参数（含 c、select）接受但忽略
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

/// `/extra/all` 与 `/extra/batch/:count` 用：把一组语录序列化成 JSON 数组，
/// 每个元素跟 `render(..., encode=json)` 产出的对象同构（同一个 `Payload`
/// 类型）。这两个端点不认 `encode`/`min_length`/`max_length`/`callback`/
/// `select`——一言协议本身没有多条语录的形态，这两个端点落在 `/extra/`
/// 前缀下就是在承认它们是超出协议范围的自定义扩展，所以这里不接受、也
/// 不看 `Query`。
///
/// `.uuid = &q.uuid` 取的是切片元素（`quotes[i]`）自己的地址，不是循环变量
/// 的地址：用 `|*q|` 按指针捕获，`q` 指向的是 `quotes` 底层数组里的那个
/// 具体元素，地址在整个 `writeJson` 调用期间稳定；如果按值捕获（`|q|`），
/// `q` 会是每次迭代复用的一份拷贝，`&q.uuid` 在循环结束后要么指向最后一次
/// 迭代遗留的内容，要么在实现按栈槽复用时让多个元素的 `uuid` 字段全部
/// 悄悄指向同一块内存——这不是这里选的实现方式，但值得记录清楚为什么必须
/// 用指针捕获。
pub fn jsonArrayBody(gpa: std.mem.Allocator, quotes: []const store.Quote) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();

    const payloads = try gpa.alloc(Payload, quotes.len);
    defer gpa.free(payloads);
    for (quotes, 0..) |*q, i| {
        payloads[i] = .{
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
        };
    }
    try writeJson(payloads, &aw.writer, .{});
    return aw.toOwnedSlice();
}

/// `encode=text` 在 `/extra/all` 与 `/extra/batch/:count` 上的形态：一个
/// JSON 字符串数组，只有 `hitokoto` 正文，跟 `encode=json` 的完整对象数组
/// 是同一批语录的两种不同投影。空切片产出 `[]`，跟 `jsonArrayBody` 一致。
pub fn textArrayBody(gpa: std.mem.Allocator, quotes: []const store.Quote) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();

    const strs = try gpa.alloc([]const u8, quotes.len);
    defer gpa.free(strs);
    for (quotes, 0..) |q, i| strs[i] = q.hitokoto;

    try writeJson(strs, &aw.writer, .{});
    return aw.toOwnedSlice();
}

/// `encode` 决定数组元素的形状（`json` 的完整对象 / `text` 的纯字符串），
/// `extraArrayBody` 只是把这个选择收敛成一处，`renderExtra` 与调用方都不用
/// 各自维护一份 switch。
fn extraArrayBody(gpa: std.mem.Allocator, quotes: []const store.Quote, encode: ExtraEncode) ![]u8 {
    return switch (encode) {
        .json => jsonArrayBody(gpa, quotes),
        .text => textArrayBody(gpa, quotes),
    };
}

/// `/extra/all` 与 `/extra/batch/:count` 的统一渲染入口，跟 `render`（`/`
/// 用的那个）结构对称：`encode` 决定数组元素的形状，`callback` 存在时把
/// **整个数组**——不管是对象数组还是字符串数组——包进 `{callback}({body})`
/// 的 JSONP 壳。跟 `/` 的 `render` 不同的是，这里 `callback` 不会覆盖
/// `encode` 的选择（`/` 的 Hitokoto 语义里 callback 恒定输出完整对象，
/// 数组端点没有对应的既有约定，选择让两者正交：callback 只管"要不要包一层
/// 函数调用"，不改变数组本身的形状）。
pub fn renderExtra(gpa: std.mem.Allocator, quotes: []const store.Quote, query: ExtraQuery) !Rendered {
    const body = try extraArrayBody(gpa, quotes, query.encode);
    if (query.callback) |cb| {
        defer gpa.free(body);
        const out = try std.fmt.allocPrint(gpa, "{s}({s})", .{ cb, body });
        return .{ .body = out, .content_type = "application/javascript; charset=utf-8" };
    }
    return .{ .body = body, .content_type = "application/json; charset=utf-8" };
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

test "parseQuery 解析 user_id" {
    const gpa = std.testing.allocator;
    const q = try parseQuery(gpa, "/?user_id=10001");
    defer q.deinit(gpa);
    try std.testing.expectEqual(@as(?u64, 10001), q.user_id);
}

test "parseQuery 解析百分号编码的 from_who，且 user_id 仍只接受数字" {
    const gpa = std.testing.allocator;
    const q = try parseQuery(gpa, "/?from_who=%E5%B0%8F%E6%98%8E");
    defer q.deinit(gpa);
    try std.testing.expectEqualStrings("小明", q.from_who.?);
    try std.testing.expectError(error.InvalidUserId, parseQuery(gpa, "/?user_id=%E5%B0%8F%E6%98%8E"));
    try std.testing.expectError(error.InvalidFromWho, parseQuery(gpa, "/?from_who="));
    try std.testing.expectError(error.InvalidFromWho, parseQuery(gpa, "/?from_who=%FF"));
}

test "parseQuery 不带 user_id 时是 null" {
    const gpa = std.testing.allocator;
    const q = try parseQuery(gpa, "/");
    defer q.deinit(gpa);
    try std.testing.expectEqual(@as(?u64, null), q.user_id);
}

test "parseQuery 拒绝非法 user_id（负数、非数字、溢出 u64）—— 400 而不是当成\"这个人没有语录\"" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidUserId, parseQuery(gpa, "/?user_id=-1"));
    try std.testing.expectError(error.InvalidUserId, parseQuery(gpa, "/?user_id=abc"));
    try std.testing.expectError(error.InvalidUserId, parseQuery(gpa, "/?user_id="));
    // u64 最大值是 18446744073709551615，多一位数字就溢出。
    try std.testing.expectError(error.InvalidUserId, parseQuery(gpa, "/?user_id=184467440737095516150"));
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
        .{"/?select=%23a&callback=moe&from_who=%E5%B0%8F%E6%98%8E&select=%23b&callback=nya&from_who=%E5%B0%8F%E7%BA%A2"},
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

// ---------------------------------------------------------------------------
// jsonArrayBody —— `/extra/all` 与 `/extra/batch/:count` 的 JSON 数组编码。

fn sample2() store.Quote {
    return .{
        .id = 43,
        .uuid = "660e8400-e29b-41d4-a716-446655440001".*,
        .hitokoto = "第二条语录",
        .kind = "g",
        .from = "测试群",
        .from_who = "小红",
        .creator = "Hikari",
        .creator_uid = 0,
        .reviewer = 0,
        .commit_from = "hikari",
        .created_at = "1700000100",
        .length = 5,
        .message_id = 999,
        .group_id = 999,
        .user_id = 10002,
    };
}

test "jsonArrayBody 产出与元素个数一致的 JSON 数组，字段跟 encode=json 的单条对象同构" {
    const gpa = std.testing.allocator;
    const quotes = [_]store.Quote{ sample(), sample2() };
    const body = try jsonArrayBody(gpa, &quotes);
    defer gpa.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();
    const arr = parsed.value.array.items;
    try std.testing.expectEqual(@as(usize, 2), arr.len);
    try std.testing.expectEqualStrings("今天也是好天气", arr[0].object.get("hitokoto").?.string);
    try std.testing.expectEqualStrings("550e8400-e29b-41d4-a716-446655440000", arr[0].object.get("uuid").?.string);
    try std.testing.expectEqualStrings("第二条语录", arr[1].object.get("hitokoto").?.string);
    try std.testing.expectEqualStrings("660e8400-e29b-41d4-a716-446655440001", arr[1].object.get("uuid").?.string);
    try std.testing.expectEqual(@as(i64, 43), arr[1].object.get("id").?.integer);
}

test "jsonArrayBody 空切片产出 []" {
    const gpa = std.testing.allocator;
    const body = try jsonArrayBody(gpa, &.{});
    defer gpa.free(body);
    try std.testing.expectEqualStrings("[]", body);
}

fn checkJsonArrayBodyAlloc(gpa: std.mem.Allocator, quotes: []const store.Quote) !void {
    const b = try jsonArrayBody(gpa, quotes);
    gpa.free(b);
}

test "jsonArrayBody 在多条语录序列化时分配失败不泄漏（checkAllAllocationFailures）" {
    const gpa = std.testing.allocator;
    const quotes = [_]store.Quote{ sample(), sample2() };
    try std.testing.checkAllAllocationFailures(gpa, checkJsonArrayBodyAlloc, .{quotes[0..]});
}

// ---------------------------------------------------------------------------
// textArrayBody / extraArrayBody / renderExtra —— `/extra/all` 与
// `/extra/batch/:count` 的 `encode=text` 数组形态、以及两个端点共用的渲染
// 入口。

test "textArrayBody 产出跟元素个数一致的字符串数组，只有 hitokoto 正文" {
    const gpa = std.testing.allocator;
    const quotes = [_]store.Quote{ sample(), sample2() };
    const body = try textArrayBody(gpa, &quotes);
    defer gpa.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();
    const arr = parsed.value.array.items;
    try std.testing.expectEqual(@as(usize, 2), arr.len);
    try std.testing.expectEqualStrings("今天也是好天气", arr[0].string);
    try std.testing.expectEqualStrings("第二条语录", arr[1].string);
}

test "textArrayBody 空切片产出 []" {
    const gpa = std.testing.allocator;
    const body = try textArrayBody(gpa, &.{});
    defer gpa.free(body);
    try std.testing.expectEqualStrings("[]", body);
}

fn checkTextArrayBodyAlloc(gpa: std.mem.Allocator, quotes: []const store.Quote) !void {
    const b = try textArrayBody(gpa, quotes);
    gpa.free(b);
}

test "textArrayBody 在多条语录序列化时分配失败不泄漏（checkAllAllocationFailures）" {
    const gpa = std.testing.allocator;
    const quotes = [_]store.Quote{ sample(), sample2() };
    try std.testing.checkAllAllocationFailures(gpa, checkTextArrayBodyAlloc, .{quotes[0..]});
}

test "parseExtraQuery 默认值：json 编码，没有过滤，没有 callback" {
    const gpa = std.testing.allocator;
    const q = try parseExtraQuery(gpa, "/extra/all");
    defer q.deinit(gpa);
    try std.testing.expectEqual(ExtraEncode.json, q.encode);
    try std.testing.expectEqual(@as(?usize, null), q.min_length);
    try std.testing.expectEqual(@as(?usize, null), q.max_length);
    try std.testing.expectEqual(@as(?u64, null), q.user_id);
    try std.testing.expectEqual(@as(?[]u8, null), q.callback);
}

test "parseExtraQuery 解析 user_id / 长度 / encode=text / callback" {
    const gpa = std.testing.allocator;
    const q = try parseExtraQuery(gpa, "/extra/all?user_id=10001&min_length=3&max_length=20&encode=text&callback=moe");
    defer q.deinit(gpa);
    try std.testing.expectEqual(ExtraEncode.text, q.encode);
    try std.testing.expectEqual(@as(?usize, 3), q.min_length);
    try std.testing.expectEqual(@as(?usize, 20), q.max_length);
    try std.testing.expectEqual(@as(?u64, 10001), q.user_id);
    try std.testing.expectEqualStrings("moe", q.callback.?);
}

test "parseExtraQuery 在 all/batch 共用路径解析 from_who" {
    const gpa = std.testing.allocator;
    const all = try parseExtraQuery(gpa, "/extra/all?from_who=%E5%B0%8F%E6%98%8E");
    defer all.deinit(gpa);
    try std.testing.expectEqualStrings("小明", all.from_who.?);

    const batch = try parseExtraQuery(gpa, "/extra/batch/2?from_who=%E5%B0%8F%E7%BA%A2");
    defer batch.deinit(gpa);
    try std.testing.expectEqualStrings("小红", batch.from_who.?);
    try std.testing.expectError(error.InvalidFromWho, parseExtraQuery(gpa, "/extra/all?from_who="));
    try std.testing.expectError(error.InvalidFromWho, parseExtraQuery(gpa, "/extra/all?from_who=%FF"));
}

test "parseExtraQuery：encode=js 是 error.UnsupportedEncode，不是静默降级成 json" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedEncode, parseExtraQuery(gpa, "/extra/all?encode=js"));
    // 跟"这个 encode 压根不认识"（比如 xml）区分开：一个是"合法值、这个
    // 端点不支持"，一个是"这个值本身就不认识"，映射到 400 的同时给不同
    // 的错误消息（server.zig）。
    try std.testing.expectError(error.InvalidEncode, parseExtraQuery(gpa, "/extra/all?encode=xml"));
}

test "parseExtraQuery：select 被接受但完全忽略，不解码也不占分配、不出现在结构体上" {
    const gpa = std.testing.allocator;
    // 恶意/畸形的 select 值（企图闭合脚本的双引号）在这两个端点上不该有
    // 任何效果——它不是 ExtraQuery 的字段，压根不会被读到。
    const q = try parseExtraQuery(gpa, "/extra/all?select=%22evil");
    defer q.deinit(gpa);
    try std.testing.expectEqual(ExtraEncode.json, q.encode);
}

test "parseExtraQuery 拒绝非法 user_id / 非法 encode / 非数字长度 / min>max / 非 utf-8 charset" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidUserId, parseExtraQuery(gpa, "/extra/all?user_id=abc"));
    try std.testing.expectError(error.InvalidUserId, parseExtraQuery(gpa, "/extra/all?user_id=-1"));
    try std.testing.expectError(error.InvalidEncode, parseExtraQuery(gpa, "/extra/all?encode=xml"));
    try std.testing.expectError(error.InvalidNumber, parseExtraQuery(gpa, "/extra/all?min_length=abc"));
    try std.testing.expectError(error.BadLengthRange, parseExtraQuery(gpa, "/extra/all?min_length=10&max_length=3"));
    try std.testing.expectError(error.UnsupportedCharset, parseExtraQuery(gpa, "/extra/all?charset=gbk"));
    const ok = try parseExtraQuery(gpa, "/extra/all?charset=utf-8");
    defer ok.deinit(gpa);
}

test "parseExtraQuery 接受但忽略 c 参数" {
    const gpa = std.testing.allocator;
    const q = try parseExtraQuery(gpa, "/extra/all?c=a&c=b");
    defer q.deinit(gpa);
    try std.testing.expectEqual(ExtraEncode.json, q.encode);
}

test "parseExtraQuery 拒绝非法字符集或为空的 callback（跟 parseQuery 共用同一套 JSONP 校验）" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidCallback,
        parseExtraQuery(gpa, "/extra/all?callback=alert(document.cookie);%2F%2F"),
    );
    try std.testing.expectError(error.InvalidCallback, parseExtraQuery(gpa, "/extra/all?callback="));
}

fn checkParseExtraQueryAlloc(gpa: std.mem.Allocator, target: []const u8) !void {
    const q = try parseExtraQuery(gpa, target);
    q.deinit(gpa);
}

test "parseExtraQuery 在分配失败时不泄漏（checkAllAllocationFailures）" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkParseExtraQueryAlloc,
        .{"/extra/all?callback=moe&from_who=%E5%B0%8F%E6%98%8E&callback=nya&from_who=%E5%B0%8F%E7%BA%A2"},
    );
}

test "renderExtra：encode=json（默认）产出完整对象数组，Content-Type 固定 application/json" {
    const gpa = std.testing.allocator;
    const quotes = [_]store.Quote{ sample(), sample2() };
    const q = try parseExtraQuery(gpa, "/extra/all");
    defer q.deinit(gpa);
    const r = try renderExtra(gpa, &quotes, q);
    defer r.deinit(gpa);
    try std.testing.expectEqualStrings("application/json; charset=utf-8", r.content_type);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, r.body, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
}

test "renderExtra：encode=text 产出字符串数组，Content-Type 仍是 application/json" {
    const gpa = std.testing.allocator;
    const quotes = [_]store.Quote{ sample(), sample2() };
    const q = try parseExtraQuery(gpa, "/extra/all?encode=text");
    defer q.deinit(gpa);
    const r = try renderExtra(gpa, &quotes, q);
    defer r.deinit(gpa);
    try std.testing.expectEqualStrings("application/json; charset=utf-8", r.content_type);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, r.body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("今天也是好天气", parsed.value.array.items[0].string);
}

test "renderExtra：callback 存在时把整个数组包进 JSONP，Content-Type 变成 application/javascript" {
    const gpa = std.testing.allocator;
    const quotes = [_]store.Quote{ sample(), sample2() };
    const q = try parseExtraQuery(gpa, "/extra/all?callback=moe");
    defer q.deinit(gpa);
    const r = try renderExtra(gpa, &quotes, q);
    defer r.deinit(gpa);
    try std.testing.expectEqualStrings("application/javascript; charset=utf-8", r.content_type);
    try std.testing.expect(std.mem.startsWith(u8, r.body, "moe(["));
    try std.testing.expect(std.mem.endsWith(u8, r.body, "])"));
}

test "renderExtra：callback + encode=text 组合，JSONP 包的是字符串数组" {
    const gpa = std.testing.allocator;
    const quotes = [_]store.Quote{sample()};
    const q = try parseExtraQuery(gpa, "/extra/all?callback=moe&encode=text");
    defer q.deinit(gpa);
    const r = try renderExtra(gpa, &quotes, q);
    defer r.deinit(gpa);
    try std.testing.expectEqualStrings("application/javascript; charset=utf-8", r.content_type);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "\"今天也是好天气\"") != null);
}

test "renderExtra：空切片仍然产出合法的 [] / callback([])" {
    const gpa = std.testing.allocator;
    const q = try parseExtraQuery(gpa, "/extra/all");
    defer q.deinit(gpa);
    const r = try renderExtra(gpa, &.{}, q);
    defer r.deinit(gpa);
    try std.testing.expectEqualStrings("[]", r.body);
}

fn checkRenderExtraAlloc(gpa: std.mem.Allocator, quotes: []const store.Quote, query: ExtraQuery) !void {
    const r = try renderExtra(gpa, quotes, query);
    r.deinit(gpa);
}

test "renderExtra(callback) 在分配失败时不泄漏中间的数组 body（checkAllAllocationFailures）" {
    const gpa = std.testing.allocator;
    const quotes = [_]store.Quote{ sample(), sample2() };
    const query = try parseExtraQuery(gpa, "/extra/all?callback=moe");
    defer query.deinit(gpa);
    try std.testing.checkAllAllocationFailures(gpa, checkRenderExtraAlloc, .{ quotes[0..], query });
}
