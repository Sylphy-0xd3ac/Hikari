const std = @import("std");
const atname = @import("atname.zig");

pub const At = struct { qq: []const u8, name: ?[]const u8 };

/// NapCat 图片段里 Hikari 实际会用到的两个定位字段。`file` 可能只是 NapCat
/// 所在机器上的 id / 路径，`url` 是它随消息一并给出的下载地址；本机 OCR
/// 只使用 http(s) URL，个人表情见 market_face。
pub const Image = struct {
    file: ?[]const u8,
    url: ?[]const u8,
    /// NapCat 内部的 marketFaceElement（QQ 商城/个人表情）。当前版本接收时
    /// 通常把它转换成 image 段，但旧版本、转发内容或其它适配器也可能直接
    /// 给 mface。OCR 时这类段使用 URL：部分版本把 file 固定写成
    /// "marketface"，它不是可下载的真实文件 id。
    market_face: bool = false,
};

pub const Segment = union(enum) {
    text: []const u8,
    at: At,
    reply: i64,
    image: Image,
    other,
};

const ws = " \t\r\n";

pub const Message = struct {
    message_id: i64,
    user_id: u64,
    time: i64,
    segments: []const Segment,

    pub fn replyTarget(self: Message) ?i64 {
        for (self.segments) |s| switch (s) {
            .reply => |id| return id,
            else => {},
        };
        return null;
    }

    /// 除 reply 段外恰好只剩一个段，且它是 text → 返回该文本。
    /// 其余情况（多个文本段、夹带 at/image 等、没有文本段）一律 null。
    pub fn soleTextBesidesReply(self: Message) ?[]const u8 {
        var found: ?[]const u8 = null;
        for (self.segments) |s| switch (s) {
            .reply => {},
            .text => |t| {
                if (found != null) return null;
                found = t;
            },
            else => return null,
        };
        return found;
    }

    /// 是否至少有一个带可用 file/url 的图片段。图片仍不会被 `renderText`
    /// 渲染成占位符；runner 只在正常文本为空时才把它交给本机 OCR。
    pub fn hasImage(self: Message) bool {
        for (self.segments) |s| switch (s) {
            .image => |img| if (img.file != null or img.url != null) return true,
            else => {},
        };
        return false;
    }

    /// 渲染成**存储文本**：text 段原样（但按 `atname.appendSanitized` 剔除占位
    /// 控制字节），数字 QQ 的 at 段写成 `atname` 占位（带 QQ 号，不带名字），
    /// 其余段丢弃，首尾 trim。
    ///
    /// **at 段不再在这里烧成 `@昵称`**：名字改成渲染时才解析（`atname` 文件头
    /// 说明了为什么）。`@全体成员` 这类 `qq` 不是数字的目标没有 QQ 号可查，
    /// 保留改动之前的 `@{qq}` 字面写法。`a.name` 因此不再参与存储文本，但
    /// `resolveAtNames` 仍然要跑：它顺带把 `hikari:username:{uid}` 刷成 QQ
    /// 原始昵称，那正是渲染时展开占位要读的键。
    ///
    /// 返回新分配的内存，调用方负责 free。
    pub fn renderText(self: Message, gpa: std.mem.Allocator) ![]u8 {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(gpa);
        for (self.segments) |s| switch (s) {
            .text => |t| try atname.appendSanitized(gpa, &list, t),
            .at => |a| if (std.fmt.parseInt(u64, std.mem.trim(u8, a.qq, ws), 10)) |uid|
                try atname.append(gpa, &list, uid)
            else |_| {
                try list.append(gpa, '@');
                try atname.appendSanitized(gpa, &list, a.qq);
            },
            else => {},
        };
        return gpa.dupe(u8, std.mem.trim(u8, list.items, ws));
    }
};

