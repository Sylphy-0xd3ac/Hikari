const std = @import("std");
const config = @import("config.zig");
const napcat = @import("napcat.zig");
const ocr = @import("ocr.zig");
const redis = @import("redis/client.zig");
const store = @import("store.zig");
const http_server = @import("http/server.zig");
const runner = @import("scan/runner.zig");
const scheduler = @import("scheduler.zig");
const import = @import("import.zig");

const ImportCommandArgs = struct {
    path: []const u8,
    user_id: u64,
};

const ImportArgsError = error{InvalidArguments};

const RunCommandArgs = struct {
    /// null = 沿用这个群自己的 lastrun；非 null = 本次强制回看这么多秒。
    lookback_seconds: ?i64 = null,
};

const RunArgsError = error{InvalidArguments};

/// `hikari run --last 24h` 的时长语法。只接受正整数 + m/h/d，且沿用扫描器
/// 既有的 7 天安全回看上限：更长的窗口会超过当前翻页护栏的设计容量，与其
/// 悄悄只扫到一部分，不如在联网前明确拒绝。
fn parseLookbackDuration(raw: []const u8) RunArgsError!i64 {
    if (raw.len < 2) return error.InvalidArguments;

    const multiplier: u64 = switch (raw[raw.len - 1]) {
        'm' => 60,
        'h' => 60 * 60,
        'd' => 24 * 60 * 60,
        else => return error.InvalidArguments,
    };
    const amount = std.fmt.parseInt(u64, raw[0 .. raw.len - 1], 10) catch return error.InvalidArguments;
    if (amount == 0) return error.InvalidArguments;
    const seconds = std.math.mul(u64, amount, multiplier) catch return error.InvalidArguments;
    if (seconds > @as(u64, @intCast(scheduler.max_lookback_seconds))) return error.InvalidArguments;
    return @intCast(seconds);
}

fn parseRunCommandArgs(parts: []const []const u8) RunArgsError!RunCommandArgs {
    if (parts.len == 0) return .{};
    if (parts.len != 2 or !std.mem.eql(u8, parts[0], "--last")) return error.InvalidArguments;
    return .{ .lookback_seconds = try parseLookbackDuration(parts[1]) };
}

/// `--user` 是必填归属，不再从 OBSERVED_QQS 猜。接受 option-first 的规范写法，
/// 同时兼容常见的 file-first 排列；其它数量、未知 flag、0/负数/溢出 QQ 都拒绝。
fn parseImportCommandArgs(parts: []const []const u8) ImportArgsError!ImportCommandArgs {
    if (parts.len != 3) return error.InvalidArguments;

    const path: []const u8, const user_raw: []const u8 = if (std.mem.eql(u8, parts[0], "--user"))
        .{ parts[2], parts[1] }
    else if (std.mem.eql(u8, parts[1], "--user"))
        .{ parts[0], parts[2] }
    else
        return error.InvalidArguments;

    if (path.len == 0 or std.mem.startsWith(u8, path, "--")) return error.InvalidArguments;
    const user_id = std.fmt.parseInt(u64, user_raw, 10) catch return error.InvalidArguments;
    if (user_id == 0) return error.InvalidArguments;
    return .{ .path = path, .user_id = user_id };
}

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
            const import_args = parseImportCommandArgs(args[2..]) catch {
                std.log.err("usage: hikari import --user <qq> <file>", .{});
                std.process.exit(1);
            };
            return runImportCommand(gpa, import_args.path, import_args.user_id);
        }
        if (std.mem.eql(u8, args[1], "run")) {
            const run_args = parseRunCommandArgs(args[2..]) catch {
                std.log.err("usage: hikari run [--last <duration>]  (duration: positive integer with m/h/d suffix, max 7d)", .{});
                std.process.exit(1);
            };
            return runRunCommand(gpa, run_args.lookback_seconds);
        }
        if (std.mem.eql(u8, args[1], "reindex")) {
            if (args.len != 2) {
                std.log.err("usage: hikari reindex", .{});
                std.process.exit(1);
            }
            return runReindexCommand(gpa);
        }
        if (std.mem.eql(u8, args[1], "refresh-names")) {
            if (args.len != 2) {
                std.log.err("usage: hikari refresh-names", .{});
                std.process.exit(1);
            }
            return runRefreshNamesCommand(gpa);
        }
        std.log.err("unknown subcommand: {s} (usage: hikari [import --user <qq> <file>|run [--last <duration>]|reindex|refresh-names])", .{args[1]});
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
    var local_ocr = ocr.Local.init(gpa, cfg.ocr_python_path);

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
        .ocr_engine = local_ocr.engine(),
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

