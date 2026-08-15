const std = @import("std");

pub const At = struct { qq: []const u8, name: ?[]const u8 };

pub const Segment = union(enum) {
    text: []const u8,
    at: At,
    reply: i64,
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

    /// text 段原样，at 段渲染为 @昵称（缺昵称用 @QQ号），其余段丢弃，首尾 trim。
    /// 返回新分配的内存，调用方负责 free。
    pub fn renderText(self: Message, gpa: std.mem.Allocator) ![]u8 {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(gpa);
        for (self.segments) |s| switch (s) {
            .text => |t| try list.appendSlice(gpa, t),
            .at => |a| {
                try list.append(gpa, '@');
                try list.appendSlice(gpa, a.name orelse a.qq);
            },
            else => {},
        };
        return gpa.dupe(u8, std.mem.trim(u8, list.items, ws));
    }
};

/// NapCat 的数字字段有时是 number 有时是 string，两种都接受。
pub fn asInt(v: std.json.Value) ?i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
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
                    const name = if (d.get("name")) |nv| asStr(nv) else null;
                    try segs.append(arena, .{ .at = .{ .qq = qq, .name = name } });
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

test "at 段带 name 渲染为 @昵称，缺 name 退化为 @QQ号" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const m1 = try parseOne(a,
        \\{"message_id":1,"user_id":2,"time":0,"message":[
        \\ {"type":"at","data":{"qq":"999","name":"小明"}},
        \\ {"type":"text","data":{"text":" 你好"}}]}
    );
    try std.testing.expectEqualStrings("@小明 你好", try m1.renderText(a));

    const m2 = try parseOne(a,
        \\{"message_id":1,"user_id":2,"time":0,"message":[
        \\ {"type":"at","data":{"qq":"999"}},{"type":"text","data":{"text":" hi"}}]}
    );
    try std.testing.expectEqualStrings("@999 hi", try m2.renderText(a));
}

test "image / face 等其他段被丢弃，不产生占位符" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const m = try parseOne(a,
        \\{"message_id":1,"user_id":2,"time":0,"message":[
        \\ {"type":"image","data":{"file":"x.png"}},
        \\ {"type":"text","data":{"text":"abc"}},
        \\ {"type":"face","data":{"id":"1"}}]}
    );
    try std.testing.expectEqualStrings("abc", try m.renderText(a));
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