/// NapCat 的数字字段有时是 number 有时是 string，两种都接受。
///
/// `.float` 一支必须先验范围再转：`@intFromFloat` 在目标类型装不下时是
/// 安全检查触发的 panic，不是可捕获的错误，而这里的输入全部来自 NapCat
/// （再往上是任意 QQ 用户）。std.json 把任何带 `.`/`e`/`E` 的数字都交给
/// parseFloat，只有非有限值才退回 `.number_string`，所以 `1e19` 这种
/// "有限但装不进 i64" 的写法会原样以 `.float` 到达这里——不验范围的话，
/// 任意一个数字字段这么回一次就能把整个守护进程连同 HTTP 一起打崩。
///
/// 边界用 ±2^63 的字面量而不是 `maxInt(i64)`：后者转成 f64 会向上舍入到
/// 2^63，把恰好等于 2^63 的输入放进来，正好是会 panic 的那个值。NaN 和
/// ±inf 在这组比较里一律为假，自然落到 null。
pub fn asInt(v: std.json.Value) ?i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |f| if (f >= -9223372036854775808.0 and f < 9223372036854775808.0)
            @intFromFloat(f)
        else
            null,
        .string => |s| std.fmt.parseInt(i64, std.mem.trim(u8, s, ws), 10) catch null,
        else => null,
    };
}

fn asStr(v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn intField(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    return asInt(obj.get(key) orelse return null);
}

/// 把 NapCat 的 image/mface 两种上报归一成同一个可 OCR 图片段。
///
/// NapCat 当前源码会把接收到的 marketFaceElement 转成 image，并附上
/// emoji_id + 一个 raw300.gif URL；协议同时允许发送/转发路径保留 mface。
/// 为兼容没有 url 的 mface，这里按 NapCat 自己的 URL 规则从 emoji_id 补出
/// 同一张图。emoji_id 是 QQ/NapCat 生成的标识，不来自 Hikari 的 URL 输入。
fn parseImage(arena: std.mem.Allocator, d: std.json.ObjectMap, market_hint: bool) !Image {
    const file0 = if (d.get("file")) |fv| asStr(fv) else null;
    const url0 = if (d.get("url")) |uv| asStr(uv) else null;
    const emoji_id = if (d.get("emoji_id")) |ev| asStr(ev) else null;
    const file = if (file0) |f| if (f.len > 0) f else null else null;
    var url = if (url0) |u| if (u.len > 0) u else null else null;
    const market_face = market_hint or emoji_id != null or (file != null and std.mem.eql(u8, file.?, "marketface"));
    if (market_face and url == null) {
        if (emoji_id) |id| {
            if (id.len > 0) {
                const dir_len: usize = @min(id.len, 2);
                url = try std.fmt.allocPrint(
                    arena,
                    "https://gxh.vip.qq.com/club/item/parcel/item/{s}/{s}/raw300.gif",
                    .{ id[0..dir_len], id },
                );
            }
        }
    }
    return .{ .file = file, .url = url, .market_face = market_face };
}

pub fn parseMessage(arena: std.mem.Allocator, v: std.json.Value) !?Message {
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };
    const mid = intField(obj, "message_id") orelse return null;
    const uid = intField(obj, "user_id") orelse return null;
    if (uid < 0) return null;
    const t = intField(obj, "time") orelse 0;

    var segs: std.ArrayList(Segment) = .empty;
    if (obj.get("message")) |mv| {
        if (mv == .array) {
            for (mv.array.items) |sv| {
                const so = switch (sv) {
                    .object => |o| o,
                    else => continue,
                };
                const ty = asStr(so.get("type") orelse continue) orelse continue;
                const data: ?std.json.ObjectMap = switch (so.get("data") orelse std.json.Value{ .null = {} }) {
                    .object => |o| o,
                    else => null,
                };
                if (std.mem.eql(u8, ty, "text")) {
                    const txt = if (data) |d| (asStr(d.get("text") orelse std.json.Value{ .null = {} }) orelse "") else "";
                    try segs.append(arena, .{ .text = txt });
                } else if (std.mem.eql(u8, ty, "at")) {
                    const d = data orelse {
                        try segs.append(arena, .other);
                        continue;
                    };
                    const qq = asStr(d.get("qq") orelse std.json.Value{ .null = {} }) orelse "";
                    // `at.data.name` 是该群里的展示名，通常就是群名片。昵称的
                    // 唯一可信来源是 runner 统一查询 get_group_member_info 后的
                    // `nickname` 字段；先丢弃这里的值，避免任一未经过补全的路径
                    // 意外把群名片写入正文或 Redis。
                    try segs.append(arena, .{ .at = .{ .qq = qq, .name = null } });
                } else if (std.mem.eql(u8, ty, "reply")) {
                    const d = data orelse {
                        try segs.append(arena, .other);
                        continue;
                    };
                    const rid = if (d.get("id")) |iv| asInt(iv) else null;
                    if (rid) |r| {
                        try segs.append(arena, .{ .reply = r });
                    } else {
                        try segs.append(arena, .other);
                    }
                } else if (std.mem.eql(u8, ty, "image") or std.mem.eql(u8, ty, "mface")) {
                    const d = data orelse {
                        try segs.append(arena, .other);
                        continue;
                    };
                    try segs.append(arena, .{ .image = try parseImage(arena, d, std.mem.eql(u8, ty, "mface")) });
                } else {
                    try segs.append(arena, .other);
                }
            }
        }
    }

    return Message{
        .message_id = mid,
        .user_id = @intCast(uid),
        .time = t,
        .segments = try segs.toOwnedSlice(arena),
    };
}

