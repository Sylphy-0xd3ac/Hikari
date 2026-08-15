const std = @import("std");
const redis = @import("redis/client.zig");
const resp = @import("redis/resp.zig");

pub const Error = redis.Error || error{OutOfMemory};

pub const key_index = "hikari:index";
pub const key_bylen = "hikari:bylen";
pub const key_tomb = "hikari:tomb";
pub const key_seq = "hikari:seq";
pub const key_lastrun_prefix = "hikari:lastrun";

pub const Quote = struct {
    id: u64,
    uuid: [36]u8,
    hitokoto: []const u8,
    kind: []const u8,
    from: []const u8,
    from_who: []const u8,
    creator: []const u8,
    creator_uid: u64,
    reviewer: u64,
    commit_from: []const u8,
    created_at: []const u8,
    length: usize,
    message_id: i64,
    group_id: u64,
    user_id: u64,

    /// 仅用于 quoteFromPairs 返回的 Quote（其字符串字段是新分配的）。
    /// 由调用方自行构造、字段借用别处内存（比如字符串字面量）的 Quote 不要调这个，
    /// 否则会尝试 free 一段不是从 gpa 分配出来的内存。
    pub fn deinit(self: Quote, gpa: std.mem.Allocator) void {
        gpa.free(self.hitokoto);
        gpa.free(self.kind);
        gpa.free(self.from);
        gpa.free(self.from_who);
        gpa.free(self.creator);
        gpa.free(self.commit_from);
        gpa.free(self.created_at);
    }
};

/// 按 UTF-8 码点数计长度；序列非法时退化为字节数。
pub fn utf8Length(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

pub fn quoteKey(buf: *[64]u8, message_id: i64) []const u8 {
    return std.fmt.bufPrint(buf, "hikari:quote:{d}", .{message_id}) catch unreachable;
}

/// 每个群各自的"上次扫描窗口终点"键。原先是单个全局 `hikari:lastrun`，但
/// `QQ_GROUP_IDS` 是逐群独立跑的：一个群失败不该让另一个群的成功掩盖它，
/// 全局键做不到这一点（见 runner.zig runOnce 的调用点）。
pub fn lastRunKey(buf: *[64]u8, group_id: u64) []const u8 {
    return std.fmt.bufPrint(buf, "{s}:{d}", .{ key_lastrun_prefix, group_id }) catch unreachable;
}

fn dupInt(gpa: std.mem.Allocator, v: anytype) ![]const u8 {
    return std.fmt.allocPrint(gpa, "{d}", .{v});
}

/// 把一段已经拥有所有权的字符串塞进 `out`；如果 append 本身分配失败，
/// 负责把这段字符串释放掉，不留给调用方处理——这样调用方在 `try` 失败时
/// 不需要再操心这个参数的归属。
fn appendOwned(gpa: std.mem.Allocator, out: *std.ArrayList([]const u8), s: []const u8) !void {
    errdefer gpa.free(s);
    try out.append(gpa, s);
}

/// 追加一个 field/value 对：`name` 是字符串字面量，在函数内部复制；`value`
/// 是调用方已经分配好、转移所有权进来的字符串。整个过程中不管哪一步失败，
/// `value` 与（如果已经分配出来的）`name` 副本都恰好被释放一次，不会有一份
/// 被孤儿化，也不会被释放两次：
///   - name 复制失败：value 还没被消费，靠函数顶部的 errdefer 释放。
///   - name 复制成功但 append(name_dup) 失败：内层 block 的 errdefer 释放
///     name_dup，外层的 errdefer 接着释放 value（value 从未被 append 过）。
///   - name 已成功挂到 out 上，append(value) 失败：value 靠外层 errdefer
///     释放；name_dup 已经在 out.items 里，会被 hashFields 顶层的清理逻辑
///     处理，不会重复释放。
///   - 两次 append 都成功：两个 errdefer 都随各自的 block 正常退出而不触发。
fn appendField(gpa: std.mem.Allocator, out: *std.ArrayList([]const u8), name: []const u8, value: []const u8) !void {
    errdefer gpa.free(value);
    {
        const name_dup = try gpa.dupe(u8, name);
        errdefer gpa.free(name_dup);
        try out.append(gpa, name_dup);
    }
    try out.append(gpa, value);
}

/// 产出 `HSET <key> <field> <value> ...` 的完整参数数组。所有元素都是新分配的，
/// 用 freeHashFields 释放。
///
/// 实现说明：brief 草稿里曾把各字段的 `try dupInt(...)` / `try gpa.dupe(...)`
/// 调用摆在一个数组字面量 `[_][2][]const u8{ .{...}, .{...}, ... }` 里。这个写法
/// 有个隐患：数组字面量的各元素在赋值给任何变量之前就按顺序求值，如果排在后面的
/// 某个 `try` 失败，前面已经求值成功、已经拿到堆内存的那些元素并没有被任何东西
/// 持有——它们不在 `out` 里（还没 append），也不在字面量本身里（字面量还没构造
///完成就已经因为 try 提前返回），于是被孤儿化，在只有分配失败测试才会走到的
/// 路径上泄漏。这里改成逐字段调用 appendOwned/appendField，让每次分配后立刻有
/// 明确的持有者（要么被 append 进 out，要么在失败时被 errdefer 释放），不再有
/// “已分配但暂无持有者”的中间状态。
pub fn hashFields(gpa: std.mem.Allocator, q: Quote) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |s| gpa.free(s);
        out.deinit(gpa);
    }

    try appendOwned(gpa, &out, try gpa.dupe(u8, "HSET"));
    var kb: [64]u8 = undefined;
    try appendOwned(gpa, &out, try gpa.dupe(u8, quoteKey(&kb, q.message_id)));

    try appendField(gpa, &out, "id", try dupInt(gpa, q.id));
    try appendField(gpa, &out, "uuid", try gpa.dupe(u8, &q.uuid));
    try appendField(gpa, &out, "hitokoto", try gpa.dupe(u8, q.hitokoto));
    try appendField(gpa, &out, "type", try gpa.dupe(u8, q.kind));
    try appendField(gpa, &out, "from", try gpa.dupe(u8, q.from));
    try appendField(gpa, &out, "from_who", try gpa.dupe(u8, q.from_who));
    try appendField(gpa, &out, "creator", try gpa.dupe(u8, q.creator));
    try appendField(gpa, &out, "creator_uid", try dupInt(gpa, q.creator_uid));
    try appendField(gpa, &out, "reviewer", try dupInt(gpa, q.reviewer));
    try appendField(gpa, &out, "commit_from", try gpa.dupe(u8, q.commit_from));
    try appendField(gpa, &out, "created_at", try gpa.dupe(u8, q.created_at));
    try appendField(gpa, &out, "length", try dupInt(gpa, q.length));
    try appendField(gpa, &out, "message_id", try dupInt(gpa, q.message_id));
    try appendField(gpa, &out, "group_id", try dupInt(gpa, q.group_id));
    try appendField(gpa, &out, "user_id", try dupInt(gpa, q.user_id));

    return out.toOwnedSlice(gpa);
}

