const std = @import("std");

pub const Error = error{ ProtocolError, OutOfMemory, ReadFailed, EndOfStream, StreamTooLong };

pub const Value = union(enum) {
    simple: []u8,
    err: []u8,
    int: i64,
    bulk: ?[]u8,
    array: ?[]Value,

    pub fn deinit(self: Value, gpa: std.mem.Allocator) void {
        switch (self) {
            .simple => |s| gpa.free(s),
            .err => |s| gpa.free(s),
            .int => {},
            .bulk => |b| if (b) |s| gpa.free(s),
            .array => |a| if (a) |items| {
                for (items) |item| item.deinit(gpa);
                gpa.free(items);
            },
        }
    }
};

pub fn encodeCommand(gpa: std.mem.Allocator, args: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var w = out.writer(gpa);
    try w.print("*{d}\r\n", .{args.len});
    for (args) |a| try w.print("${d}\r\n{s}\r\n", .{ a.len, a });
    return out.toOwnedSlice(gpa);
}

/// 读一行并去掉尾部 CRLF。返回的切片指向 reader 内部缓冲，
/// 下一次读操作即失效，必须立刻复制。
fn readLine(r: *std.Io.Reader) Error![]const u8 {
    const raw = r.takeDelimiterInclusive('\n') catch |e| switch (e) {
        error.EndOfStream => return error.EndOfStream,
        error.StreamTooLong => return error.StreamTooLong,
        error.ReadFailed => return error.ReadFailed,
    };
    return std.mem.trimRight(u8, raw, "\r\n");
}

pub fn readValue(gpa: std.mem.Allocator, r: *std.Io.Reader) Error!Value {
    const line = try readLine(r);
    if (line.len == 0) return error.ProtocolError;
    const tag = line[0];
    const body = line[1..];

    switch (tag) {
        '+' => return .{ .simple = try gpa.dupe(u8, body) },
        '-' => return .{ .err = try gpa.dupe(u8, body) },
        ':' => return .{ .int = std.fmt.parseInt(i64, body, 10) catch return error.ProtocolError },
        '$' => {
            const n = std.fmt.parseInt(i64, body, 10) catch return error.ProtocolError;
            if (n < 0) return .{ .bulk = null };
            const len: usize = @intCast(n);
            const buf = r.readAlloc(gpa, len) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.EndOfStream => return error.EndOfStream,
                error.ReadFailed => return error.ReadFailed,
            };
            errdefer gpa.free(buf);
            r.discardAll(2) catch |e| switch (e) { // 尾部 CRLF
                error.EndOfStream => return error.EndOfStream,
                error.ReadFailed => return error.ReadFailed,
            };
            return .{ .bulk = buf };
        },
        '*' => {
            const n = std.fmt.parseInt(i64, body, 10) catch return error.ProtocolError;
            if (n < 0) return .{ .array = null };
            const len: usize = @intCast(n);
            const items = try gpa.alloc(Value, len);
            var filled: usize = 0;
            errdefer {
                for (items[0..filled]) |item| item.deinit(gpa);
                gpa.free(items);
            }
            while (filled < len) : (filled += 1) {
                items[filled] = try readValue(gpa, r);
            }
            return .{ .array = items };
        },
        else => return error.ProtocolError,
    }
}

test "encodeCommand 编码为 RESP 数组" {
    const gpa = std.testing.allocator;
    const out = try encodeCommand(gpa, &.{ "SET", "k", "v" });
    defer gpa.free(out);
    try std.testing.expectEqualStrings("*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$1\r\nv\r\n", out);
}

test "encodeCommand 处理空参数与含 CRLF 的值" {
    const gpa = std.testing.allocator;
    const out = try encodeCommand(gpa, &.{ "SET", "k", "a\r\nb" });
    defer gpa.free(out);
    try std.testing.expectEqualStrings("*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$4\r\na\r\nb\r\n", out);
}

