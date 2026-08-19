const std = @import("std");

const c = @cImport({
    @cInclude("time.h");
});

pub const seconds_per_day: i64 = 86400;

/// 本地时区相对 UTC 的偏移（秒，东为正），含夏令时。
/// Zig std 没有时区数据库，只能走 libc。
pub fn localOffsetSeconds(now: i64) i64 {
    const t: c.time_t = @intCast(now);
    var tm: c.struct_tm = undefined;
    if (c.localtime_r(&t, &tm) == null) return 0;
    return @intCast(tm.tm_gmtoff);
}

/// 给定当前 Unix 秒与本地时区偏移，返回下一次 HH:MM 触发的 Unix 秒。
/// 若当前恰好等于今天的触发时刻，顺延到明天（避免同一时刻重复触发）。
pub fn nextRunAt(now: i64, hour: u8, minute: u8, offset: i64) i64 {
    const local = now + offset;
    const local_midnight = @divFloor(local, seconds_per_day) * seconds_per_day;
    const target_local = local_midnight + @as(i64, hour) * 3600 + @as(i64, minute) * 60;
    const target = if (target_local > local) target_local else target_local + seconds_per_day;
    return target - offset;
}

/// windowStart 的返回值：起点本身，加上"是否被 7 天回看上限截断过"。
/// `clamped` 让调用方（runner.runOnce）能在截断发生时打一条警告——截断
/// 意味着 [run_at - max_lookback_seconds, last_run) 这一段被放弃，
/// 其中的 💦 撤稿指令永久不可恢复（它们只会被看到一次）。
pub const Window = struct { start: i64, clamped: bool };

/// 回看上限：停机超过这个时长，更早的那段放弃并警告。
/// 7 天 ≈ 35 页（200 条/页），远在 runner 的 200 次迭代护栏内。
pub const max_lookback_seconds: i64 = 7 * 86400;

/// 扫描窗口起点，逐群独立：按这个群自己的 `last_run`（`hikari:lastrun:{group_id}`）
/// 算，而不是固定回看 24 小时——固定 24h 的话，停机超过一天的那段永远不会被
/// 任何一次扫描覆盖到，丢的不只是语录（明天的窗口还能兜住新贴的 ✨），
/// 还有 💦 撤稿指令（只会被看到一次，漏了就永久漏了）。
///
/// - `last_run == null`（这个群从未跑过）→ 退化成原来的固定 24h 窗口。
/// - `last_run >= run_at`（这个群这一时刻已经跟上了，比如同一轮 runOnce 里
///   补跑逻辑用最早的漏跑时刻重扫了全部群，其中有的群本来就没漏）→ 空窗口
///   `[run_at, run_at)`。`inWindow` 对 `start == end` 已经返回 false（有
///   专门的测试钉住），这里不需要、也不应该再加一层特判。
/// - 停机跨度超过 `max_lookback_seconds` → 截断到上限，`clamped = true`。
/// - 否则 → `[last_run, run_at)`，把 last_run 之后错过的整段都补上。
pub fn windowStart(run_at: i64, last_run: ?i64) Window {
    const last = last_run orelse return .{ .start = run_at - seconds_per_day, .clamped = false };
    if (last >= run_at) return .{ .start = run_at, .clamped = false };
    if (run_at - last > max_lookback_seconds) {
        return .{ .start = run_at - max_lookback_seconds, .clamped = true };
    }
    return .{ .start = last, .clamped = false };
}

/// 进程重启后判断今天的那次是否漏跑。漏了返回今天的触发时刻，否则 null。
pub fn missedRun(now: i64, last_run: ?i64, hour: u8, minute: u8, offset: i64) ?i64 {
    const last = last_run orelse return null;
    const local = now + offset;
    const local_midnight = @divFloor(local, seconds_per_day) * seconds_per_day;
    const today_local = local_midnight + @as(i64, hour) * 3600 + @as(i64, minute) * 60;
    const today = today_local - offset;
    if (now < today) return null; // 今天这次还没到
    if (last >= today) return null; // 今天已经跑过
    return today;
}

const day = 86400;
const cst = 8 * 3600; // UTC+8

/// 2026-08-15T00:00:00 UTC 的 Unix 秒
const base_utc: i64 = 1786838400;