pub fn freeHashFields(gpa: std.mem.Allocator, args: [][]const u8) void {
    for (args) |s| gpa.free(s);
    gpa.free(args);
}

fn pairLookup(pairs: []const resp.Value, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < pairs.len) : (i += 2) {
        const k = switch (pairs[i]) {
            .bulk => |b| b orelse continue,
            else => continue,
        };
        if (!std.mem.eql(u8, k, name)) continue;
        return switch (pairs[i + 1]) {
            .bulk => |b| b orelse null,
            else => null,
        };
    }
    return null;
}

/// 把 HGETALL 的扁平 field/value 回复还原成 Quote。字段缺失或空回复返回 null。
///
/// 分配顺序：hitokoto -> kind -> from -> from_who -> creator -> commit_from
/// -> created_at，每次分配后立刻 errdefer，形成一条标准的链式清理——前面已经
/// 成功分配的字段在后面任意一步失败时都会被按相反顺序释放。created_at 之后
/// 没有 errdefer：之后只剩下 @splat、@memcpy 和 parseOr（内部用 catch 兜底，
/// 不返回错误）这些不会失败的操作，所以不需要保护。
pub fn quoteFromPairs(gpa: std.mem.Allocator, pairs: []const resp.Value) !?Quote {
    if (pairs.len == 0) return null;
    const hitokoto_raw = pairLookup(pairs, "hitokoto") orelse return null;

    var q: Quote = undefined;
    q.hitokoto = try gpa.dupe(u8, hitokoto_raw);
    errdefer gpa.free(q.hitokoto);
    q.kind = try gpa.dupe(u8, pairLookup(pairs, "type") orelse "g");
    errdefer gpa.free(q.kind);
    q.from = try gpa.dupe(u8, pairLookup(pairs, "from") orelse "");
    errdefer gpa.free(q.from);
    q.from_who = try gpa.dupe(u8, pairLookup(pairs, "from_who") orelse "");
    errdefer gpa.free(q.from_who);
    q.creator = try gpa.dupe(u8, pairLookup(pairs, "creator") orelse "Hikari");
    errdefer gpa.free(q.creator);
    q.commit_from = try gpa.dupe(u8, pairLookup(pairs, "commit_from") orelse "hikari");
    errdefer gpa.free(q.commit_from);
    q.created_at = try gpa.dupe(u8, pairLookup(pairs, "created_at") orelse "0");

    q.uuid = @splat('0');
    if (pairLookup(pairs, "uuid")) |u| {
        if (u.len == 36) @memcpy(&q.uuid, u);
    }

    q.id = parseOr(u64, pairLookup(pairs, "id"), 0);
    q.creator_uid = parseOr(u64, pairLookup(pairs, "creator_uid"), 0);
    q.reviewer = parseOr(u64, pairLookup(pairs, "reviewer"), 0);
    q.length = parseOr(usize, pairLookup(pairs, "length"), utf8Length(hitokoto_raw));
    q.message_id = parseOr(i64, pairLookup(pairs, "message_id"), 0);
    q.group_id = parseOr(u64, pairLookup(pairs, "group_id"), 0);
    q.user_id = parseOr(u64, pairLookup(pairs, "user_id"), 0);
    return q;
}

fn parseOr(comptime T: type, s: ?[]const u8, fallback: T) T {
    const raw = s orelse return fallback;
    return std.fmt.parseInt(T, raw, 10) catch fallback;
}

