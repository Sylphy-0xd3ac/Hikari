const std = @import("std");
const config = @import("config.zig");
const napcat = @import("napcat.zig");
const redis = @import("redis/client.zig");
const store = @import("store.zig");
const http_server = @import("http/server.zig");
const runner = @import("scan/runner.zig");
const scheduler = @import("scheduler.zig");
const import = @import("import.zig");

pub fn main() !void {
    var dbg: std.heap.DebugAllocator(.{}) = .init;
    defer _ = dbg.deinit();
    const gpa = dbg.allocator();

    // 子命令分发：无参数（args.len == 1，只有程序名）时完全落到下面原有的
    // "起daemon" 路径，行为跟加子命令之前逐字节一致——这个 if 块只在
    // 用户显式传了第一个参数时才会截住执行流。
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    if (args.len > 1) {
        if (std.mem.eql(u8, args[1], "import")) {
            if (args.len != 3) {
                std.log.err("usage: hikari import <file>", .{});
                std.process.exit(1);
            }
            return runImportCommand(gpa, args[2]);
        }
        std.log.err("unknown subcommand: {s} (usage: hikari [import <file>])", .{args[1]});
        std.process.exit(1);
    }

    var bad: ?[]const u8 = null;
    var cfg = config.load(gpa, &bad) catch |e| {
        std.log.err("config error ({s}) at env var: {s}", .{ @errorName(e), bad orelse "?" });
        std.process.exit(1);
    };
    defer cfg.deinit();

    // HTTP 服务与扫描器各持一条 Redis 连接：redis.Client 内部的 reader/writer
    // 持有指向自身的指针，一旦被移动/复制就会失效，两个使用方绝不能共享同一条连接。
    var http_redis = try redis.Client.connect(gpa, cfg.redis_host, cfg.redis_port, cfg.redis_password, cfg.redis_db);
    defer http_redis.deinit();
    var http_store = store.Store.init(gpa, &http_redis);

    var scan_redis = try redis.Client.connect(gpa, cfg.redis_host, cfg.redis_port, cfg.redis_password, cfg.redis_db);
    defer scan_redis.deinit();
    var scan_store = store.Store.init(gpa, &scan_redis);

    var nap = napcat.Client.init(gpa, cfg.napcat_url, cfg.napcat_token);
    defer nap.deinit();

    var srv = try http_server.Server.listen(gpa, &http_store, cfg.http_host, cfg.http_port);
    defer srv.deinit();
    std.log.info("hitokoto api listening on {s}:{d}", .{ cfg.http_host, srv.port() });

    const http_thread = try std.Thread.spawn(.{}, http_server.Server.runForever, .{&srv});
    http_thread.detach();

    const deps: runner.Deps = .{
        .gpa = gpa,
        .nap = &nap,
        .st = &scan_store,
        .observed_qq = cfg.observed_qq,
        .admin_qqs = cfg.admin_qqs,
        .group_ids = cfg.group_ids,
    };

    // 重启补跑：`hikari:lastrun:{group_id}` 是逐群独立的键，所以这里逐群判断
    // "今天该跑的时刻已过且这个群上次运行早于它"，而不是只读一个全局键。这里
    // 的 off 只用于这一次判断，跟下面循环里每轮重新计算的 off 是两回事，
    // 互不影响。
    {
        const now = std.time.timestamp();
        const off = scheduler.localOffsetSeconds(now);
        var earliest_missed: ?i64 = null;
        for (cfg.group_ids) |gid| {
            // `catch null` 的后果是"当作这个群从来没跑过"。注意方向：missedRun
            // 只在 last 早于今天该跑的时刻时才返回补跑时间，所以 null 会让这个
            // 群的补跑判断**退化成首次启动那条路**——真的漏跑了也不会被补上，
            // 而不是反过来多触发一次扫描。多跑一次是无害的（exists/isTombstoned
            // 挡重复），漏跑不是；这里保持宽松是因为 Redis 刚起来读不到某个群
            // 的 lastrun 时不该直接崩掉整个进程，代价记在这里。
            const last = scan_store.getLastRun(gid) catch null;
            if (scheduler.missedRun(now, last, cfg.scan_hour, cfg.scan_minute, off)) |missed| {
                // 各群漏跑的时刻可能不一样（比如上一轮里一个群成功、一个群
                // 失败，且它们各自最近一次成功的时间点本来就不同）；取最早的
                // 那个当 run_at：它离"覆盖到位"最远。runOnce 会用这一个 run_at
                // 重新扫全部群——已经追上这个时刻的群只是把已经处理过的窗口
                // 幂等地重扫一遍（exists/isTombstoned 挡重复入库），无害，
                // 所以这里不需要、也不做逐群跳过。
                if (earliest_missed == null or missed < earliest_missed.?) {
                    earliest_missed = missed;
                }
            }
        }
        if (earliest_missed) |missed| {
            std.log.info("catching up on missed run at {d}", .{missed});
            runner.runOnce(deps, missed);
        }
    }

    // 每轮都重新取 now 和 off，而不是在循环外算一次复用：本地时区相对 UTC
    // 的偏移会因为夏令时切换而改变，进程一次起来跑几个月是常态，缓存一份
    // 旧偏移会导致跨越 DST 边界之后触发时刻整体偏移一小时。
    while (true) {
        const now = std.time.timestamp();
        const off = scheduler.localOffsetSeconds(now);
        const next = scheduler.nextRunAt(now, cfg.scan_hour, cfg.scan_minute, off);
        const wait_s = next - now;
        std.log.info("next scan in {d}s", .{wait_s});
        if (wait_s > 0) std.Thread.sleep(@as(u64, @intCast(wait_s)) * std.time.ns_per_s);
        runner.runOnce(deps, next);
    }
}

/// `hikari import <file>`：装配一条独立的 Redis 连接 + NapCat 客户端（不跟
/// 常驻路径共享，理由跟 main() 里 http_redis/scan_redis 分开是同一个——
/// redis.Client 一旦被移动/复制就会失效，这条命令本来就是独立进程运行到
/// 结束就退出，没有必要也不该尝试复用常驻路径的连接管理）。
fn runImportCommand(gpa: std.mem.Allocator, path: []const u8) !void {
    var bad: ?[]const u8 = null;
    var cfg = config.load(gpa, &bad) catch |e| {
        std.log.err("config error ({s}) at env var: {s}", .{ @errorName(e), bad orelse "?" });
        std.process.exit(1);
    };
    defer cfg.deinit();

    var imp_redis = try redis.Client.connect(gpa, cfg.redis_host, cfg.redis_port, cfg.redis_password, cfg.redis_db);
    defer imp_redis.deinit();
    var imp_store = store.Store.init(gpa, &imp_redis);

    var nap = napcat.Client.init(gpa, cfg.napcat_url, cfg.napcat_token);
    defer nap.deinit();

    const deps: runner.Deps = .{
        .gpa = gpa,
        .nap = &nap,
        .st = &imp_store,
        .observed_qq = cfg.observed_qq,
        .admin_qqs = cfg.admin_qqs,
        .group_ids = cfg.group_ids,
    };

    const summary = import.run(deps, path, std.time.timestamp()) catch |e| {
        std.log.err("import failed: {s}", .{@errorName(e)});
        std.process.exit(1);
    };

    const text = try import.formatSummary(gpa, summary);
    defer gpa.free(text);
    try std.fs.File.stdout().writeAll(text);

    if (summary.write_failed > 0) std.process.exit(1);
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
    _ = @import("napcat.zig");
    _ = @import("scheduler.zig");
    _ = @import("scan/runner.zig");
    _ = @import("import.zig");
}
