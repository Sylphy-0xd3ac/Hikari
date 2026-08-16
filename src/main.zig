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
        if (std.mem.eql(u8, args[1], "run")) {
            if (args.len != 2) {
                std.log.err("usage: hikari run", .{});
                std.process.exit(1);
            }
            return runRunCommand(gpa);
        }
        if (std.mem.eql(u8, args[1], "reindex")) {
            if (args.len != 2) {
                std.log.err("usage: hikari reindex", .{});
                std.process.exit(1);
            }
            return runReindexCommand(gpa);
        }
        std.log.err("unknown subcommand: {s} (usage: hikari [import <file>|run|reindex])", .{args[1]});
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
        .observed_qqs = cfg.observed_qqs,
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
                // scheduler.missedRun 的非 null 返回值只由 now/hour/minute/offset
                // 算出，跟传进去的 last_run 完全无关——同一次调用里所有非 null 的
                // missed 眼下必然彼此相等，只有"漏没漏跑"（null 还是非 null）
                // 逐群不同。取最小值目前只是在给一堆相等的数取 min，不是因为它们
                // 会不一样；这里留着 min 选择是防御性的、面向将来的写法——万一
                // missedRun 以后改成也参考 last_run（比如允许每群独立判定该补哪
                // 一天），各群的 missed 就可能真的分叉，到时候不用改这段代码。
                // runOnce 会用选中的 run_at 重新扫全部群——已经追上这个时刻的群
                // 现在会拿到一个空窗口（scheduler.windowStart 的 last_run >= run_at
                // 分支），不会再做任何多余的重扫，也无需在这里逐群跳过。
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
        .observed_qqs = cfg.observed_qqs,
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

/// `hikari run`：跑一次扫描立刻退出，不起 HTTP 服务。装配跟常驻路径
/// （main() 里那条）逐字段相同——同一个 config.load、同一种独立 Redis
/// 连接、同一个 runner.Deps 构造方式——因为这必须是一次真实的运行：窗口
/// 起点仍然是 `hikari:lastrun:{group_id}`，跑完仍然逐群写回它，跟定时
/// 路径没有任何区别。这正是这个子命令存在的意义：运营方过去想手动验证一次
/// 扫描，得靠"临时改 SCAN_TIME、重启、等、再改回去"这套仪式；`runOnce`
/// 从来就不关心调用者是谁，唯一缺的只是一个不需要仪式的入口。
///
/// `run_at = std.time.timestamp()`：窗口因此是 `[last_run, now)`——上次
/// 成功运行之后错过的整段，跟调度路径完全同一条计算逻辑（含 7 天回看
/// 上限），不是"固定回看 24 小时"那种阉割版本。
///
/// 退出码：只有 config 加载失败或 Redis 连不上才是非零——这两步失败意味着
/// 这次调用压根没跑起来，运营方需要能从退出码看出"根本没跑"和"跑了但
/// 某些群失败了"的区别。后者 `runOnce` 按设计吞掉每个群自己的错误（见
/// `scan/runner.zig`），这里不改这个既有行为：单个群失败不该让整条命令
/// 退出码变成非零，否则 cron/CI 里跑这条命令会在"完全正常的部分失败"
/// 场景下持续报警。
fn runRunCommand(gpa: std.mem.Allocator) !void {
    var bad: ?[]const u8 = null;
    var cfg = config.load(gpa, &bad) catch |e| {
        std.log.err("config error ({s}) at env var: {s}", .{ @errorName(e), bad orelse "?" });
        std.process.exit(1);
    };
    defer cfg.deinit();

    var run_redis = redis.Client.connect(gpa, cfg.redis_host, cfg.redis_port, cfg.redis_password, cfg.redis_db) catch |e| {
        std.log.err("redis connect failed: {s}", .{@errorName(e)});
        std.process.exit(1);
    };
    defer run_redis.deinit();
    var run_store = store.Store.init(gpa, &run_redis);

    var nap = napcat.Client.init(gpa, cfg.napcat_url, cfg.napcat_token);
    defer nap.deinit();

    const deps: runner.Deps = .{
        .gpa = gpa,
        .nap = &nap,
        .st = &run_store,
        .observed_qqs = cfg.observed_qqs,
        .admin_qqs = cfg.admin_qqs,
        .group_ids = cfg.group_ids,
    };

    runner.runOnce(deps, std.time.timestamp());
}

/// `hikari reindex`：把 `hikari:index` 里已有的语录逐条补进作者维度的索引
/// `hikari:byuser:{user_id}`，然后退出。装配方式跟 `import`/`run` 一致——
/// 自己的 config.load、自己的一条 Redis 连接（`redis.Client` 一旦被移动或
/// 复制就会失效，这条命令跑完就退出，没有必要也不该复用常驻路径的连接）。
///
/// 它存在的理由：`hikari:byuser` 是后加的键，上线之前收录的 136 条生产语录
/// 全都不在里面，`/?user_id=` 因此对整个存量语录库失效（这 136 条同属一个
/// 作者，不是"部分作者查不到"）。而"重新收录一遍就好"这条曾经写进文档的建议
/// 行不通：扫描器与 `hikari import` 都在 `Store.exists()` 那道关卡上就返回
/// 了，`add()`/`addChain()` 根本走不到。见 `store.Store.reindexByUser`。
///
/// 它**不改变任何自动行为**：进程启动不跑它，定时扫描不跑它，HTTP 读路径
/// 更不会顺手写一笔。只有运营方显式敲这条命令才会发出任何写命令。
///
/// 退出码：config 加载失败、Redis 连不上、或者回填过程中 Redis 报错，都是
/// 非零——这三种都意味着这次修复没有（完整）做成，运营方需要能从退出码直接
/// 看出来。被跳过的条目不算失败：它们是数据本身的既有缺陷（悬空 id、缺
/// 字段），再跑多少遍也不会变，如实打进摘要里就够了。
fn runReindexCommand(gpa: std.mem.Allocator) !void {
    var bad: ?[]const u8 = null;
    var cfg = config.load(gpa, &bad) catch |e| {
        std.log.err("config error ({s}) at env var: {s}", .{ @errorName(e), bad orelse "?" });
        std.process.exit(1);
    };
    defer cfg.deinit();

    var reindex_redis = redis.Client.connect(gpa, cfg.redis_host, cfg.redis_port, cfg.redis_password, cfg.redis_db) catch |e| {
        std.log.err("redis connect failed: {s}", .{@errorName(e)});
        std.process.exit(1);
    };
    defer reindex_redis.deinit();
    var reindex_store = store.Store.init(gpa, &reindex_redis);

    const summary = reindex_store.reindexByUser() catch |e| {
        std.log.err("reindex failed: {s}", .{@errorName(e)});
        std.process.exit(1);
    };

    const text = try store.formatReindexSummary(gpa, summary);
    defer gpa.free(text);
    try std.fs.File.stdout().writeAll(text);
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