pub const Store = struct {
    gpa: std.mem.Allocator,
    client: *redis.Client,
    mutex: std.Thread.Mutex,

    /// `gpa` is used for the caller-visible allocations this type makes
    /// (`hashFields` buffers, `Quote` string fields returned to the caller).
    /// It is a distinct parameter from `client.gpa` on purpose: `client.gpa`
    /// is the allocator `redis.Client.command` used to build its `resp.Value`
    /// reply, and that reply must be freed with the *same* allocator it was
    /// allocated with (`client.gpa`), not with `self.gpa`. `Store` never
    /// calls `v.deinit(self.gpa)` for that reason — always `v.deinit(self.client.gpa)`.
    pub fn init(gpa: std.mem.Allocator, client: *redis.Client) Store {
        return .{ .gpa = gpa, .client = client, .mutex = .{} };
    }

    pub fn nextId(self: *Store) Error!u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const n = try self.client.commandInt(&.{ "INCR", key_seq });
        return @intCast(@max(n, 0));
    }

    pub fn exists(self: *Store, message_id: i64) Error!bool {
        var buf: [32]u8 = undefined;
        const ids = std.fmt.bufPrint(&buf, "{d}", .{message_id}) catch unreachable;
        self.mutex.lock();
        defer self.mutex.unlock();
        return (try self.client.commandInt(&.{ "SISMEMBER", key_index, ids })) == 1;
    }

    pub fn isTombstoned(self: *Store, message_id: i64) Error!bool {
        var buf: [32]u8 = undefined;
        const ids = std.fmt.bufPrint(&buf, "{d}", .{message_id}) catch unreachable;
        self.mutex.lock();
        defer self.mutex.unlock();
        return (try self.client.commandInt(&.{ "SISMEMBER", key_tomb, ids })) == 1;
    }

    pub fn add(self: *Store, q: Quote) Error!void {
        const args = try hashFields(self.gpa, q);
        defer freeHashFields(self.gpa, args);

        var idb: [32]u8 = undefined;
        const ids = std.fmt.bufPrint(&idb, "{d}", .{q.message_id}) catch unreachable;
        var lenb: [32]u8 = undefined;
        const lens = std.fmt.bufPrint(&lenb, "{d}", .{q.length}) catch unreachable;

        self.mutex.lock();
        defer self.mutex.unlock();
        // 顺序即事务语义：exists() 查的是 hikari:index，所以 SADD 是提交点，
        // 必须最后发。这样三种部分失败（只有 HSET 成功 / HSET+ZADD 成功）
        // 留下的状态都满足 exists() == false，下一次扫描原样重做一遍即可修复
        // （三条命令都幂等）。若把 SADD 提到 ZADD 前面，"HSET+SADD 成功、
        // ZADD 失败" 会让这条语录 exists() == true 而永远不在 hikari:bylen 里：
        // GET / 随机得到它，任何 min_length/max_length 查询都永远看不见它，
        // 而且再也不会被修复。
        try self.client.commandOk(args);
        try self.client.commandOk(&.{ "ZADD", key_bylen, lens, ids });
        try self.client.commandOk(&.{ "SADD", key_index, ids });
    }

    pub fn revoke(self: *Store, message_id: i64) Error!void {
        var kb: [64]u8 = undefined;
        const qk = quoteKey(&kb, message_id);
        var idb: [32]u8 = undefined;
        const ids = std.fmt.bufPrint(&idb, "{d}", .{message_id}) catch unreachable;

        self.mutex.lock();
        defer self.mutex.unlock();
        // tombstone 先落盘：它是这次作废唯一持久的事实（"这条消息永远不再入库"），
        // 而删索引、删 hash 都只是它的后果。这样任何一次部分失败最坏留下一个
        // 孤儿 hash（没人索引得到它，只占空间），而不是 hikari:index 里一个
        // 没有 hash 的悬空 id——后者会被 randomAny 抽中、HGETALL 回空，让一个
        // 非空的库对外返回 404，且永远不会自愈。SREM 也排在 ZREM 前面，理由
        // 同 add()：index 是对外可见性的开关，先关它。
        try self.client.commandOk(&.{ "SADD", key_tomb, ids });
        try self.client.commandOk(&.{ "SREM", key_index, ids });
        try self.client.commandOk(&.{ "ZREM", key_bylen, ids });
        try self.client.commandOk(&.{ "DEL", qk });
    }

    pub fn setLastRun(self: *Store, group_id: u64, ts: i64) Error!void {
        var kb: [64]u8 = undefined;
        const key = lastRunKey(&kb, group_id);
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{ts}) catch unreachable;
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.client.commandOk(&.{ "SET", key, s });
    }

    pub fn getLastRun(self: *Store, group_id: u64) Error!?i64 {
        var kb: [64]u8 = undefined;
        const key = lastRunKey(&kb, group_id);
        self.mutex.lock();
        defer self.mutex.unlock();
        const v = try self.client.command(&.{ "GET", key });
        defer v.deinit(self.client.gpa);
        return switch (v) {
            .bulk => |b| if (b) |s| (std.fmt.parseInt(i64, s, 10) catch null) else null,
            else => null,
        };
    }

    /// 只在 randomAny / randomByLength 内部调用，此时锁已经被持有，所以这里
    /// 不再加锁——std.Thread.Mutex 不可重入，加了会自锁死。
    fn fetchById(self: *Store, gpa: std.mem.Allocator, id_str: []const u8) Error!?Quote {
        const mid = std.fmt.parseInt(i64, id_str, 10) catch return null;
        var kb: [64]u8 = undefined;
        const v = try self.client.command(&.{ "HGETALL", quoteKey(&kb, mid) });
        defer v.deinit(self.client.gpa);
        const items = switch (v) {
            .array => |a| a orelse return null,
            else => return null,
        };
        return quoteFromPairs(gpa, items);
    }

    pub fn randomAny(self: *Store, gpa: std.mem.Allocator) Error!?Quote {
        self.mutex.lock();
        defer self.mutex.unlock();
        const v = try self.client.command(&.{ "SRANDMEMBER", key_index });
        defer v.deinit(self.client.gpa);
        const id_str = switch (v) {
            .bulk => |b| b orelse return null,
            else => return null,
        };
        return self.fetchById(gpa, id_str);
    }

    pub fn randomByLength(self: *Store, gpa: std.mem.Allocator, min: usize, max: usize) Error!?Quote {
        var minb: [32]u8 = undefined;
        var maxb: [32]u8 = undefined;
        const mins = std.fmt.bufPrint(&minb, "{d}", .{min}) catch unreachable;
        const maxs = std.fmt.bufPrint(&maxb, "{d}", .{max}) catch unreachable;

        self.mutex.lock();
        defer self.mutex.unlock();
        const v = try self.client.command(&.{ "ZRANGEBYSCORE", key_bylen, mins, maxs });
        defer v.deinit(self.client.gpa);
        const items = switch (v) {
            .array => |a| a orelse return null,
            else => return null,
        };
        if (items.len == 0) return null;
        const pick = items[std.crypto.random.uintLessThan(usize, items.len)];
        const id_str = switch (pick) {
            .bulk => |b| b orelse return null,
            else => return null,
        };
        return self.fetchById(gpa, id_str);
    }

    /// `/extra/all`：拿到 hikari:index 的全部成员，逐个 HGETALL 展开。库空时
    /// SMEMBERS 回一个空数组（不是 nil），走到 fetchMany 时 ids 为空，直接
    /// 产出一个长度为 0 的、gpa 拥有的切片——调用方（HTTP 层）统一用
    /// `gpa.free` 释放返回值，不区分空库还是非空库，所以这里不能像
    /// randomAny 那样在空/nil 分支提前 return 一个不是 gpa 分配出来的切片。
    pub fn allQuotes(self: *Store, gpa: std.mem.Allocator) Error![]Quote {
        self.mutex.lock();
        defer self.mutex.unlock();
        const v = try self.client.command(&.{ "SMEMBERS", key_index });
        defer v.deinit(self.client.gpa);
        const items: []const resp.Value = switch (v) {
            .array => |a| if (a) |arr| arr else &[_]resp.Value{},
            else => &[_]resp.Value{},
        };
        return self.fetchMany(gpa, items);
    }

    /// `/extra/batch/:count`：SRANDMEMBER 的负数形式（`-count`）允许重复，
    /// 正数形式只会去重、且在 count 超过库大小时静默截断到库大小——调用方
    /// （HTTP 层）明确选择了"允许重复"这个语义，所以这里必须发负数形式，
    /// 不能图省事发正数。`count` 的上限校验（1000）由调用方在发这条命令
    /// 之前做：那是一处"用户输入直接决定分配/命令规模"的护栏，属于 HTTP 层
    /// 的职责，不是这里的。
    pub fn randomMany(self: *Store, gpa: std.mem.Allocator, count: usize) Error![]Quote {
        var buf: [32]u8 = undefined;
        const neg = std.fmt.bufPrint(&buf, "-{d}", .{count}) catch unreachable;

        self.mutex.lock();
        defer self.mutex.unlock();
        const v = try self.client.command(&.{ "SRANDMEMBER", key_index, neg });
        defer v.deinit(self.client.gpa);
        const items: []const resp.Value = switch (v) {
            .array => |a| if (a) |arr| arr else &[_]resp.Value{},
            else => &[_]resp.Value{},
        };
        return self.fetchMany(gpa, items);
    }

    /// 把一组 id（SMEMBERS/SRANDMEMBER 回复里的 bulk string 数组）逐个
    /// HGETALL 展开成 Quote 数组。只在 allQuotes/randomMany 内部调用，此时
    /// 锁已经被持有——理由同 fetchById。
    ///
    /// 清理纪律：`out` 从声明起就有 errdefer 兜底，覆盖已经成功 append 进
    /// `out` 的每个 Quote（各自持有七个独立分配的字符串）——`fetchById`
    /// 本身失败（Redis I/O/协议错误）时不会留下任何新孤儿，因为它要么整体
    /// 失败要么整体成功返回一个完整的 Quote，还没被 append 就跟着 try 直接
    /// 传播。
    ///
    /// 但 `q` 拿到手之后、成功 append 进 `out` 之前还有一个不算短的窗口：
    /// `out.append` 自己也会分配（扩容底层数组），也可能失败。这个失败点
    /// 不能用裸 `try out.append(gpa, q)`——那样 `q` 已经完整分配好的七个
    /// 字符串会在这一步失败时被孤儿化：它既不在 `out.items` 里（append 没有
    /// 成功），外层 errdefer 也就看不到它，于是在这条只有分配失败测试才会
    /// 走到的路径上泄漏（`checkAllAllocationFailures` 在这里真的抓到过：
    /// fail_index 落在 `out.append` 内部的扩容分配上，`q` 七个字段全部已经
    /// 分配完成却因为这一处裸 `try` 而丢失引用）。改成 `catch` 显式在同一处
    /// 释放 `q` 后再把错误传播出去，保证 append 失败的这一条也被释放恰好
    /// 一次，不依赖外层 errdefer 兜它。
    fn fetchMany(self: *Store, gpa: std.mem.Allocator, ids: []const resp.Value) Error![]Quote {
        var out: std.ArrayList(Quote) = .empty;
        errdefer {
            for (out.items) |q| q.deinit(gpa);
            out.deinit(gpa);
        }
        for (ids) |item| {
            const id_str = switch (item) {
                .bulk => |b| b orelse continue,
                else => continue,
            };
            if (try self.fetchById(gpa, id_str)) |q| {
                out.append(gpa, q) catch |e| {
                    q.deinit(gpa);
                    return e;
                };
            }
        }
        return out.toOwnedSlice(gpa);
    }
};

