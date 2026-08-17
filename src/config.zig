const std = @import("std");

pub const Error = error{ MissingEnv, InvalidValue, OutOfMemory };

pub const Env = std.StringHashMap([]const u8);

const env_keys = [_][]const u8{
    "NAPCAT_HTTP_URL", "NAPCAT_TOKEN",     "OBSERVED_QQS", "QQ_GROUP_IDS",
    "ADMIN_QQS",       "SCAN_TIME",        "HTTP_HOST",    "HTTP_PORT",
    "REDIS_URL",       "OCR_TESSDATA_DIR",
    // 已废弃，仍然读取：只为了在它单独在场时报出明确的改名错误。
    "OBSERVED_QQ",
};

pub const ScanTime = struct { hour: u8, minute: u8 };

pub const RedisTarget = struct {
    host: []u8,
    port: u16,
    password: ?[]u8,
    db: u32,

    pub fn deinit(self: *RedisTarget, gpa: std.mem.Allocator) void {
        gpa.free(self.host);
        if (self.password) |p| gpa.free(p);
    }
};

pub const Config = struct {
    gpa: std.mem.Allocator,
    napcat_url: []u8,
    napcat_token: []u8,
    /// 被观察者集合。**空切片 = 观察所有人**（任何群成员的消息都可能被收录），
    /// 这是部署上的常态配置，不是没人走的兜底分支。判定统一走
    /// `scan/rules.zig` 的 `Params.isObserved`，本文件只负责把 env 解析成
    /// 这个切片，不在这里再写一份"空即全部"的规则。
    observed_qqs: []u64,
    group_ids: []u64,
    admin_qqs: []u64,
    scan_hour: u8,
    scan_minute: u8,
    http_host: []u8,
    http_port: u16,
    redis_host: []u8,
    redis_port: u16,
    redis_password: ?[]u8,
    redis_db: u32,
    /// null 时让 Tesseract 使用系统自带模型；生产指向 tessdata_best 目录。
    ocr_tessdata_dir: ?[]u8,

    pub fn deinit(self: *Config) void {
        self.gpa.free(self.napcat_url);
        self.gpa.free(self.napcat_token);
        self.gpa.free(self.observed_qqs);
        self.gpa.free(self.group_ids);
        self.gpa.free(self.admin_qqs);
        self.gpa.free(self.http_host);
        self.gpa.free(self.redis_host);
        if (self.redis_password) |p| self.gpa.free(p);
        if (self.ocr_tessdata_dir) |p| self.gpa.free(p);
    }
};

const ws = " \t\r\n";

fn validEnvKey(key: []const u8) bool {
    if (key.len == 0 or !(std.ascii.isAlphabetic(key[0]) or key[0] == '_')) return false;
    for (key[1..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    return true;
}

/// dotenv 值解析刻意不做 `$VAR` / `${VAR}` 展开：配置文件不是 shell，值的
/// 含义不应依赖启动进程恰好带了哪些其它变量。单双引号只负责把空格、`#` 和
/// shell 元字符包在值里，外层引号会被剥掉；反斜杠保持字面量。
fn dotEnvValue(raw0: []const u8) Error![]const u8 {
    const raw = std.mem.trim(u8, raw0, ws);
    if (raw.len == 0) return raw;

    if (raw[0] == '\'' or raw[0] == '"') {
        const quote = raw[0];
        var close: ?usize = null;
        var i: usize = 1;
        while (i < raw.len) : (i += 1) {
            if (raw[i] == quote) {
                close = i;
                break;
            }
        }
        const end = close orelse return error.InvalidValue;
        const tail = std.mem.trim(u8, raw[end + 1 ..], ws);
        if (tail.len > 0 and tail[0] != '#') return error.InvalidValue;
        return raw[1..end];
    }

    // 未加引号时，`#` 只有位于值开头或前面是空白才开始注释；URL/token 中
    // 连着写的 `#` 是值本身，不能被截断。
    var end = raw.len;
    for (raw, 0..) |c, i| {
        if (c == '#' and (i == 0 or std.ascii.isWhitespace(raw[i - 1]))) {
            end = i;
            break;
        }
    }
    return std.mem.trimRight(u8, raw[0..end], ws);
}

fn putOverride(env: *Env, key: []const u8, value: []const u8) Error!void {
    env.put(key, value) catch return error.OutOfMemory;
}

/// 把一份 `.env` 文本解析进 Env。后出现的同名键覆盖前面的；真正的进程环境
/// 会在 load() 里再覆盖这一层，所以优先级固定为 process env > .env。
fn parseDotEnvInto(env: *Env, contents0: []const u8) Error!void {
    var contents = contents0;
    if (std.mem.startsWith(u8, contents, "\xEF\xBB\xBF")) contents = contents[3..];

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, ws);
        if (line.len == 0 or line[0] == '#') continue;

        if (std.mem.startsWith(u8, line, "export") and line.len > "export".len and std.ascii.isWhitespace(line["export".len])) {
            line = std.mem.trimLeft(u8, line["export".len..], ws);
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidValue;
        const key = std.mem.trim(u8, line[0..eq], ws);
        if (!validEnvKey(key)) return error.InvalidValue;
        const value = try dotEnvValue(line[eq + 1 ..]);
        try putOverride(env, key, value);
    }
}

fn parseUintList(gpa: std.mem.Allocator, raw: []const u8) Error![]u64 {
    var out: std.ArrayList(u64) = .empty;
    errdefer out.deinit(gpa);
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, ws);
        if (t.len == 0) return error.InvalidValue;
        const n = std.fmt.parseInt(u64, t, 10) catch return error.InvalidValue;
        try out.append(gpa, n);
    }
    if (out.items.len == 0) return error.InvalidValue;
    return out.toOwnedSlice(gpa);
}

