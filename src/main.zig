const std = @import("std");

pub fn main() !void {
    std.debug.print("hikari\n", .{});
}

test {
    _ = @import("config.zig");
    _ = @import("onebot.zig");
}