fn sampleQuote() Quote {
    return .{
        .id = 7,
        .uuid = "550e8400-e29b-41d4-a716-446655440000".*,
        .hitokoto = "今天也是好天气",
        .kind = "g",
        .from = "测试群",
        .from_who = "小明",
        .creator = "Hikari",
        .creator_uid = 0,
        .reviewer = 0,
        .commit_from = "hikari",
        .created_at = "1700000000",
        .length = 7,
        .message_id = 12345,
        .group_id = 999,
        .user_id = 10001,
    };
}

test "quoteKey 拼出正确的键名" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("hikari:quote:12345", quoteKey(&buf, 12345));
    try std.testing.expectEqualStrings("hikari:quote:-7", quoteKey(&buf, -7));
}

test "hashFields 产出 HSET 命令的完整参数，键值成对" {
    const gpa = std.testing.allocator;
    const args = try hashFields(gpa, sampleQuote());
    defer freeHashFields(gpa, args);

    try std.testing.expectEqualStrings("HSET", args[0]);
    try std.testing.expectEqualStrings("hikari:quote:12345", args[1]);
    // 命令名 + key + 成对的 field/value
    try std.testing.expectEqual(@as(usize, 0), (args.len - 2) % 2);

    // 抽查几个字段确实出现且值正确
    var i: usize = 2;
    var seen_hitokoto = false;
    var seen_length = false;
    while (i < args.len) : (i += 2) {
        if (std.mem.eql(u8, args[i], "hitokoto")) {
            try std.testing.expectEqualStrings("今天也是好天气", args[i + 1]);
            seen_hitokoto = true;
        }
        if (std.mem.eql(u8, args[i], "length")) {
            try std.testing.expectEqualStrings("7", args[i + 1]);
            seen_length = true;
        }
    }
    try std.testing.expect(seen_hitokoto);
    try std.testing.expect(seen_length);
}

test "hashFields 产出的 32 个参数与字面量逐一匹配（钉住字段名与顺序，尤其是 type）" {
    const gpa = std.testing.allocator;
    const args = try hashFields(gpa, sampleQuote());
    defer freeHashFields(gpa, args);

    // 这是线上协议：字段名（含 kind -> "type" 的翻译）、顺序、取值都钉死在这里，
    // 防止 quoteFromPairs 的 orelse 默认值把字段名写错这类改动悄悄溜过测试——
    // round-trip 测试只抽查了 7/15 个字段，剩下 8 个（包括 type 本身）全靠这里守住。
    const expected = [_][]const u8{
        "HSET",        "hikari:quote:12345",
        "id",          "7",
        "uuid",        "550e8400-e29b-41d4-a716-446655440000",
        "hitokoto",    "今天也是好天气",
        "type",        "g",
        "from",        "测试群",
        "from_who",    "小明",
        "creator",     "Hikari",
        "creator_uid", "0",
        "reviewer",    "0",
        "commit_from", "hikari",
        "created_at",  "1700000000",
        "length",      "7",
        "message_id",  "12345",
        "group_id",    "999",
        "user_id",     "10001",
    };
    try std.testing.expectEqual(expected.len, args.len);
    for (expected, args) |e, a| try std.testing.expectEqualStrings(e, a);
}

test "quoteFromPairs 还原 HGETALL 的扁平回复" {
    const gpa = std.testing.allocator;
    const args = try hashFields(gpa, sampleQuote());
    defer freeHashFields(gpa, args);

    // 把 args[2..] 包装成 resp.Value 的扁平数组，模拟 HGETALL
    var pairs: std.ArrayList(resp.Value) = .empty;
    defer {
        for (pairs.items) |p| p.deinit(gpa);
        pairs.deinit(gpa);
    }
    for (args[2..]) |s| try pairs.append(gpa, .{ .bulk = try gpa.dupe(u8, s) });

    var q = (try quoteFromPairs(gpa, pairs.items)).?;
    defer q.deinit(gpa);

    try std.testing.expectEqual(@as(u64, 7), q.id);
    try std.testing.expectEqualStrings("今天也是好天气", q.hitokoto);
    try std.testing.expectEqualStrings("测试群", q.from);
    try std.testing.expectEqualStrings("小明", q.from_who);
    try std.testing.expectEqual(@as(usize, 7), q.length);
    try std.testing.expectEqual(@as(i64, 12345), q.message_id);
    try std.testing.expectEqualStrings("550e8400-e29b-41d4-a716-446655440000", &q.uuid);
}

test "quoteFromPairs 遇到空回复返回 null" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(@as(?Quote, null), try quoteFromPairs(gpa, &.{}));
}

test "quoteFromPairs 缺少 hitokoto 字段时返回 null" {
    const gpa = std.testing.allocator;
    const pairs = [_]resp.Value{
        .{ .bulk = @constCast("id") },
        .{ .bulk = @constCast("1") },
    };
    try std.testing.expectEqual(@as(?Quote, null), try quoteFromPairs(gpa, &pairs));
}