pub fn parseMessages(arena: std.mem.Allocator, v: std.json.Value) ![]Message {
    var out: std.ArrayList(Message) = .empty;
    const arr = switch (v) {
        .array => |a| a,
        else => return out.toOwnedSlice(arena),
    };
    for (arr.items) |item| {
        if (try parseMessage(arena, item)) |m| try out.append(arena, m);
    }
    return out.toOwnedSlice(arena);
}

fn parseOne(arena: std.mem.Allocator, src: []const u8) !Message {
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, src, .{});
    return (try parseMessage(arena, parsed.value)).?;
}

test "解析 text 段并渲染" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const m = try parseOne(a,
        \\{"message_id":7,"user_id":10001,"time":100,
        \\ "message":[{"type":"text","data":{"text":"  hello  "}}]}
    );
    try std.testing.expectEqual(@as(i64, 7), m.message_id);
    try std.testing.expectEqual(@as(u64, 10001), m.user_id);
    const t = try m.renderText(a);
    try std.testing.expectEqualStrings("hello", t);
}

test "user_id 与 message_id 可以是字符串" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const m = try parseOne(a,
        \\{"message_id":"7","user_id":"10001","time":"100","message":[]}
    );
    try std.testing.expectEqual(@as(i64, 7), m.message_id);
    try std.testing.expectEqual(@as(u64, 10001), m.user_id);
    try std.testing.expectEqual(@as(i64, 100), m.time);
}

test "asInt：超出 i64 范围的浮点数返回 null，不是让 @intFromFloat 把进程打崩" {
    // std.json 把带 . / e / E 的数字一律走 parseFloat，只有非有限值才退回
    // .number_string。所以 1e19 这种"有限但装不进 i64"的写法会以 .float
    // 到达这里，未检查的 @intFromFloat 在 ReleaseSafe 下是直接 panic——
    // NapCat 任意一个数字字段这么回一次，整个守护进程连同 HTTP 一起死。
    try std.testing.expectEqual(@as(?i64, null), asInt(.{ .float = 1e19 }));
    try std.testing.expectEqual(@as(?i64, null), asInt(.{ .float = -1e19 }));
    try std.testing.expectEqual(@as(?i64, null), asInt(.{ .float = std.math.inf(f64) }));
    try std.testing.expectEqual(@as(?i64, null), asInt(.{ .float = std.math.nan(f64) }));
}

test "asInt：范围内的浮点数照常取整数部分" {
    try std.testing.expectEqual(@as(?i64, 7), asInt(.{ .float = 7.0 }));
    try std.testing.expectEqual(@as(?i64, -7), asInt(.{ .float = -7.9 }));
}