fn parseScanTime(raw: []const u8) Error!ScanTime {
    if (raw.len != 5 or raw[2] != ':') return error.InvalidValue;
    const h = std.fmt.parseInt(u8, raw[0..2], 10) catch return error.InvalidValue;
    const m = std.fmt.parseInt(u8, raw[3..5], 10) catch return error.InvalidValue;
    if (h > 23 or m > 59) return error.InvalidValue;
    return .{ .hour = h, .minute = m };
}

fn parseRedisUrl(gpa: std.mem.Allocator, raw: []const u8) Error!RedisTarget {
    const prefix = "redis://";
    if (!std.mem.startsWith(u8, raw, prefix)) return error.InvalidValue;
    var rest = raw[prefix.len..];

    var password: ?[]u8 = null;
    errdefer if (password) |p| gpa.free(p);
    if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at| {
        const cred = rest[0..at];
        if (cred.len == 0 or cred[0] != ':') return error.InvalidValue;
        if (cred.len == 1) return error.InvalidValue;
        password = try gpa.dupe(u8, cred[1..]);
        rest = rest[at + 1 ..];
    }

    var db: u32 = 0;
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
        const dbs = rest[slash + 1 ..];
        if (dbs.len > 0) db = std.fmt.parseInt(u32, dbs, 10) catch return error.InvalidValue;
        rest = rest[0..slash];
    }

    const colon = std.mem.lastIndexOfScalar(u8, rest, ':') orelse return error.InvalidValue;
    const host_raw = rest[0..colon];
    if (host_raw.len == 0) return error.InvalidValue;
    const port = std.fmt.parseInt(u16, rest[colon + 1 ..], 10) catch return error.InvalidValue;

    const host = try gpa.dupe(u8, host_raw);
    return .{ .host = host, .port = port, .password = password, .db = db };
}

fn need(env: Env, key: []const u8, bad: *?[]const u8) Error![]const u8 {
    const v = env.get(key) orelse {
        bad.* = key;
        return error.MissingEnv;
    };
    if (std.mem.trim(u8, v, ws).len == 0) {
        bad.* = key;
        return error.MissingEnv;
    }
    return std.mem.trim(u8, v, ws);
}

/// 取一个**可选**变量：不存在、或者存在但 trim 后是空串，都当作"没填"。
/// `OBSERVED_QQS` 靠这条把"没填"和"填了空串"折叠成同一个语义（观察所有人），
/// 而不是像 need() 那样把空串当成缺失错误。
fn optional(env: Env, key: []const u8) ?[]const u8 {
    const v = env.get(key) orelse return null;
    const t = std.mem.trim(u8, v, ws);
    return if (t.len == 0) null else t;
}