test "quoteFromPairs 只有 hitokoto 时其余字段全部落到默认值" {
    const gpa = std.testing.allocator;
    const pairs = [_]resp.Value{
        .{ .bulk = @constCast("hitokoto") },
        .{ .bulk = @constCast("你好") },
    };
    var q = (try quoteFromPairs(gpa, &pairs)).?;
    defer q.deinit(gpa);

    try std.testing.expectEqualStrings("你好", q.hitokoto);
    try std.testing.expectEqualStrings("g", q.kind);
    try std.testing.expectEqualStrings("", q.from);
    try std.testing.expectEqualStrings("", q.from_who);
    try std.testing.expectEqualStrings("Hikari", q.creator);
    try std.testing.expectEqualStrings("hikari", q.commit_from);
    try std.testing.expectEqualStrings("0", q.created_at);
    for (q.uuid) |ch| try std.testing.expectEqual(@as(u8, '0'), ch);
    try std.testing.expectEqual(@as(u64, 0), q.id);
    try std.testing.expectEqual(@as(u64, 0), q.creator_uid);
    try std.testing.expectEqual(@as(u64, 0), q.reviewer);
    // 没有 length 字段时退化成对 hitokoto 按码点数计算的长度，Task 7 的
    // min_length/max_length 就是靠这条兜底路径处理没写 length 的旧数据。
    try std.testing.expectEqual(utf8Length("你好"), q.length);
    try std.testing.expectEqual(@as(i64, 0), q.message_id);
    try std.testing.expectEqual(@as(u64, 0), q.group_id);
    try std.testing.expectEqual(@as(u64, 0), q.user_id);
}

test "utf8Length 按码点数算长度" {
    try std.testing.expectEqual(@as(usize, 7), utf8Length("今天也是好天气"));
    try std.testing.expectEqual(@as(usize, 3), utf8Length("abc"));
    try std.testing.expectEqual(@as(usize, 1), utf8Length("✨"));
    try std.testing.expectEqual(@as(usize, 4), utf8Length("你好ab"));
    // 非法 UTF-8 退化为字节数，不崩
    try std.testing.expectEqual(@as(usize, 2), utf8Length("\xff\xfe"));
}

fn checkHashFieldsAlloc(gpa: std.mem.Allocator, q: Quote) !void {
    const args = try hashFields(gpa, q);
    freeHashFields(gpa, args);
}

test "hashFields 在分配失败时不泄漏（checkAllAllocationFailures）" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkHashFieldsAlloc, .{sampleQuote()});
}

fn checkQuoteFromPairsAlloc(gpa: std.mem.Allocator, pairs: []const resp.Value) !void {
    const q = try quoteFromPairs(gpa, pairs);
    if (q) |qq| qq.deinit(gpa);
}

test "quoteFromPairs 在分配失败时不泄漏（checkAllAllocationFailures）" {
    const gpa = std.testing.allocator;
    const args = try hashFields(gpa, sampleQuote());
    defer freeHashFields(gpa, args);

    var pairs: std.ArrayList(resp.Value) = .empty;
    defer {
        for (pairs.items) |p| p.deinit(gpa);
        pairs.deinit(gpa);
    }
    for (args[2..]) |s| try pairs.append(gpa, .{ .bulk = try gpa.dupe(u8, s) });

    try std.testing.checkAllAllocationFailures(gpa, checkQuoteFromPairsAlloc, .{pairs.items});
}

// ---------------------------------------------------------------------------
// Store：只测试它发出的命令序列对不对，沿用 Task 5 client.zig 测试里的
// FakeServer 思路——起一个本地监听，把预先写好的 RESP 回复脚本按顺序吐给客户端，
// 同时把客户端发来的字节收集下来，供测试断言用。