test "parseMessage：message_id 是超范围浮点数时整条消息被丢弃" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const parsed = try std.json.parseFromSlice(std.json.Value, a,
        \\{"message_id":1e19,"user_id":10001,"time":100,"message":[]}
    , .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?Message, null), try parseMessage(a, parsed.value));
}

test "at 段一律渲染成带 QQ 号的占位，NapCat 附带的群展示名进不了正文" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    // 三种上报形态（带 name、无 name、name 为空串）渲染出来完全一样：存储
    // 文本只认 QQ 号。`name` 在这里出现多少次都不影响结果，这正是"群名片
    // 绝不落库"要钉住的东西。
    const m1 = try parseOne(a,
        \\{"message_id":1,"user_id":2,"time":0,"message":[
        \\ {"type":"at","data":{"qq":"999","name":"小明"}},
        \\ {"type":"text","data":{"text":" 你好"}}]}
    );
    try std.testing.expectEqualStrings("\x01999\x02 你好", try m1.renderText(a));

    const m2 = try parseOne(a,
        \\{"message_id":1,"user_id":2,"time":0,"message":[
        \\ {"type":"at","data":{"qq":"999"}},{"type":"text","data":{"text":" hi"}}]}
    );
    try std.testing.expectEqualStrings("\x01999\x02 hi", try m2.renderText(a));

    const m3 = try parseOne(a,
        \\{"message_id":1,"user_id":2,"time":0,"message":[
        \\ {"type":"at","data":{"qq":"999","name":""}},{"type":"text","data":{"text":" hi"}}]}
    );
    try std.testing.expectEqualStrings("\x01999\x02 hi", try m3.renderText(a));

    // 展开之后才是给人看的样子：查得到用昵称，查不到退回 @QQ号。
    const shown = try atname.expand(a, try m1.renderText(a), &.{999}, &.{"Sylphy"});
    try std.testing.expectEqualStrings("@Sylphy 你好", shown);
    const unknown = try atname.expand(a, try m1.renderText(a), &.{}, &.{});
    try std.testing.expectEqualStrings("@999 你好", unknown);
}

test "at 的 qq 不是数字（@全体成员）时没有 QQ 号可查，保留 @{qq} 字面写法" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const m = try parseOne(a,
        \\{"message_id":1,"user_id":2,"time":0,"message":[
        \\ {"type":"at","data":{"qq":"all","name":"全体成员"}},
        \\ {"type":"text","data":{"text":" 集合"}}]}
    );
    const rendered = try m.renderText(a);
    try std.testing.expectEqualStrings("@all 集合", rendered);
    try std.testing.expect(!atname.has(rendered));
}

test "文本段里原样带着的占位控制字节被丢弃，无法伪造成别人的 at" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const segments = [_]Segment{.{ .text = "\x011393309348\x02 是我说的" }};
    const m = Message{ .message_id = 1, .user_id = 2, .time = 0, .segments = &segments };
    const rendered = try m.renderText(a);
    try std.testing.expectEqualStrings("1393309348 是我说的", rendered);
    try std.testing.expect(!atname.has(rendered));
}

test "image / face 等非文本段不产生占位符，但保留 OCR 所需的图片定位字段" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const m = try parseOne(a,
        \\{"message_id":1,"user_id":2,"time":0,"message":[
        \\ {"type":"image","data":{"file":"x.png","url":"https://example.test/x.png"}},
        \\ {"type":"text","data":{"text":"abc"}},
        \\ {"type":"face","data":{"id":"1"}}]}
    );
    try std.testing.expectEqualStrings("abc", try m.renderText(a));
    try std.testing.expect(m.hasImage());
    try std.testing.expectEqualStrings("x.png", m.segments[0].image.file.?);
    try std.testing.expectEqualStrings("https://example.test/x.png", m.segments[0].image.url.?);
    try std.testing.expect(!m.segments[0].image.market_face);
}