/// `bad` 里报给运营方的那句话：既点名旧变量、也点名新变量，让人一眼知道
/// 要把 .env 里的哪一行改成什么。
pub const observed_renamed_hint = "OBSERVED_QQ (renamed to OBSERVED_QQS; unset means observe everyone)";

pub fn loadFrom(gpa: std.mem.Allocator, env: Env, bad: *?[]const u8) Error!Config {
    const napcat_url_raw = try need(env, "NAPCAT_HTTP_URL", bad);
    const napcat_token_raw = try need(env, "NAPCAT_TOKEN", bad);
    const groups_raw = try need(env, "QQ_GROUP_IDS", bad);
    const admins_raw = try need(env, "ADMIN_QQS", bad);
    const scan_raw = try need(env, "SCAN_TIME", bad);
    const host_raw = try need(env, "HTTP_HOST", bad);
    const port_raw = try need(env, "HTTP_PORT", bad);
    const redis_raw = try need(env, "REDIS_URL", bad);

    // 旧名字 OBSERVED_QQ 已经不存在了，而且**故意不做别名**：一个被静默
    // 忽略的旧变量名比一条"改名字"的启动错误糟糕得多——运营方会以为观察
    // 范围还是原来那个人，实际上进程已经在观察所有人（空集合语义）。只有
    // 旧名字在场、新名字缺席时才报错，两个都在时以新的为准（迁移期间
    // .env 里两个并存不该拦住启动）。
    if (env.get("OBSERVED_QQ") != null and optional(env, "OBSERVED_QQS") == null) {
        bad.* = observed_renamed_hint;
        return error.InvalidValue;
    }
    // 不填 / 填空串 = 观察所有人 → 空切片。
    const observed = blk: {
        const raw = optional(env, "OBSERVED_QQS") orelse break :blk try gpa.alloc(u64, 0);
        break :blk parseUintList(gpa, raw) catch |e| {
            bad.* = "OBSERVED_QQS";
            return if (e == error.OutOfMemory) e else error.InvalidValue;
        };
    };
    errdefer gpa.free(observed);
    const groups = parseUintList(gpa, groups_raw) catch |e| {
        bad.* = "QQ_GROUP_IDS";
        return if (e == error.OutOfMemory) e else error.InvalidValue;
    };
    errdefer gpa.free(groups);
    const admins = parseUintList(gpa, admins_raw) catch |e| {
        bad.* = "ADMIN_QQS";
        return if (e == error.OutOfMemory) e else error.InvalidValue;
    };
    errdefer gpa.free(admins);
    const scan = parseScanTime(scan_raw) catch {
        bad.* = "SCAN_TIME";
        return error.InvalidValue;
    };
    const port = std.fmt.parseInt(u16, port_raw, 10) catch {
        bad.* = "HTTP_PORT";
        return error.InvalidValue;
    };
    var redis = parseRedisUrl(gpa, redis_raw) catch |e| {
        bad.* = "REDIS_URL";
        return if (e == error.OutOfMemory) e else error.InvalidValue;
    };
    errdefer redis.deinit(gpa);

    const napcat_url = try gpa.dupe(u8, std.mem.trimRight(u8, napcat_url_raw, "/"));
    errdefer gpa.free(napcat_url);
    const napcat_token = try gpa.dupe(u8, napcat_token_raw);
    errdefer gpa.free(napcat_token);
    const http_host = try gpa.dupe(u8, host_raw);
    errdefer gpa.free(http_host);
    const ocr_tessdata_dir = if (optional(env, "OCR_TESSDATA_DIR")) |raw|
        try gpa.dupe(u8, raw)
    else
        null;
    errdefer if (ocr_tessdata_dir) |p| gpa.free(p);

    return .{
        .gpa = gpa,
        .napcat_url = napcat_url,
        .napcat_token = napcat_token,
        .observed_qqs = observed,
        .group_ids = groups,
        .admin_qqs = admins,
        .scan_hour = scan.hour,
        .scan_minute = scan.minute,
        .http_host = http_host,
        .http_port = port,
        .redis_host = redis.host,
        .redis_port = redis.port,
        .redis_password = redis.password,
        .redis_db = redis.db,
        .ocr_tessdata_dir = ocr_tessdata_dir,
    };
}