/// `hikari import --user <qq> <file>`：装配一条独立的 Redis 连接 + NapCat
/// 客户端（不跟
/// 常驻路径共享，理由跟 main() 里 http_redis/scan_redis 分开是同一个——
/// redis.Client 一旦被移动/复制就会失效，这条命令本来就是独立进程运行到
/// 结束就退出，没有必要也不该尝试复用常驻路径的连接管理）。
fn runImportCommand(gpa: std.mem.Allocator, path: []const u8, attribution_qq: u64) !void {
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
    var local_ocr = ocr.Local.init(gpa, cfg.ocr_python_path);

    const deps: runner.Deps = .{
        .gpa = gpa,
        .nap = &nap,
        .st = &imp_store,
        .observed_qqs = cfg.observed_qqs,
        .admin_qqs = cfg.admin_qqs,
        .group_ids = cfg.group_ids,
        .ocr_engine = local_ocr.engine(),
    };

    const summary = import.run(deps, path, attribution_qq, std.time.timestamp()) catch |e| {
        std.log.err("import failed: {s}", .{@errorName(e)});
        std.process.exit(1);
    };

    const text = try import.formatSummary(gpa, summary);
    defer gpa.free(text);
    try std.fs.File.stdout().writeAll(text);

    if (summary.write_failed > 0) std.process.exit(1);
}