test "个人表情兼容 image 和原生 mface，上报缺 URL 时按 NapCat 规则补图源" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const m = try parseOne(a,
        \\{"message_id":1,"user_id":2,"time":0,"message":[
        \\ {"type":"image","data":{"file":"marketface","emoji_id":"abcdef"}},
        \\ {"type":"mface","data":{"emoji_id":"123456","emoji_package_id":"9","summary":"贴图"}}]}
    );
    try std.testing.expect(m.hasImage());
    try std.testing.expect(m.segments[0].image.market_face);
    try std.testing.expectEqualStrings(
        "https://gxh.vip.qq.com/club/item/parcel/item/ab/abcdef/raw300.gif",
        m.segments[0].image.url.?,
    );
    try std.testing.expect(m.segments[1].image.market_face);
    try std.testing.expectEqualStrings(
        "https://gxh.vip.qq.com/club/item/parcel/item/12/123456/raw300.gif",
        m.segments[1].image.url.?,
    );
}

test "纯图片消息渲染为空串" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const m = try parseOne(a,
        \\{"message_id":1,"user_id":2,"time":0,
        \\ "message":[{"type":"image","data":{"file":"x.png"}}]}
    );
    try std.testing.expectEqualStrings("", try m.renderText(a));
    try std.testing.expect(m.hasImage());
}

test "没有 file/url 的 image 段不算可 OCR 图片" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const m = try parseOne(a,
        \\{"message_id":1,"user_id":2,"time":0,
        \\ "message":[{"type":"image","data":{"file":"","url":""}}]}
    );
    try std.testing.expect(!m.hasImage());
}

test "replyTarget 取 reply 段的 id" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const m = try parseOne(a,
        \\{"message_id":1,"user_id":2,"time":0,"message":[
        \\ {"type":"reply","data":{"id":"555"}},
        \\ {"type":"text","data":{"text":"✨"}}]}
    );
    try std.testing.expectEqual(@as(?i64, 555), m.replyTarget());
    try std.testing.expectEqualStrings("✨", m.soleTextBesidesReply().?);
}

test "soleTextBesidesReply：多个文本段或夹带其他段一律返回 null" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const two_text = try parseOne(a,
        \\{"message_id":1,"user_id":2,"time":0,"message":[
        \\ {"type":"reply","data":{"id":"5"}},
        \\ {"type":"text","data":{"text":"✨"}},
        \\ {"type":"text","data":{"text":"x"}}]}
    );
    try std.testing.expectEqual(@as(?[]const u8, null), two_text.soleTextBesidesReply());

    const with_image = try parseOne(a,
        \\{"message_id":1,"user_id":2,"time":0,"message":[
        \\ {"type":"reply","data":{"id":"5"}},
        \\ {"type":"text","data":{"text":"✨"}},
        \\ {"type":"image","data":{"file":"x"}}]}
    );
    try std.testing.expectEqual(@as(?[]const u8, null), with_image.soleTextBesidesReply());

    const with_at = try parseOne(a,
        \\{"message_id":1,"user_id":2,"time":0,"message":[
        \\ {"type":"reply","data":{"id":"5"}},
        \\ {"type":"at","data":{"qq":"9"}}]}
    );
    try std.testing.expectEqual(@as(?[]const u8, null), with_at.soleTextBesidesReply());
}

test "无 reply 段时 replyTarget 为 null" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const m = try parseOne(a,
        \\{"message_id":1,"user_id":2,"time":0,
        \\ "message":[{"type":"text","data":{"text":"x"}}]}
    );
    try std.testing.expectEqual(@as(?i64, null), m.replyTarget());
}

test "parseMessages 解析数组" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const parsed = try std.json.parseFromSlice(std.json.Value, a,
        \\[{"message_id":1,"user_id":2,"time":10,"message":[]},
        \\ {"message_id":2,"user_id":3,"time":20,"message":[]}]
    , .{});
    const list = try parseMessages(a, parsed.value);
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqual(@as(i64, 2), list[1].message_id);
}