pub fn load(gpa: std.mem.Allocator, bad: *?[]const u8) Error!Config {
    var env: Env = .init(gpa);
    defer env.deinit();

    const dot_env: ?[]u8 = std.fs.cwd().readFileAlloc(gpa, ".env", 1024 * 1024) catch |e| switch (e) {
        error.FileNotFound => null,
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            bad.* = ".env";
            return error.InvalidValue;
        },
    };
    defer if (dot_env) |contents| gpa.free(contents);
    if (dot_env) |contents| {
        parseDotEnvInto(&env, contents) catch |e| {
            bad.* = ".env";
            return e;
        };
    }

    // 只拥有真实进程环境返回的副本；`.env` 的 key/value 都是 dot_env 里的
    // 切片，随上面的 buffer 一起释放，不能在 valueIterator 里混着 free。
    var process_values: std.ArrayList([]u8) = .empty;
    defer {
        for (process_values.items) |v| gpa.free(v);
        process_values.deinit(gpa);
    }
    for (env_keys) |k| {
        const v = std.process.getEnvVarOwned(gpa, k) catch |e| switch (e) {
            error.EnvironmentVariableNotFound => continue,
            else => return error.InvalidValue,
        };
        process_values.append(gpa, v) catch {
            gpa.free(v);
            return error.OutOfMemory;
        };
        putOverride(&env, k, v) catch |e| {
            _ = process_values.pop();
            gpa.free(v);
            return e;
        };
    }
    return loadFrom(gpa, env, bad);
}

test ".env：支持注释、export、单双引号和 shell 元字符，且不展开 $VAR" {
    const gpa = std.testing.allocator;
    var env: Env = .init(gpa);
    defer env.deinit();

    try parseDotEnvInto(&env,
        \\# comment
        \\export NAPCAT_HTTP_URL = http://127.0.0.1:3000 # inline comment
        \\NAPCAT_TOKEN='a?b)c!d#e*f'
        \\REDIS_URL="redis://:$PASSWORD@127.0.0.1:6379/0"
        \\HTTP_HOST=host#literal
        \\HTTP_PORT=8080
    );

    try std.testing.expectEqualStrings("http://127.0.0.1:3000", env.get("NAPCAT_HTTP_URL").?);
    try std.testing.expectEqualStrings("a?b)c!d#e*f", env.get("NAPCAT_TOKEN").?);
    try std.testing.expectEqualStrings("redis://:$PASSWORD@127.0.0.1:6379/0", env.get("REDIS_URL").?);
    try std.testing.expectEqualStrings("host#literal", env.get("HTTP_HOST").?);
}

test ".env：后写覆盖前写，进程环境覆盖文件值使用同一条 putOverride" {
    const gpa = std.testing.allocator;
    var env: Env = .init(gpa);
    defer env.deinit();

    try parseDotEnvInto(&env, "HTTP_PORT=7000\nHTTP_PORT=7001\n");
    try std.testing.expectEqualStrings("7001", env.get("HTTP_PORT").?);
    try putOverride(&env, "HTTP_PORT", "9000");
    try std.testing.expectEqualStrings("9000", env.get("HTTP_PORT").?);
}

test ".env：拒绝坏键、缺等号、未闭合引号和引号后的垃圾" {
    const gpa = std.testing.allocator;
    inline for ([_][]const u8{
        "1BAD=x\n",
        "NO_EQUALS\n",
        "TOKEN='unterminated\n",
        "TOKEN='ok' trailing\n",
    }) |contents| {
        var env: Env = .init(gpa);
        defer env.deinit();
        try std.testing.expectError(error.InvalidValue, parseDotEnvInto(&env, contents));
    }
}

test "parseUintList 解析逗号分隔的 QQ 号" {
    const gpa = std.testing.allocator;
    const got = try parseUintList(gpa, "123, 456 ,789");
    defer gpa.free(got);
    try std.testing.expectEqualSlices(u64, &.{ 123, 456, 789 }, got);
}

test "parseUintList 拒绝空串与非数字" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidValue, parseUintList(gpa, ""));
    try std.testing.expectError(error.InvalidValue, parseUintList(gpa, "12,,34"));
    try std.testing.expectError(error.InvalidValue, parseUintList(gpa, "12,ab"));
}