const FakeServer = struct {
    listener: std.net.Server,
    thread: std.Thread,
    script: []const u8,
    received: std.ArrayList(u8),
    gpa: std.mem.Allocator,
    stopped: bool,

    fn serve(self: *FakeServer) void {
        const conn = self.listener.accept() catch return;
        defer conn.stream.close();
        var buf: [4096]u8 = undefined;
        _ = conn.stream.writeAll(self.script) catch return;
        while (true) {
            const n = conn.stream.read(&buf) catch return;
            if (n == 0) return;
            self.received.appendSlice(self.gpa, buf[0..n]) catch return;
        }
    }

    fn start(gpa: std.mem.Allocator, script: []const u8) !*FakeServer {
        const self = try gpa.create(FakeServer);
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        self.* = .{
            .listener = try addr.listen(.{ .reuse_address = true }),
            .thread = undefined,
            .script = script,
            .received = .empty,
            .gpa = gpa,
            .stopped = false,
        };
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    fn port(self: *FakeServer) u16 {
        return self.listener.listen_address.getPort();
    }

    fn stop(self: *FakeServer) void {
        if (self.stopped) return;
        self.stopped = true;
        self.listener.deinit();
        self.thread.join();
    }
};

/// 把 args[skip..] 编码成一段 RESP bulk-string 数组回复，字节布局与
/// `resp.encodeCommand` 完全相同（都是 `*N\r\n$len\r\nval\r\n...`），
/// 用来伪造 HGETALL 的数组回复。
fn encodeArrayReply(gpa: std.mem.Allocator, items: []const []const u8) ![]u8 {
    return resp.encodeCommand(gpa, items);
}

/// 按给定顺序在 `bytes` 里逐帧定位：每一帧都必须存在，且必须出现在前一帧之后。
///
/// 断言的是**完整连续的 RESP 命令帧**，不是命令名子串。只查命令名的话，帧内
/// 参数换位（比如 ZADD 的 score/member 对调、SREM 打到了 bylen 上）照样全部
/// 通过；写库顺序本身是这两个函数的正确性所在（哪一步先落盘决定了部分失败会
/// 留下什么状态），所以顺序也必须一起钉死。
fn expectFrameSequence(bytes: []const u8, frames: []const []const u8) !void {
    var at: usize = 0;
    for (frames) |f| {
        const idx = std.mem.indexOfPos(u8, bytes, at, f) orelse {
            std.debug.print("missing or out-of-order RESP frame: {s}\n", .{f});
            return error.TestUnexpectedResult;
        };
        at = idx + f.len;
    }
}

test "nextId 发 INCR hikari:seq 并返回结果" {
    const gpa = std.testing.allocator;
    const srv = try FakeServer.start(gpa, ":5\r\n");
    defer {
        srv.stop();
        srv.received.deinit(gpa);
        gpa.destroy(srv);
    }
    var c = try redis.Client.connect(gpa, "127.0.0.1", srv.port(), null, 0);
    defer c.deinit();
    var store = Store.init(gpa, &c);

    try std.testing.expectEqual(@as(u64, 5), try store.nextId());

    c.deinit();
    srv.stop();
    try std.testing.expect(std.mem.indexOf(u8, srv.received.items, "INCR") != null);
    try std.testing.expect(std.mem.indexOf(u8, srv.received.items, key_seq) != null);
}

test "exists 发 SISMEMBER hikari:index 并解读结果" {
    const gpa = std.testing.allocator;
    {
        const srv = try FakeServer.start(gpa, ":1\r\n");
        defer {
            srv.stop();
            srv.received.deinit(gpa);
            gpa.destroy(srv);
        }
        var c = try redis.Client.connect(gpa, "127.0.0.1", srv.port(), null, 0);
        defer c.deinit();
        var store = Store.init(gpa, &c);
        try std.testing.expect(try store.exists(12345));
        c.deinit();
        srv.stop();
        try std.testing.expect(std.mem.indexOf(u8, srv.received.items, "SISMEMBER") != null);
        try std.testing.expect(std.mem.indexOf(u8, srv.received.items, key_index) != null);
        try std.testing.expect(std.mem.indexOf(u8, srv.received.items, "12345") != null);
    }
    {
        const srv = try FakeServer.start(gpa, ":0\r\n");
        defer {
            srv.stop();
            srv.received.deinit(gpa);
            gpa.destroy(srv);
        }
        var c = try redis.Client.connect(gpa, "127.0.0.1", srv.port(), null, 0);
        defer c.deinit();
        var store = Store.init(gpa, &c);
        try std.testing.expect(!try store.exists(12345));
    }
}

test "isTombstoned 发 SISMEMBER hikari:tomb" {
    const gpa = std.testing.allocator;
    const srv = try FakeServer.start(gpa, ":1\r\n");
    defer {
        srv.stop();
        srv.received.deinit(gpa);
        gpa.destroy(srv);
    }
    var c = try redis.Client.connect(gpa, "127.0.0.1", srv.port(), null, 0);
    defer c.deinit();
    var store = Store.init(gpa, &c);
    try std.testing.expect(try store.isTombstoned(999));
    c.deinit();
    srv.stop();
    try std.testing.expect(std.mem.indexOf(u8, srv.received.items, "SISMEMBER") != null);
    try std.testing.expect(std.mem.indexOf(u8, srv.received.items, key_tomb) != null);
}

test "add 依次发 HSET / ZADD / SADD —— hikari:index 是提交点" {
    const gpa = std.testing.allocator;
    const srv = try FakeServer.start(gpa, ":15\r\n:1\r\n:1\r\n");
    defer {
        srv.stop();
        srv.received.deinit(gpa);
        gpa.destroy(srv);
    }
    var c = try redis.Client.connect(gpa, "127.0.0.1", srv.port(), null, 0);
    defer c.deinit();
    var store = Store.init(gpa, &c);

    try store.add(sampleQuote());

    c.deinit();
    srv.stop();

    // 顺序不是随便定的：exists() 查的是 hikari:index，所以 SADD 必须是最后
    // 一步，这样任何一次部分失败留下的状态都满足 exists() == false，下一次
    // 扫描会原样重做一遍（HSET/ZADD/SADD 都幂等）。反过来把 SADD 放在 ZADD
    // 前面的话，"HSET+SADD 成功、ZADD 失败" 会让这条语录 exists() == true，
    // 从此每次扫描都跳过它，而它永远进不了 hikari:bylen——GET / 能随机到，
    // 任何带 min_length/max_length 的查询都永远看不见，且不会自愈。
    try expectFrameSequence(srv.received.items, &.{
        "*32\r\n$4\r\nHSET\r\n$18\r\nhikari:quote:12345\r\n",
        "*4\r\n$4\r\nZADD\r\n$12\r\nhikari:bylen\r\n$1\r\n7\r\n$5\r\n12345\r\n",
        "*3\r\n$4\r\nSADD\r\n$12\r\nhikari:index\r\n$5\r\n12345\r\n",
    });
}

test "revoke 依次发 SADD tomb / SREM / ZREM / DEL —— tombstone 先落盘" {
    const gpa = std.testing.allocator;
    const srv = try FakeServer.start(gpa, ":1\r\n:1\r\n:1\r\n:1\r\n");
    defer {
        srv.stop();
        srv.received.deinit(gpa);
        gpa.destroy(srv);
    }
    var c = try redis.Client.connect(gpa, "127.0.0.1", srv.port(), null, 0);
    defer c.deinit();
    var store = Store.init(gpa, &c);

    try store.revoke(12345);

    c.deinit();
    srv.stop();

    // tombstone 是这次作废唯一持久的事实：它一旦落盘，即使后面三步全失败，
    // 下一次扫描的 isTombstoned 也会挡住重新入库，而运营方看到的是"还能查到
    // 这条语录"这种可见、可重试的故障。反过来先 DEL 再 SREM 的话，DEL 成功、
    // SREM 失败会在 hikari:index 里留下一个没有 hash 的悬空 id：randomAny
    // 抽中它，HGETALL 回空，非空库对外返回 404，而且永远不会自愈。
    try expectFrameSequence(srv.received.items, &.{
        "*3\r\n$4\r\nSADD\r\n$11\r\nhikari:tomb\r\n$5\r\n12345\r\n",
        "*3\r\n$4\r\nSREM\r\n$12\r\nhikari:index\r\n$5\r\n12345\r\n",
        "*3\r\n$4\r\nZREM\r\n$12\r\nhikari:bylen\r\n$5\r\n12345\r\n",
        "*2\r\n$3\r\nDEL\r\n$18\r\nhikari:quote:12345\r\n",
    });
}

test "setLastRun 发 SET hikari:lastrun:{group_id}，按群区分键" {
    const gpa = std.testing.allocator;
    const srv = try FakeServer.start(gpa, "+OK\r\n");
    defer {
        srv.stop();
        srv.received.deinit(gpa);
        gpa.destroy(srv);
    }
    var c = try redis.Client.connect(gpa, "127.0.0.1", srv.port(), null, 0);
    defer c.deinit();
    var store = Store.init(gpa, &c);
    try store.setLastRun(12345, 1700000000);
    c.deinit();
    srv.stop();

    // 断言完整连续帧，不是三段独立的子串存在性检查：这个仓库之前有一轮review
    // 发现独立的 indexOf 检查会让参数换位（比如 group_id 和 ts 对调）悄悄通过。
    try expectFrameSequence(srv.received.items, &.{
        "*3\r\n$3\r\nSET\r\n$20\r\nhikari:lastrun:12345\r\n$10\r\n1700000000\r\n",
    });
}

test "getLastRun 读到值时解析出来，nil 时返回 null；键按 group_id 区分" {
    const gpa = std.testing.allocator;
    {
        const srv = try FakeServer.start(gpa, "$10\r\n1700000000\r\n");
        defer {
            srv.stop();
            srv.received.deinit(gpa);
            gpa.destroy(srv);
        }
        var c = try redis.Client.connect(gpa, "127.0.0.1", srv.port(), null, 0);
        defer c.deinit();
        var store = Store.init(gpa, &c);
        try std.testing.expectEqual(@as(?i64, 1700000000), try store.getLastRun(12345));
        c.deinit();
        srv.stop();
        try expectFrameSequence(srv.received.items, &.{
            "*2\r\n$3\r\nGET\r\n$20\r\nhikari:lastrun:12345\r\n",
        });
    }
    {
        const srv = try FakeServer.start(gpa, "$-1\r\n");
        defer {
            srv.stop();
            srv.received.deinit(gpa);
            gpa.destroy(srv);
        }
        var c = try redis.Client.connect(gpa, "127.0.0.1", srv.port(), null, 0);
        defer c.deinit();
        var store = Store.init(gpa, &c);
        try std.testing.expectEqual(@as(?i64, null), try store.getLastRun(999));
        c.deinit();
        srv.stop();
        try expectFrameSequence(srv.received.items, &.{
            "*2\r\n$3\r\nGET\r\n$18\r\nhikari:lastrun:999\r\n",
        });
    }
}

test "randomAny 用 SRANDMEMBER 拿 id 再 HGETALL 取回整条语录" {
    const gpa = std.testing.allocator;
    const args = try hashFields(gpa, sampleQuote());
    defer freeHashFields(gpa, args);
    const hgetall_reply = try encodeArrayReply(gpa, args[2..]);
    defer gpa.free(hgetall_reply);

    const script = try std.mem.concat(gpa, u8, &.{ "$5\r\n12345\r\n", hgetall_reply });
    defer gpa.free(script);

    const srv = try FakeServer.start(gpa, script);
    defer {
        srv.stop();
        srv.received.deinit(gpa);
        gpa.destroy(srv);
    }
    var c = try redis.Client.connect(gpa, "127.0.0.1", srv.port(), null, 0);
    defer c.deinit();
    var store = Store.init(gpa, &c);

    var q = (try store.randomAny(gpa)).?;
    defer q.deinit(gpa);
    try std.testing.expectEqualStrings("今天也是好天气", q.hitokoto);
    try std.testing.expectEqual(@as(i64, 12345), q.message_id);

    c.deinit();
    srv.stop();
    try std.testing.expect(std.mem.indexOf(u8, srv.received.items, "SRANDMEMBER") != null);
    try std.testing.expect(std.mem.indexOf(u8, srv.received.items, key_index) != null);
    try std.testing.expect(std.mem.indexOf(u8, srv.received.items, "HGETALL") != null);
    try std.testing.expect(std.mem.indexOf(u8, srv.received.items, "hikari:quote:12345") != null);
}

test "randomAny 索引为空时返回 null，不再发 HGETALL" {
    const gpa = std.testing.allocator;
    const srv = try FakeServer.start(gpa, "$-1\r\n");
    defer {
        srv.stop();
        srv.received.deinit(gpa);
        gpa.destroy(srv);
    }
    var c = try redis.Client.connect(gpa, "127.0.0.1", srv.port(), null, 0);
    defer c.deinit();
    var store = Store.init(gpa, &c);

    try std.testing.expectEqual(@as(?Quote, null), try store.randomAny(gpa));

    c.deinit();
    srv.stop();
    try std.testing.expect(std.mem.indexOf(u8, srv.received.items, "SRANDMEMBER") != null);
    try std.testing.expect(std.mem.indexOf(u8, srv.received.items, "HGETALL") == null);
}

test "randomByLength 用 ZRANGEBYSCORE 拿候选再 HGETALL 取回整条语录" {
    const gpa = std.testing.allocator;
    const args = try hashFields(gpa, sampleQuote());
    defer freeHashFields(gpa, args);
    const hgetall_reply = try encodeArrayReply(gpa, args[2..]);
    defer gpa.free(hgetall_reply);

    const script = try std.mem.concat(gpa, u8, &.{ "*1\r\n$5\r\n12345\r\n", hgetall_reply });
    defer gpa.free(script);

    const srv = try FakeServer.start(gpa, script);
    defer {
        srv.stop();
        srv.received.deinit(gpa);
        gpa.destroy(srv);
    }
    var c = try redis.Client.connect(gpa, "127.0.0.1", srv.port(), null, 0);
    defer c.deinit();
    var store = Store.init(gpa, &c);

    var q = (try store.randomByLength(gpa, 5, 10)).?;
    defer q.deinit(gpa);
    try std.testing.expectEqualStrings("今天也是好天气", q.hitokoto);

    c.deinit();
    srv.stop();
    // 不能分别独立查 "ZRANGEBYSCORE" / key / "$1\r\n5\r\n" / "$2\r\n10\r\n"
    // 是否存在：min/max 被换位成 "... 10 5" 时，四段子串依然全部存在，
    // 只是相对顺序变了，四条独立的 indexOf 会全部通过，测不出换位。
    // 改成断言整条命令帧——命令名、key、min、max 的相对位置一起钉死在一个
    // 连续字节串里，换位会让这个字节串在整个流里都找不到。帧内容照抄
    // resp.encodeCommand 的编码格式："*{参数个数}\r\n" + 每个参数
    // "${长度}\r\n{内容}\r\n"，参数依次是 ZRANGEBYSCORE、
    // key_bylen（"hikari:bylen"，12 字节）、"5"（1 字节）、"10"（2 字节），
    // 共 4 个参数。
    try std.testing.expect(std.mem.indexOf(
        u8,
        srv.received.items,
        "*4\r\n$13\r\nZRANGEBYSCORE\r\n$12\r\nhikari:bylen\r\n$1\r\n5\r\n$2\r\n10\r\n",
    ) != null);
}

test "randomByLength 候选为空数组时返回 null" {
    const gpa = std.testing.allocator;
    const srv = try FakeServer.start(gpa, "*0\r\n");
    defer {
        srv.stop();
        srv.received.deinit(gpa);
        gpa.destroy(srv);
    }
    var c = try redis.Client.connect(gpa, "127.0.0.1", srv.port(), null, 0);
    defer c.deinit();
    var store = Store.init(gpa, &c);
    try std.testing.expectEqual(@as(?Quote, null), try store.randomByLength(gpa, 1, 100));
}

// ---------------------------------------------------------------------------
// allQuotes / randomMany —— `/extra/all` 与 `/extra/batch/:count` 的存储层。

test "allQuotes 用 SMEMBERS 拿全部 id 再逐个 HGETALL 展开" {
    const gpa = std.testing.allocator;
    var q2 = sampleQuote();
    q2.message_id = 999;
    q2.hitokoto = "第二条语录";
    q2.length = 5;

    const args1 = try hashFields(gpa, sampleQuote());
    defer freeHashFields(gpa, args1);
    const args2 = try hashFields(gpa, q2);
    defer freeHashFields(gpa, args2);
    const h1 = try encodeArrayReply(gpa, args1[2..]);
    defer gpa.free(h1);
    const h2 = try encodeArrayReply(gpa, args2[2..]);
    defer gpa.free(h2);
    const smembers = try encodeArrayReply(gpa, &.{ "12345", "999" });
    defer gpa.free(smembers);

    const script = try std.mem.concat(gpa, u8, &.{ smembers, h1, h2 });
    defer gpa.free(script);

    const srv = try FakeServer.start(gpa, script);
    defer {
        srv.stop();
        srv.received.deinit(gpa);
        gpa.destroy(srv);
    }
    var c = try redis.Client.connect(gpa, "127.0.0.1", srv.port(), null, 0);
    defer c.deinit();
    var store = Store.init(gpa, &c);

    const quotes = try store.allQuotes(gpa);
    defer {
        for (quotes) |q| q.deinit(gpa);
        gpa.free(quotes);
    }
    try std.testing.expectEqual(@as(usize, 2), quotes.len);
    try std.testing.expectEqualStrings("今天也是好天气", quotes[0].hitokoto);
    try std.testing.expectEqualStrings("第二条语录", quotes[1].hitokoto);

    c.deinit();
    srv.stop();
    try std.testing.expect(std.mem.indexOf(u8, srv.received.items, "SMEMBERS") != null);
    try std.testing.expect(std.mem.indexOf(u8, srv.received.items, key_index) != null);
    try std.testing.expect(std.mem.indexOf(u8, srv.received.items, "hikari:quote:12345") != null);
    try std.testing.expect(std.mem.indexOf(u8, srv.received.items, "hikari:quote:999") != null);
}

test "allQuotes 库空时返回长度为 0 的数组（不是 null）" {
    const gpa = std.testing.allocator;
    // SMEMBERS 在空集合上回一个空数组（`*0\r\n`），不是 nil——`hikari:index`
    // 本身要么不存在（Redis 对不存在的 key 做 SMEMBERS 就是空数组）要么存在
    // 但为空，两种情况在协议层都是同一种回复。
    const srv = try FakeServer.start(gpa, "*0\r\n");
    defer {
        srv.stop();
        srv.received.deinit(gpa);
        gpa.destroy(srv);
    }
    var c = try redis.Client.connect(gpa, "127.0.0.1", srv.port(), null, 0);
    defer c.deinit();
    var store = Store.init(gpa, &c);

    const quotes = try store.allQuotes(gpa);
    defer gpa.free(quotes);
    try std.testing.expectEqual(@as(usize, 0), quotes.len);
}

test "randomMany 发 SRANDMEMBER 的负数形式（允许重复），命令帧钉死符号" {
    const gpa = std.testing.allocator;
    const args = try hashFields(gpa, sampleQuote());
    defer freeHashFields(gpa, args);
    const h = try encodeArrayReply(gpa, args[2..]);
    defer gpa.free(h);

    // count=3，让同一个 id 在 SRANDMEMBER 回复里重复出现三次——真实 Redis
    // 的负数形式就是这样（允许重复），验证 fetchMany 老老实实按回复出现
    // 的次数逐条 HGETALL，不会因为 id 相同就去重合并成一条。
    const srandmember = try encodeArrayReply(gpa, &.{ "12345", "12345", "12345" });
    defer gpa.free(srandmember);
    const script = try std.mem.concat(gpa, u8, &.{ srandmember, h, h, h });
    defer gpa.free(script);

    const srv = try FakeServer.start(gpa, script);
    defer {
        srv.stop();
        srv.received.deinit(gpa);
        gpa.destroy(srv);
    }
    var c = try redis.Client.connect(gpa, "127.0.0.1", srv.port(), null, 0);
    defer c.deinit();
    var store = Store.init(gpa, &c);

    const quotes = try store.randomMany(gpa, 3);
    defer {
        for (quotes) |q| q.deinit(gpa);
        gpa.free(quotes);
    }
    try std.testing.expectEqual(@as(usize, 3), quotes.len);

    c.deinit();
    srv.stop();
    // 符号是这条命令唯一容易搞反、又不会被普通子串检查抓到的地方：搞反成
    // 正数形式（"3"）会让 Redis 走去重语义，在 count 超过库大小时还会静默
    // 截断到库大小——两种情况普通测试都可能"恰好"通过。这里钉死完整帧，
    // 命令名、key、"-3" 三段的相对顺序与内容一起验证。
    try std.testing.expect(std.mem.indexOf(
        u8,
        srv.received.items,
        "*3\r\n$11\r\nSRANDMEMBER\r\n$12\r\nhikari:index\r\n$2\r\n-3\r\n",
    ) != null);
}

test "randomMany 库空时返回长度为 0 的数组" {
    const gpa = std.testing.allocator;
    const srv = try FakeServer.start(gpa, "*0\r\n");
    defer {
        srv.stop();
        srv.received.deinit(gpa);
        gpa.destroy(srv);
    }
    var c = try redis.Client.connect(gpa, "127.0.0.1", srv.port(), null, 0);
    defer c.deinit();
    var store = Store.init(gpa, &c);

    const quotes = try store.randomMany(gpa, 5);
    defer gpa.free(quotes);
    try std.testing.expectEqual(@as(usize, 0), quotes.len);
}

/// checkAllAllocationFailures 专用：`gpa` 是被注入失败的 allocator，只应该
/// 覆盖 `store.allQuotes` 本身"逐条 HGETALL 展开成 Quote 数组"这条路径——
/// 这正是本仓库缺陷史里点名的那类：一条语录内部有七个独立分配的字符串，
/// N 条语录里任意一条、任意一个字段的分配失败，前面已经 append 进 out 的
/// 每一条都必须被释放恰好一次，不多不少。
///
/// 网络层（FakeServer 的服务线程、redis.Client 的连接/读写缓冲、RESP 回复
/// 解码用的 `client.gpa`）全部改用 `std.testing.allocator`（`net_gpa`，不参与
/// 失败注入），原因有两条：一是 FakeServer 的服务线程与本线程会并发调用
/// 同一个 allocator，`std.testing.FailingAllocator` 的失败计数不是为并发
/// 访问设计的，混用会让失败点落不到确定的分配上，测试变得不确定；二是
/// 这里想测的是 `allQuotes` 自己的清理纪律，网络层的分配失败路径已经在
/// `redis/client.zig` 和本文件别处测过，不需要在这里重复覆盖。
fn checkAllQuotesAlloc(gpa: std.mem.Allocator) !void {
    const net_gpa = std.testing.allocator;

    var q2 = sampleQuote();
    q2.message_id = 999;
    q2.hitokoto = "第二条语录";
    q2.length = 5;

    const args1 = try hashFields(net_gpa, sampleQuote());
    defer freeHashFields(net_gpa, args1);
    const args2 = try hashFields(net_gpa, q2);
    defer freeHashFields(net_gpa, args2);
    const h1 = try encodeArrayReply(net_gpa, args1[2..]);
    defer net_gpa.free(h1);
    const h2 = try encodeArrayReply(net_gpa, args2[2..]);
    defer net_gpa.free(h2);
    const smembers = try encodeArrayReply(net_gpa, &.{ "12345", "999" });
    defer net_gpa.free(smembers);

    const script = try std.mem.concat(net_gpa, u8, &.{ smembers, h1, h2 });
    defer net_gpa.free(script);

    const srv = try FakeServer.start(net_gpa, script);
    defer {
        srv.stop();
        srv.received.deinit(net_gpa);
        net_gpa.destroy(srv);
    }
    var c = try redis.Client.connect(net_gpa, "127.0.0.1", srv.port(), null, 0);
    defer c.deinit();
    var st = Store.init(net_gpa, &c);

    const quotes = try st.allQuotes(gpa);
    for (quotes) |q| q.deinit(gpa);
    gpa.free(quotes);
}

test "allQuotes 在多条语录构建过程中任意一步分配失败都不泄漏、不重复释放（checkAllAllocationFailures）" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkAllQuotesAlloc, .{});
}
