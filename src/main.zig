const std = @import("std");

pub fn main() !void {
    std.debug.print("hikari\n", .{});
}

test {
    _ = @import("config.zig");
    _ = @import("onebot.zig");
    _ = @import("scan/rules.zig");
    _ = @import("redis/resp.zig");
    _ = @import("redis/client.zig");
    _ = @import("uuid.zig");
    _ = @import("store.zig");
    _ = @import("http/hitokoto.zig");
    _ = @import("http/server.zig");
}
