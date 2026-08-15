const std = @import("std");

/// 生成 RFC 4122 v4 UUID 的规范字符串形式（小写，带连字符）。
pub fn v4() [36]u8 {
    var b: [16]u8 = undefined;
    std.crypto.random.bytes(&b);
    b[6] = (b[6] & 0x0f) | 0x40; // version 4
    b[8] = (b[8] & 0x3f) | 0x80; // variant 10

    const hex = "0123456789abcdef";
    var out: [36]u8 = undefined;
    var oi: usize = 0;
    for (b, 0..) |byte, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[oi] = '-';
            oi += 1;
        }
        out[oi] = hex[byte >> 4];
        out[oi + 1] = hex[byte & 0x0f];
        oi += 2;
    }
    return out;
}

test "v4 形状正确" {
    const u = v4();
    try std.testing.expectEqual(@as(usize, 36), u.len);
    try std.testing.expectEqual(@as(u8, '-'), u[8]);
    try std.testing.expectEqual(@as(u8, '-'), u[13]);
    try std.testing.expectEqual(@as(u8, '-'), u[18]);
    try std.testing.expectEqual(@as(u8, '-'), u[23]);
    try std.testing.expectEqual(@as(u8, '4'), u[14]);
    try std.testing.expect(u[19] == '8' or u[19] == '9' or u[19] == 'a' or u[19] == 'b');
    for (u, 0..) |ch, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) continue;
        try std.testing.expect(std.ascii.isHex(ch));
        try std.testing.expect(!std.ascii.isUpper(ch));
    }
}

test "v4 两次生成不相同" {
    try std.testing.expect(!std.mem.eql(u8, &v4(), &v4()));
}