test "parseScanTime 解析 HH:MM" {
    try std.testing.expectEqual(ScanTime{ .hour = 3, .minute = 0 }, try parseScanTime("03:00"));
    try std.testing.expectEqual(ScanTime{ .hour = 23, .minute = 59 }, try parseScanTime("23:59"));
}

test "parseScanTime 拒绝越界与格式错误" {
    try std.testing.expectError(error.InvalidValue, parseScanTime("24:00"));
    try std.testing.expectError(error.InvalidValue, parseScanTime("03:60"));
    try std.testing.expectError(error.InvalidValue, parseScanTime("3:00"));
    try std.testing.expectError(error.InvalidValue, parseScanTime("0300"));
}

test "parseRedisUrl 解析带密码与不带密码两种形式" {
    const gpa = std.testing.allocator;

    var a = try parseRedisUrl(gpa, "redis://127.0.0.1:6379/0");
    defer a.deinit(gpa);
    try std.testing.expectEqualStrings("127.0.0.1", a.host);
    try std.testing.expectEqual(@as(u16, 6379), a.port);
    try std.testing.expectEqual(@as(?[]u8, null), a.password);
    try std.testing.expectEqual(@as(u32, 0), a.db);

    var b = try parseRedisUrl(gpa, "redis://:s3cret@redis.internal:6380/2");
    defer b.deinit(gpa);
    try std.testing.expectEqualStrings("redis.internal", b.host);
    try std.testing.expectEqual(@as(u16, 6380), b.port);
    try std.testing.expectEqualStrings("s3cret", b.password.?);
    try std.testing.expectEqual(@as(u32, 2), b.db);
}

test "parseRedisUrl 缺省 db 视为 0，拒绝非 redis scheme" {
    const gpa = std.testing.allocator;
    var a = try parseRedisUrl(gpa, "redis://h:1");
    defer a.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 0), a.db);
    try std.testing.expectError(error.InvalidValue, parseRedisUrl(gpa, "http://h:1"));
}

fn testEnv(gpa: std.mem.Allocator) !Env {
    var env: Env = .init(gpa);
    try env.put("NAPCAT_HTTP_URL", "http://127.0.0.1:3000");
    try env.put("NAPCAT_TOKEN", "tok");
    try env.put("OBSERVED_QQS", "10001");
    try env.put("QQ_GROUP_IDS", "111,222");
    try env.put("ADMIN_QQS", "20001");
    try env.put("SCAN_TIME", "03:00");
    try env.put("HTTP_HOST", "0.0.0.0");
    try env.put("HTTP_PORT", "8080");
    try env.put("REDIS_URL", "redis://127.0.0.1:6379/0");
    return env;
}

test "loadFrom 读全所有字段" {
    const gpa = std.testing.allocator;
    var env = try testEnv(gpa);
    defer env.deinit();
    var bad: ?[]const u8 = null;
    var cfg = try loadFrom(gpa, env, &bad);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("http://127.0.0.1:3000", cfg.napcat_url);
    try std.testing.expectEqualSlices(u64, &.{10001}, cfg.observed_qqs);
    try std.testing.expectEqualSlices(u64, &.{ 111, 222 }, cfg.group_ids);
    try std.testing.expectEqualSlices(u64, &.{20001}, cfg.admin_qqs);
    try std.testing.expectEqual(@as(u8, 3), cfg.scan_hour);
    try std.testing.expectEqual(@as(u16, 8080), cfg.http_port);
    try std.testing.expectEqual(@as(u16, 6379), cfg.redis_port);
    try std.testing.expectEqual(@as(?[]u8, null), cfg.ocr_tessdata_dir);
}

test "loadFrom：OCR_TESSDATA_DIR 可选，填写时保留路径" {
    const gpa = std.testing.allocator;
    var env = try testEnv(gpa);
    defer env.deinit();
    try env.put("OCR_TESSDATA_DIR", "/opt/hikari/tessdata");
    var bad: ?[]const u8 = null;
    var cfg = try loadFrom(gpa, env, &bad);
    defer cfg.deinit();
    try std.testing.expectEqualStrings("/opt/hikari/tessdata", cfg.ocr_tessdata_dir.?);
}

