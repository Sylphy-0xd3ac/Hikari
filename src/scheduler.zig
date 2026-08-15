const std = @import("std");

const c = @cImport({
    @cInclude("time.h");
});

const seconds_per_day: i64 = 86400;

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

/// 扫描窗口 = [触发时刻 - 24h, 触发时刻)
pub fn windowStart(run_at: i64) i64 {
    return run_at - seconds_per_day;
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

test "windowStart 恒为触发时刻前 24 小时" {
    try std.testing.expectEqual(base_utc - day, windowStart(base_utc));
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