test "readValue 读简单字符串" {
    const gpa = std.testing.allocator;
    var r: std.Io.Reader = .fixed("+OK\r\n");
    const v = try readValue(gpa, &r);
    defer v.deinit(gpa);
    try std.testing.expectEqualStrings("OK", v.simple);
}

test "readValue 读错误" {
    const gpa = std.testing.allocator;
    var r: std.Io.Reader = .fixed("-ERR bad command\r\n");
    const v = try readValue(gpa, &r);
    defer v.deinit(gpa);
    try std.testing.expectEqualStrings("ERR bad command", v.err);
}

test "readValue 读整数（含负数）" {
    const gpa = std.testing.allocator;
    var r: std.Io.Reader = .fixed(":42\r\n:-7\r\n");
    const a = try readValue(gpa, &r);
    defer a.deinit(gpa);
    try std.testing.expectEqual(@as(i64, 42), a.int);
    const b = try readValue(gpa, &r);
    defer b.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -7), b.int);
}

test "readValue 读 bulk 字符串与 nil" {
    const gpa = std.testing.allocator;
    var r: std.Io.Reader = .fixed("$5\r\nhello\r\n$-1\r\n$0\r\n\r\n");

    const a = try readValue(gpa, &r);
    defer a.deinit(gpa);
    try std.testing.expectEqualStrings("hello", a.bulk.?);

    const b = try readValue(gpa, &r);
    defer b.deinit(gpa);
    try std.testing.expectEqual(@as(?[]u8, null), b.bulk);

    const c = try readValue(gpa, &r);
    defer c.deinit(gpa);
    try std.testing.expectEqualStrings("", c.bulk.?);
}

test "readValue 读 bulk 里含 CRLF 的二进制安全内容" {
    const gpa = std.testing.allocator;
    var r: std.Io.Reader = .fixed("$4\r\na\r\nb\r\n");
    const v = try readValue(gpa, &r);
    defer v.deinit(gpa);
    try std.testing.expectEqualStrings("a\r\nb", v.bulk.?);
}

test "readValue 读数组与嵌套数组" {
    const gpa = std.testing.allocator;
    var r: std.Io.Reader = .fixed("*2\r\n$1\r\na\r\n*2\r\n:1\r\n$1\r\nb\r\n");
    const v = try readValue(gpa, &r);
    defer v.deinit(gpa);

    const items = v.array.?;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("a", items[0].bulk.?);
    const inner = items[1].array.?;
    try std.testing.expectEqual(@as(i64, 1), inner[0].int);
    try std.testing.expectEqualStrings("b", inner[1].bulk.?);
}

test "readValue 读空数组与 nil 数组" {
    const gpa = std.testing.allocator;
    var r: std.Io.Reader = .fixed("*0\r\n*-1\r\n");
    const a = try readValue(gpa, &r);
    defer a.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), a.array.?.len);
    const b = try readValue(gpa, &r);
    defer b.deinit(gpa);
    try std.testing.expectEqual(@as(?[]Value, null), b.array);
}

test "readValue 遇到未知类型前缀报错" {
    const gpa = std.testing.allocator;
    var r: std.Io.Reader = .fixed("%1\r\n");
    try std.testing.expectError(error.ProtocolError, readValue(gpa, &r));
}

/// checkAllAllocationFailures 用的辅助函数：每次调用都在给定字节上
/// 新建一个独立的 fixed reader，避免跨调用复用已消费的流。
fn checkReadValueAlloc(gpa: std.mem.Allocator, bytes: []const u8) !void {
    var r: std.Io.Reader = .fixed(bytes);
    const v = try readValue(gpa, &r);
    v.deinit(gpa);
}

test "readValue 在分配失败时把 OutOfMemory 原样传出（bulk）" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkReadValueAlloc,
        .{"$5\r\nhello\r\n"},
    );
}

test "readValue 在分配失败时把 OutOfMemory 原样传出（嵌套数组）" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkReadValueAlloc,
        .{"*2\r\n$1\r\na\r\n*2\r\n:1\r\n$1\r\nb\r\n"},
    );
}