test "nextRunAt 取今天尚未到达的时刻" {
    // 本地 UTC+8。base_utc 对应本地 08:00。目标 10:30 还没到 → 今天。
    const now = base_utc;
    const got = nextRunAt(now, 10, 30, cst);
    try std.testing.expectEqual(base_utc + 2 * 3600 + 30 * 60, got);
}

test "nextRunAt 时刻已过则顺延到明天" {
    // base_utc 本地是 08:00，目标 03:00 已过 → 明天 03:00 本地 = base_utc - 5h + 24h
    const got = nextRunAt(base_utc, 3, 0, cst);
    try std.testing.expectEqual(base_utc - 5 * 3600 + day, got);
}

test "nextRunAt 正好等于当前时刻则顺延到明天" {
    // base_utc 本地 08:00，目标 08:00 → 不重复触发，顺延
    const got = nextRunAt(base_utc, 8, 0, cst);
    try std.testing.expectEqual(base_utc + day, got);
}

test "nextRunAt 在 UTC 时区下也正确" {
    // base_utc 本地即 00:00。目标 03:00 → 今天 03:00
    try std.testing.expectEqual(base_utc + 3 * 3600, nextRunAt(base_utc, 3, 0, 0));
}

test "nextRunAt 在负偏移时区下也正确" {
    // UTC-5：base_utc 本地是前一天 19:00。目标 23:00 → 本地当天 23:00 = base_utc + 4h
    try std.testing.expectEqual(base_utc + 4 * 3600, nextRunAt(base_utc, 23, 0, -5 * 3600));
}

test "windowStart：last_run 为 null（首次运行）→ 退化成固定 24h 窗口" {
    const got = windowStart(base_utc, null);
    try std.testing.expectEqual(base_utc - day, got.start);
    try std.testing.expect(!got.clamped);
}

test "windowStart：last_run >= run_at（这个群已经跟上了）→ 空窗口" {
    const got_equal = windowStart(base_utc, base_utc);
    try std.testing.expectEqual(base_utc, got_equal.start);
    try std.testing.expect(!got_equal.clamped);

    const got_ahead = windowStart(base_utc, base_utc + 3600);
    try std.testing.expectEqual(base_utc, got_ahead.start);
    try std.testing.expect(!got_ahead.clamped);
}

test "windowStart：正常回补 → 窗口起点就是 last_run，不截断" {
    const last = base_utc - 3 * day;
    const got = windowStart(base_utc, last);
    try std.testing.expectEqual(last, got.start);
    try std.testing.expect(!got.clamped);
}

test "windowStart：停机跨度恰为 7 天上限 → 不截断" {
    const last = base_utc - max_lookback_seconds;
    const got = windowStart(base_utc, last);
    try std.testing.expectEqual(last, got.start);
    try std.testing.expect(!got.clamped);
}

test "windowStart：停机跨度比 7 天上限多 1 秒 → 截断且标记 clamped" {
    const last = base_utc - max_lookback_seconds - 1;
    const got = windowStart(base_utc, last);
    try std.testing.expectEqual(base_utc - max_lookback_seconds, got.start);
    try std.testing.expect(got.clamped);
}

test "missedRun：从未跑过则不补跑" {
    try std.testing.expectEqual(@as(?i64, null), missedRun(base_utc, null, 3, 0, cst));
}

test "missedRun：今天该跑的时刻已过且上次早于它 → 返回该时刻" {
    // base_utc 本地 08:00，今天 03:00 本地 = base_utc - 5h，已过
    const today_run = base_utc - 5 * 3600;
    try std.testing.expectEqual(@as(?i64, today_run), missedRun(base_utc, today_run - day, 3, 0, cst));
}

test "missedRun：今天已经跑过则不补跑" {
    const today_run = base_utc - 5 * 3600;
    try std.testing.expectEqual(@as(?i64, null), missedRun(base_utc, today_run, 3, 0, cst));
    try std.testing.expectEqual(@as(?i64, null), missedRun(base_utc, today_run + 60, 3, 0, cst));
}

test "missedRun：今天的时刻还没到则不补跑" {
    // 目标 10:30 本地，现在本地 08:00，还没到
    try std.testing.expectEqual(@as(?i64, null), missedRun(base_utc, base_utc - day, 10, 30, cst));
}

test "localOffsetSeconds 返回整分钟对齐的偏移" {
    const off = localOffsetSeconds(std.time.timestamp());
    try std.testing.expect(off > -13 * 3600 and off < 15 * 3600);
    try std.testing.expectEqual(@as(i64, 0), @mod(off, 60));
}