test "loadFrom 缺字段时报出是哪一个" {
    const gpa = std.testing.allocator;
    var env = try testEnv(gpa);
    defer env.deinit();
    _ = env.remove("ADMIN_QQS");
    var bad: ?[]const u8 = null;
    try std.testing.expectError(error.MissingEnv, loadFrom(gpa, env, &bad));
    try std.testing.expectEqualStrings("ADMIN_QQS", bad.?);
}

test "loadFrom 值非法时报出是哪一个" {
    const gpa = std.testing.allocator;
    var env = try testEnv(gpa);
    defer env.deinit();
    try env.put("HTTP_PORT", "notanumber");
    var bad: ?[]const u8 = null;
    try std.testing.expectError(error.InvalidValue, loadFrom(gpa, env, &bad));
    try std.testing.expectEqualStrings("HTTP_PORT", bad.?);
}

test "loadFrom：OBSERVED_QQS 不填 = 观察所有人（空切片，不是错误）" {
    const gpa = std.testing.allocator;
    var env = try testEnv(gpa);
    defer env.deinit();
    _ = env.remove("OBSERVED_QQS");
    var bad: ?[]const u8 = null;
    var cfg = try loadFrom(gpa, env, &bad);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 0), cfg.observed_qqs.len);
}

test "loadFrom：OBSERVED_QQS 填空串同样是观察所有人" {
    const gpa = std.testing.allocator;
    var env = try testEnv(gpa);
    defer env.deinit();
    try env.put("OBSERVED_QQS", "   ");
    var bad: ?[]const u8 = null;
    var cfg = try loadFrom(gpa, env, &bad);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 0), cfg.observed_qqs.len);
}

test "loadFrom：OBSERVED_QQS 解析成逗号分隔的多个 QQ，跟 ADMIN_QQS 同一套语法" {
    const gpa = std.testing.allocator;
    var env = try testEnv(gpa);
    defer env.deinit();
    try env.put("OBSERVED_QQS", "10001, 10002 ,10003");
    var bad: ?[]const u8 = null;
    var cfg = try loadFrom(gpa, env, &bad);
    defer cfg.deinit();
    try std.testing.expectEqualSlices(u64, &.{ 10001, 10002, 10003 }, cfg.observed_qqs);
}

test "loadFrom：只留旧名字 OBSERVED_QQ 时启动失败，错误里同时点名新旧两个变量" {
    const gpa = std.testing.allocator;
    var env = try testEnv(gpa);
    defer env.deinit();
    _ = env.remove("OBSERVED_QQS");
    try env.put("OBSERVED_QQ", "10001");
    var bad: ?[]const u8 = null;
    // 静默忽略旧变量名是这条规则唯一不能接受的行为：运营方会以为观察范围
    // 还是那一个人，实际上进程已经在观察所有人。
    try std.testing.expectError(error.InvalidValue, loadFrom(gpa, env, &bad));
    try std.testing.expect(std.mem.indexOf(u8, bad.?, "OBSERVED_QQ") != null);
    try std.testing.expect(std.mem.indexOf(u8, bad.?, "OBSERVED_QQS") != null);
}

test "loadFrom：新旧两个名字并存时以新的为准，不拦启动（迁移期间可以两个都写着）" {
    const gpa = std.testing.allocator;
    var env = try testEnv(gpa);
    defer env.deinit();
    try env.put("OBSERVED_QQ", "77777");
    try env.put("OBSERVED_QQS", "10001,10002");
    var bad: ?[]const u8 = null;
    var cfg = try loadFrom(gpa, env, &bad);
    defer cfg.deinit();
    try std.testing.expectEqualSlices(u64, &.{ 10001, 10002 }, cfg.observed_qqs);
}

test "loadFrom：OBSERVED_QQS 值非法时报出是哪一个" {
    const gpa = std.testing.allocator;
    var env = try testEnv(gpa);
    defer env.deinit();
    try env.put("OBSERVED_QQS", "10001,abc");
    var bad: ?[]const u8 = null;
    try std.testing.expectError(error.InvalidValue, loadFrom(gpa, env, &bad));
    try std.testing.expectEqualStrings("OBSERVED_QQS", bad.?);
}