/// `hikari run` / `hikari run --last <duration>`：跑一次扫描立刻退出，
/// 不起 HTTP 服务。装配跟常驻路径
/// （main() 里那条）逐字段相同——同一个 config.load、同一种独立 Redis
/// 连接、同一个 runner.Deps 构造方式——因为这必须是一次真实的运行：窗口
/// 起点仍然是 `hikari:lastrun:{group_id}`，跑完仍然逐群写回它，跟定时
/// 路径没有任何区别。这正是这个子命令存在的意义：运营方过去想手动验证一次
/// 扫描，得靠"临时改 SCAN_TIME、重启、等、再改回去"这套仪式；`runOnce`
/// 从来就不关心调用者是谁，唯一缺的只是一个不需要仪式的入口。
///
/// 默认窗口是 `[last_run, now)`；显式 `--last 24h` 时，本次不读 last_run，
/// 强制改成 `[now-24h, now)`。两者成功后都照常把这个群的 lastrun 写成 now：
/// `--last` 是一次性的窗口覆盖，不是删除进度，也不会改变之后的定时行为。
///
/// 退出码：只有 config 加载失败或 Redis 连不上才是非零——这两步失败意味着
/// 这次调用压根没跑起来，运营方需要能从退出码看出"根本没跑"和"跑了但
/// 某些群失败了"的区别。后者 `runOnce` 按设计吞掉每个群自己的错误（见
/// `scan/runner.zig`），这里不改这个既有行为：单个群失败不该让整条命令
/// 退出码变成非零，否则 cron/CI 里跑这条命令会在"完全正常的部分失败"
/// 场景下持续报警。
fn runRunCommand(gpa: std.mem.Allocator, lookback_seconds: ?i64) !void {
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
    var local_ocr = ocr.Local.init(gpa, cfg.ocr_python_path);

    const deps: runner.Deps = .{
        .gpa = gpa,
        .nap = &nap,
        .st = &run_store,
        .observed_qqs = cfg.observed_qqs,
        .admin_qqs = cfg.admin_qqs,
        .group_ids = cfg.group_ids,
        .ocr_engine = local_ocr.engine(),
    };

    runner.runOnceWithOptions(deps, std.time.timestamp(), .{ .lookback_seconds = lookback_seconds });
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

/// `hikari refresh-names`：把每条语录引用到的 QQ（作者与收录者）的
/// `hikari:username:{uid}` 用当前的 QQ 原始昵称重写一遍，然后退出。装配方式跟
/// `import`/`run`/`reindex` 一致——自己的 config.load、自己的一条 Redis 连接、
/// 同一种 `runner.Deps` 构造方式，因为它要问的正是扫描器在问的那个
/// `get_group_member_info`。
///
/// 它存在的理由：这些键最初由一段**采用群名片**的代码写下（`card` 优先），
/// 写入端后来改成只认 `nickname`，但存量的错值不会自愈——只有那个人再次出现
/// 在某次扫描窗口里才会被重写。而 `creator` 与正文里的 at 改成渲染时解析之后
/// （见 `store.Store.resolveDisplayNames`），这些键的值直接就是对外显示的
/// 名字：不先洗一遍，那个修复只是把"冻结的群名片"换成"当前存着的群名片"。
/// 见 `scan/runner.zig` 的 `refreshNames`。
///
/// 它**不改变任何自动行为**，也不改动任何一条语录：只写 `hikari:username`
/// 这一类键。跑第二遍会把全部命中算进 unchanged，一条写命令都不发。
///
/// 退出码：config 加载失败、Redis 连不上、或者过程中 Redis 报错都是非零。
/// 问不到昵称的那些人不算失败——他们已经离开了全部被观察的群，NapCat 回答不
/// 了，再跑多少遍也一样，如实记进摘要的 unresolved 就够了。
fn runRefreshNamesCommand(gpa: std.mem.Allocator) !void {
    var bad: ?[]const u8 = null;
    var cfg = config.load(gpa, &bad) catch |e| {
        std.log.err("config error ({s}) at env var: {s}", .{ @errorName(e), bad orelse "?" });
        std.process.exit(1);
    };
    defer cfg.deinit();

    var refresh_redis = redis.Client.connect(gpa, cfg.redis_host, cfg.redis_port, cfg.redis_password, cfg.redis_db) catch |e| {
        std.log.err("redis connect failed: {s}", .{@errorName(e)});
        std.process.exit(1);
    };
    defer refresh_redis.deinit();
    var refresh_store = store.Store.init(gpa, &refresh_redis);

    var nap = napcat.Client.init(gpa, cfg.napcat_url, cfg.napcat_token);
    defer nap.deinit();

    // OCR 引擎这条命令用不上（它不看图，也不产生候选），但 Deps 要求一个；
    // 传 local ocr 跟另外几条命令保持同一种装配，且因为从不调用它，
    // OCR_PYTHON_PATH 配得对不对不影响这条命令能不能跑。
    var local_ocr = ocr.Local.init(gpa, cfg.ocr_python_path);

    const deps: runner.Deps = .{
        .gpa = gpa,
        .nap = &nap,
        .st = &refresh_store,
        .observed_qqs = cfg.observed_qqs,
        .admin_qqs = cfg.admin_qqs,
        .group_ids = cfg.group_ids,
        .ocr_engine = local_ocr.engine(),
    };

    const summary = runner.refreshNames(deps) catch |e| {
        std.log.err("refresh-names failed: {s}", .{@errorName(e)});
        std.process.exit(1);
    };

    const text = try runner.formatRefreshNamesSummary(gpa, summary);
    defer gpa.free(text);
    try std.fs.File.stdout().writeAll(text);
}

test "import CLI：--user 必填，option-first 与 file-first 都解析到同一结果" {
    const a = try parseImportCommandArgs(&.{ "--user", "123456", "seed.txt" });
    try std.testing.expectEqualStrings("seed.txt", a.path);
    try std.testing.expectEqual(@as(u64, 123456), a.user_id);

    const b = try parseImportCommandArgs(&.{ "seed.txt", "--user", "123456" });
    try std.testing.expectEqualStrings("seed.txt", b.path);
    try std.testing.expectEqual(@as(u64, 123456), b.user_id);
}

test "import CLI：缺 --user、坏 QQ、额外参数与未知 flag 都拒绝" {
    inline for ([_][]const []const u8{
        &.{"seed.txt"},
        &.{ "--user", "0", "seed.txt" },
        &.{ "--user", "-1", "seed.txt" },
        &.{ "--user", "abc", "seed.txt" },
        &.{ "--user", "18446744073709551616", "seed.txt" },
        &.{ "--author", "123", "seed.txt" },
        &.{ "--user", "123", "seed.txt", "extra" },
    }) |parts| {
        try std.testing.expectError(error.InvalidArguments, parseImportCommandArgs(parts));
    }
}

test "run CLI：默认沿用 lastrun，--last 接受 m h d 并换算成秒" {
    const normal = try parseRunCommandArgs(&.{});
    try std.testing.expectEqual(@as(?i64, null), normal.lookback_seconds);

    const one_hour = try parseRunCommandArgs(&.{ "--last", "1h" });
    try std.testing.expectEqual(@as(?i64, 3600), one_hour.lookback_seconds);
    const ninety_minutes = try parseRunCommandArgs(&.{ "--last", "90m" });
    try std.testing.expectEqual(@as(?i64, 5400), ninety_minutes.lookback_seconds);
    const seven_days = try parseRunCommandArgs(&.{ "--last", "7d" });
    try std.testing.expectEqual(@as(?i64, scheduler.max_lookback_seconds), seven_days.lookback_seconds);
}

test "run CLI：--last 拒绝零、负数、小数、无单位、超 7 天及多余参数" {
    inline for ([_][]const []const u8{
        &.{"--last"},
        &.{ "--last", "0h" },
        &.{ "--last", "-1h" },
        &.{ "--last", "1.5h" },
        &.{ "--last", "24" },
        &.{ "--last", "169h" },
        &.{ "--last", "18446744073709551615d" },
        &.{ "--last", "1h", "extra" },
        &.{ "--since", "1h" },
    }) |parts| {
        try std.testing.expectError(error.InvalidArguments, parseRunCommandArgs(parts));
    }
}

test {
    _ = @import("config.zig");
    _ = @import("onebot.zig");
    _ = @import("atname.zig");
    _ = @import("ocr.zig");
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
