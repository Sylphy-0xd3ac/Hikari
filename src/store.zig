const std = @import("std");
const redis = @import("redis/client.zig");
const resp = @import("redis/resp.zig");

pub const Error = redis.Error || error{OutOfMemory};

pub const key_index = "hikari:index";
pub const key_bylen = "hikari:bylen";
pub const key_tomb = "hikari:tomb";
pub const key_seq = "hikari:seq";
pub const key_lastrun_prefix = "hikari:lastrun";
/// `hikari:chainmember:{message_id}` STRING，value 是这条 🔥 链主键（第一个
/// 成员）的 message_id。链的**每一个**成员——包括主键自己——都写一份，值都是
/// 同一个主键。这是 revoke() 用来跨扫描窗口解析"这个 id 属不属于某条链"的
/// 持久映射：rules.classify 的 chainOf 只能在当次窗口重建出的链里查找，💦
/// 引用的目标若来自缓冲池或 get_msg 回补（窗口外），chainOf 必然返回 null；
/// 这份映射把"成员 → 链主键"这件事写进 Redis，脱离窗口也能查。
pub const key_chainmember_prefix = "hikari:chainmember";
/// `hikari:chain:{primary_message_id}` SET，成员是这条链的全部 message_id
/// （含主键自己）。revoke() 撤一条链时先靠 chainmember 映射拿到主键，再靠
/// 这个 SET 拿到全部成员，逐个 tombstone。
pub const key_chain_prefix = "hikari:chain";
/// `hikari:username:{user_id}` STRING，这个人当前的群名片（群名片优先，
/// 否则昵称）快照。`scan/runner.zig` 的 `authorCard` 在每次扫描里按**遇到的
/// 作者**（不是固定的被观察者）刷新它——群名片会改，语录 hash 里冻结的
/// `from_who` 不会。渲染语录时（`fetchById`/`resolveDisplayNames`）用这个键
/// 覆盖 hash 里的旧值，让一次改名同时反映到这个人说过的全部历史语录上；
/// 这个键缺失（GET/MGET 回 nil）——从未被某次扫描当过候选作者、这个人已经
/// 离群且从来没成功刷新过、或者语录是 `import` 写进来的——渲染时落回 hash
/// 里存的旧值，见 `resolveDisplayNames` 顶部的完整说明。
pub const key_username_prefix = "hikari:username";
/// `hikari:groupname:{group_id}` STRING，这个群当前的群名快照，用法和理由
/// 跟 `key_username_prefix` 对称，只是覆盖的字段是 `from` 而不是 `from_who`。
pub const key_groupname_prefix = "hikari:groupname";
/// `hikari:byuser:{user_id}` ZSET，score = 语录长度（UTF-8 码点数），member =
/// `message_id`（🔥 链只有主键在里面，跟 `hikari:bylen` 完全对称）。作者维度
/// 的索引，`/?user_id=` 在全部三个端点上都靠它。
///
/// 为什么是 ZSET 不是 SET：`user_id` 需要能跟 `min_length`/`max_length`
/// 组合过滤。ZSET 让"这个人 + 长度区间"和"全库 + 长度区间"是同一条
/// `ZRANGEBYSCORE key min max`，只是 key 换了——组合过滤因此不是一条单独
/// 维护的代码路径，见 `Filter`/`rangeKeyLocked`。
///
/// 写入顺序（`add`/`addChain`）：跟 `hikari:bylen` 同一段，在
/// `SADD hikari:index`（提交点）之前——任何一步部分失败都仍然满足
/// `exists() == false`，下一次扫描原样重做即可（ZADD 幂等）。放到提交点
/// 之后会出现"语录已提交、但 `/?user_id=` 永远查不到它"这种不会自愈的偏差。
///
/// 撤稿（`revoke`）：`message_id` 本身不带 `user_id`，`revokeSingleLocked`/
/// `revokeChainLocked` 靠 `quoteUserIdLocked`（`HGET hikari:quote:{id}
/// user_id`）在 `DEL` 之前把作者问出来，再对这个人的 ZSET 发一次
/// `ZREM`——问不到（hash 已经不存在、或者压根没有这个字段）就跳过，不是
/// 错误，跟 `SREM index`/`ZREM bylen` 对非主键链成员的处理一样，是无害
/// 空操作。
///
/// **136 条现存生产语录不在任何 `hikari:byuser` 里，修复手段是
/// `hikari reindex`（`reindexByUser`）**：这些语录早于这份索引存在，
/// `hikari:index`/`hikari:bylen` 从收录当时就写好了，但 `hikari:byuser`
/// 是全新的键，历史数据当然不会自己出现在一个当初根本不存在的索引里。
///
/// **后果是整体性的**：这 136 条同属一个作者（上线之前只观察一个人），
/// 所以在 `reindex` 跑之前，`/?user_id=` 这个过滤器对**整个存量语录库**
/// 都是空的——不是"有些作者查得到、有些查不到"，而是这个参数对上线前的
/// 全部语录一律返回"这个人没有语录"（`/` 404，`/extra/*` 返回 `[]`），
/// 即使这个人明明说过话、语录也明明能被 `GET /` 随机到。它们仍然完整地
/// 存在于 `hikari:index`/`hikari:bylen`，`GET /`、`/extra/all`、
/// `/extra/batch/:count` 在不带 `user_id` 时行为完全不变。
///
/// **"重新收录一遍就好"是一条假建议**（这里以前真的这么写过）：扫描器与
/// `hikari import` 都在 `Store.exists()` 那道关卡上就 `return` 了，
/// `add()`/`addChain()` 根本走不到，重放多少次都不会补上索引。本仓库
/// "状态修复只靠幂等重放"这条原则在这里恰恰失效——幂等重放的入口本身被
/// `exists()` 挡死了。所以必须另有一条**只回填索引、不改动语录本身**的
/// 路径，那就是 `reindexByUser`：`SMEMBERS hikari:index` → 逐 id
/// `HMGET hikari:quote:{id} user_id length` → `ZADD hikari:byuser:{uid}
/// {length} {id}`，纯读加纯索引写，幂等、可重复跑。
///
/// 它仍然**不自动跑**：进程启动不跑，定时扫描不跑，读路径更不会顺手写
/// 一笔。当初拒绝做迁移的理由（"读路径悄悄触发写"、"启动时多一个隐藏
/// 步骤"都会引入新状态机）原样成立——一条只由运营方显式敲的子命令新增
/// 的状态机是零。
pub const key_byuser_prefix = "hikari:byuser";

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

pub fn chainMemberKey(buf: *[64]u8, message_id: i64) []const u8 {
    return std.fmt.bufPrint(buf, "{s}:{d}", .{ key_chainmember_prefix, message_id }) catch unreachable;
}

pub fn chainKey(buf: *[64]u8, message_id: i64) []const u8 {
    return std.fmt.bufPrint(buf, "{s}:{d}", .{ key_chain_prefix, message_id }) catch unreachable;
}

pub fn usernameKey(buf: *[64]u8, user_id: u64) []const u8 {
    return std.fmt.bufPrint(buf, "{s}:{d}", .{ key_username_prefix, user_id }) catch unreachable;
}

pub fn groupNameKey(buf: *[64]u8, group_id: u64) []const u8 {
    return std.fmt.bufPrint(buf, "{s}:{d}", .{ key_groupname_prefix, group_id }) catch unreachable;
}

pub fn byUserKey(buf: *[64]u8, user_id: u64) []const u8 {
    return std.fmt.bufPrint(buf, "{s}:{d}", .{ key_byuser_prefix, user_id }) catch unreachable;
}

/// 读取端的过滤条件，三个 HTTP 端点（`/`、`/extra/all`、
/// `/extra/batch/:count`）共用同一个结构，避免"某个端点漏接了某个过滤
/// 参数"这类只在某一条路径上出现的偏差。
///
/// 全空（`isUnfiltered`）时，`randomFiltered`/`allFiltered`/
/// `randomManyFiltered` 分别委托给改动前就有的 `randomAny`/`randomByLength`/
/// `allQuotes`/`randomMany`，命令序列跟改动前逐字节相同；一旦带上任何一项
/// （`user_id` 和/或长度），就统一走一条 `ZRANGEBYSCORE {key} {min} {max}`：
/// `user_id` 决定用哪个 ZSET（`hikari:byuser:{u}` 还是全库的
/// `hikari:bylen`），长度决定 score 区间。组合与单项因此是同一条代码
/// 路径，不存在"组合起来没人测过"的分支。
pub const Filter = struct {
    user_id: ?u64 = null,
    min_length: ?usize = null,
    max_length: ?usize = null,

    pub fn isUnfiltered(self: Filter) bool {
        return self.user_id == null and self.min_length == null and self.max_length == null;
    }

    fn minScore(self: Filter) usize {
        return self.min_length orelse 0;
    }

    fn maxScore(self: Filter) usize {
        return self.max_length orelse std.math.maxInt(u32);
    }
};

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

/// 把一组 i64 id 格式化成新分配的十进制字符串数组，用来拼进变长的 Redis 命令
/// （链的 SADD/SREM/ZREM 需要一次性带上全部成员）。用 freeIdStrings 释放。
///
/// 清理纪律跟 hashFields 同一套：`out` 本身与已经成功格式化的每个元素都有
/// errdefer 兜底，任何一步 allocPrint/alloc 失败都不会孤儿化前面已经分配好
/// 的字符串。
fn formatIds(gpa: std.mem.Allocator, ids: []const i64) ![][]const u8 {
    const out = try gpa.alloc([]const u8, ids.len);
    errdefer gpa.free(out);
    var filled: usize = 0;
    errdefer for (out[0..filled]) |s| gpa.free(s);
    for (ids, 0..) |id, i| {
        out[i] = try std.fmt.allocPrint(gpa, "{d}", .{id});
        filled = i + 1;
    }
    return out;
}

fn freeIdStrings(gpa: std.mem.Allocator, strs: [][]const u8) void {
    for (strs) |s| gpa.free(s);
    gpa.free(strs);
}

/// 拼一条 `<cmd> <key> <member...>` 命令的完整参数数组。`cmd`/`key` 是借用的
/// 字符串字面量或调用方持有的缓冲区，`members` 是调用方已经拥有的字符串——
/// 这个函数只分配容纳指针的外层数组，不复制/不接管任何字符串本身的所有权，
/// 所以只需要 `gpa.free(返回值)`，不需要遍历释放元素。
fn buildMultiArgs(gpa: std.mem.Allocator, cmd: []const u8, key: []const u8, members: []const []const u8) ![][]const u8 {
    const args = try gpa.alloc([]const u8, 2 + members.len);
    args[0] = cmd;
    args[1] = key;
    for (members, 0..) |m, i| args[2 + i] = m;
    return args;
}

/// MGET 回复里一个元素的 bulk string，nil 与非 bulk 类型统一折叠成 null——
/// `resolveDisplayNames` 靠这个区分"这个键真的存在（哪怕值是空串）"与
/// "这个键压根没写过"。
fn bulkOrNull(v: resp.Value) ?[]const u8 {
    return switch (v) {
        .bulk => |b| b,
        else => null,
    };
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

/// `hikari reindex` 一次运行的结果。`seen` 是 `SMEMBERS hikari:index` 回来的
/// 成员数，`reindexed` 是真的发出了 `ZADD hikari:byuser:{user_id}` 的条数，
/// 其余四个是各自的跳过原因——分开计数而不是合成一个 skipped，是因为它们
/// 指向完全不同的排查方向：`bad_id` 是索引里混进了不是 message_id 的东西，
/// `missing_hash` 是索引里的悬空 id（语录 hash 已经不在了），另外两个是
/// hash 在、但缺了建索引必需的字段。
pub const ReindexSummary = struct {
    seen: usize = 0,
    reindexed: usize = 0,
    /// `hikari:index` 的成员不是一个能解析成 message_id 的整数。
    bad_id: usize = 0,
    /// `HMGET` 的两个字段都是 nil：hash 整个不存在（悬空 id），或者两个
    /// 字段都没写过。HMGET 分不出这两种情形，对这条命令来说也不需要分。
    missing_hash: usize = 0,
    /// hash 在，但 `user_id` 缺失或不是数字——不知道该记进谁的 ZSET。
    missing_user_id: usize = 0,
    /// hash 在，但 `length` 缺失或不是数字——不知道 score 该写多少。
    missing_length: usize = 0,

    pub fn skipped(self: ReindexSummary) usize {
        return self.bad_id + self.missing_hash + self.missing_user_id + self.missing_length;
    }
};

pub fn formatReindexSummary(gpa: std.mem.Allocator, s: ReindexSummary) ![]u8 {
    return std.fmt.allocPrint(gpa,
        \\Saw {d} member(s) in hikari:index.
        \\Reindexed {d} into hikari:byuser, skipped {d} (malformed index member {d}, no quote hash {d}, no user_id {d}, no length {d}).
        \\
    , .{
        s.seen,
        s.reindexed,
        s.skipped(),
        s.bad_id,
        s.missing_hash,
        s.missing_user_id,
        s.missing_length,
    });
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
        var ubuf: [64]u8 = undefined;

        self.mutex.lock();
        defer self.mutex.unlock();
        // 顺序即事务语义：exists() 查的是 hikari:index，所以 SADD 是提交点，
        // 必须最后发。这样几种部分失败（只有 HSET 成功 / HSET+ZADD(bylen)
        // 成功 / HSET+ZADD(bylen)+ZADD(byuser) 成功）留下的状态都满足
        // exists() == false，下一次扫描原样重做一遍即可修复（全部命令都
        // 幂等）。若把 SADD 提到任何一条 ZADD 前面，"其余命令成功、某条
        // ZADD 失败" 会让这条语录 exists() == true 而永远不在对应的索引
        // 里：GET / 随机得到它，任何 min_length/max_length（或
        // /?user_id=）查询都永远看不见它，而且再也不会被修复。
        try self.client.commandOk(args);
        try self.client.commandOk(&.{ "ZADD", key_bylen, lens, ids });
        // 作者维度的索引跟 hikari:bylen 是同一类东西：都是"提交点之前必须
        // 就位的索引"，所以排在同一段里、同样在 SADD hikari:index 之前。
        try self.client.commandOk(&.{ "ZADD", byUserKey(&ubuf, q.user_id), lens, ids });
        try self.client.commandOk(&.{ "SADD", key_index, ids });
    }

    /// 跟 add() 一样落一条语录，另外把"成员 → 链主键"的映射持久化进 Redis：
    /// `member_ids` 是这条 🔥 链的**全部**成员（时间升序，member_ids[0] ==
    /// q.message_id，即主键），至少应有 2 个（buildChains 只并成 ≥2 个成员的
    /// 链）；调用 add() 时用 1 个成员数组也能正常工作（只是多写一份主键到
    /// 自己的映射），不专门拒绝。
    ///
    /// 为什么需要这份映射：rules.classify 只能在**当次扫描窗口**重建出的链里
    /// 判定 "id 是不是某条链的成员"（chainOf 吃的是 window 里的 ✨/🔥 数据）。
    /// 一条链语录一旦入库，往后任何一次扫描都可能再次窗口内看到它、也可能
    /// 完全看不到它（已经翻过去了）；💦 撤稿这条链时引用的目标可能来自
    /// get_msg 回补或缓冲池，落在窗口外——chainOf 在那种情况下必然返回
    /// null，链无法在内存里重建。只有把"这个 id 属于哪条链"这件事在**收录
    /// 当时**写进 Redis，才能让 revoke() 在任何一次未来的扫描里、不依赖窗口
    /// 就查到答案，见 revoke() 与 revokeChainLocked 的实现。
    ///
    /// 写入顺序：chainmember 映射与 chain 成员集**先于** HSET/ZADD/SADD 落盘，
    /// 理由跟 add() 内部 SADD 必须最后发一致，但方向反过来更要紧：如果映射
    /// 写在 `SADD hikari:index`（提交点）之后，"index 提交成功、映射写失败"
    /// 会让 exists(主键) == true（今后重扫时被跳过、永不重试），但非主键成员
    /// 逃过了 isChainMember 守卫——往后一次窗口若单独判定到它，会被当成一条
    /// 全新的独立语录再收一遍，造出碎句与整句同时入库的重复。映射写在提交点
    /// 之前，任何一步失败都仍然满足 exists(主键) == false，下一次扫描原样
    /// 重做（SET/SADD/HSET/ZADD 全部幂等），不会有"半成品映射 + 已提交语录"
    /// 这种不一致状态。
    pub fn addChain(self: *Store, q: Quote, member_ids: []const i64) Error!void {
        const args = try hashFields(self.gpa, q);
        defer freeHashFields(self.gpa, args);

        var idb: [32]u8 = undefined;
        const primary_s = std.fmt.bufPrint(&idb, "{d}", .{q.message_id}) catch unreachable;
        var lenb: [32]u8 = undefined;
        const lens = std.fmt.bufPrint(&lenb, "{d}", .{q.length}) catch unreachable;
        var ckb: [64]u8 = undefined;
        const chain_key = chainKey(&ckb, q.message_id);
        var ubuf: [64]u8 = undefined;

        const member_strs = try formatIds(self.gpa, member_ids);
        defer freeIdStrings(self.gpa, member_strs);

        const sadd_chain_args = try buildMultiArgs(self.gpa, "SADD", chain_key, member_strs);
        defer self.gpa.free(sadd_chain_args);

        self.mutex.lock();
        defer self.mutex.unlock();

        for (member_ids) |mid| {
            var kb: [64]u8 = undefined;
            const key = chainMemberKey(&kb, mid);
            try self.client.commandOk(&.{ "SET", key, primary_s });
        }
        try self.client.commandOk(sadd_chain_args);

        try self.client.commandOk(args);
        try self.client.commandOk(&.{ "ZADD", key_bylen, lens, primary_s });
        // 链只有主键进 hikari:byuser（跟 hikari:bylen 一致）：整条链是一条
        // 语录，作者是全体成员共同的那一个人——buildChains 强制一条链的
        // 全部成员同属一个 user_id，这里不存在"该记谁"的歧义。
        try self.client.commandOk(&.{ "ZADD", byUserKey(&ubuf, q.user_id), lens, primary_s });
        try self.client.commandOk(&.{ "SADD", key_index, primary_s });
    }

    /// `hikari reindex`（`main.zig` 的子命令）唯一的实现：把 `hikari:index`
    /// 里已经存在的每一条语录补进它作者的 `hikari:byuser:{user_id}`。
    ///
    /// 为什么必须单独有这条路径：`hikari:byuser` 是后加的键，136 条更早收录
    /// 的生产语录不在里面，`/?user_id=` 对**整个**现存语录库恒定查不到（这
    /// 136 条同属一个作者，所以这不是"部分作者查不到"，是这个过滤器对上线
    /// 前的全部存量语录整体失效）。曾经写在设计文档与 `key_byuser_prefix`
    /// 注释里的修复建议是"把这些语录重新收录一遍"——那条建议是错的：扫描器
    /// 与 `hikari import` 都在 `Store.exists()` 这道关卡上就返回了，
    /// `add()`／`addChain()` 根本走不到，重放多少次都不会补上索引。只回填
    /// 索引、不改动语录本身的路径必须自己存在，就是这个方法。
    ///
    /// 命令序列：`SMEMBERS hikari:index` → 逐 id 一次
    /// `HMGET hikari:quote:{id} user_id length` → 两个字段都问到就
    /// `ZADD hikari:byuser:{user_id} {length} {id}`。
    ///
    /// 三条纪律：
    ///
    ///   - **只补索引，绝不创造或改动语录**：`HMGET` 是纯读；问不出 `user_id`
    ///     或 `length` 就跳过并计数，绝不拿 0 当默认值——`hikari:byuser:0`
    ///     会是一个真实存在、却对应不到任何人的假索引，比缺一条更难发现。
    ///   - **幂等、可重复跑**：`ZADD` 对已经在的成员就是原样覆盖 score。跑
    ///     第二遍发出的是逐字节相同的一串命令，不改变任何状态，所以中途失败
    ///     （网络断了、Redis 重启）的修复手段就是原样再跑一遍。
    ///   - **绝不自动触发**：只有运营方显式敲 `hikari reindex` 才会走到这里。
    ///     进程启动、定时扫描、任何 HTTP 读路径都不碰它——"读路径顺手写一笔"
    ///     和"启动时跑一遍全量修复"都会引入这次改动范围之外的新状态机，这正
    ///     是当初决定不做自动回填的理由，加了子命令也不推翻它。
    ///
    /// 先把 `SMEMBERS` 的结果解析成一份自有的 `[]i64` 再进循环，而不是抱着
    /// 那个 `resp.Value` 一路 `HMGET` 下去：一是索引成员本身的合法性在碰任何
    /// 一条 hash 之前就查完并计数；二是整张索引的回复能在循环开始前就释放掉，
    /// 循环期间的常驻内存是每条 8 字节，而不是一整个 resp.Value 数组。
    pub fn reindexByUser(self: *Store) Error!ReindexSummary {
        var summary: ReindexSummary = .{};

        self.mutex.lock();
        defer self.mutex.unlock();

        var ids: std.ArrayList(i64) = .empty;
        defer ids.deinit(self.gpa);
        {
            const v = try self.client.command(&.{ "SMEMBERS", key_index });
            defer v.deinit(self.client.gpa);
            const items: []const resp.Value = switch (v) {
                .array => |a| if (a) |arr| arr else &[_]resp.Value{},
                else => &[_]resp.Value{},
            };
            summary.seen = items.len;
            for (items) |item| {
                const member = bulkOrNull(item) orelse {
                    summary.bad_id += 1;
                    continue;
                };
                const id = std.fmt.parseInt(i64, member, 10) catch {
                    summary.bad_id += 1;
                    continue;
                };
                try ids.append(self.gpa, id);
            }
        }

        for (ids.items) |id| {
            var kb: [64]u8 = undefined;
            const v = try self.client.command(&.{ "HMGET", quoteKey(&kb, id), "user_id", "length" });
            defer v.deinit(self.client.gpa);
            const pair: []const resp.Value = switch (v) {
                .array => |a| if (a) |arr| arr else &[_]resp.Value{},
                else => &[_]resp.Value{},
            };
            const uid_s: ?[]const u8 = if (pair.len > 0) bulkOrNull(pair[0]) else null;
            const len_s: ?[]const u8 = if (pair.len > 1) bulkOrNull(pair[1]) else null;
            if (uid_s == null and len_s == null) {
                summary.missing_hash += 1;
                continue;
            }
            const uid: ?u64 = if (uid_s) |x| (std.fmt.parseInt(u64, x, 10) catch null) else null;
            if (uid == null) {
                summary.missing_user_id += 1;
                continue;
            }
            const length: ?usize = if (len_s) |x| (std.fmt.parseInt(usize, x, 10) catch null) else null;
            if (length == null) {
                summary.missing_length += 1;
                continue;
            }
            var idb: [32]u8 = undefined;
            const id_s = std.fmt.bufPrint(&idb, "{d}", .{id}) catch unreachable;
            var lenb: [32]u8 = undefined;
            const len_out = std.fmt.bufPrint(&lenb, "{d}", .{length.?}) catch unreachable;
            var ubuf: [64]u8 = undefined;
            try self.client.commandOk(&.{ "ZADD", byUserKey(&ubuf, uid.?), len_out, id_s });
            summary.reindexed += 1;
        }

        return summary;
    }

    /// 撤一条语录。`message_id` 先按 `hikari:chainmember:{message_id}` 查它是
    /// 不是某条 🔥 链的成员——不管是不是主键——查到就走 revokeChainLocked
    /// 撤整条链；查不到（GET 回 nil，最常见的情形：路径1/2/3 收录的普通语录，
    /// 或者压根没被 tombstone 过的任意 id）就走原来的单条撤稿逻辑。
    ///
    /// 这个 GET 是 revoke() 唯一新增的往返：它是让撤稿脱离"当次窗口能不能
    /// 重建出链"这个约束的关键——4.4 节承诺"跨扫描窗口的 💦 也能作废前几天
    /// 已入库的语录"对链语录同样成立，靠的就是这里查 Redis 而不是查内存里的
    /// chains 数组。
    pub fn revoke(self: *Store, message_id: i64) Error!void {
        var cmkb: [64]u8 = undefined;
        const chainmember_key = chainMemberKey(&cmkb, message_id);

        self.mutex.lock();
        defer self.mutex.unlock();

        const primary_v = try self.client.command(&.{ "GET", chainmember_key });
        defer primary_v.deinit(self.client.gpa);
        const primary_id: ?i64 = switch (primary_v) {
            .bulk => |b| if (b) |s| (std.fmt.parseInt(i64, s, 10) catch null) else null,
            else => null,
        };

        if (primary_id) |pid| {
            try self.revokeChainLocked(pid, message_id);
        } else {
            try self.revokeSingleLocked(message_id);
        }
    }

    /// `HGET hikari:quote:{id} user_id`，解析成数字。hash 不存在、字段缺失、
    /// 值不是数字，一律返回 null（都表示"问不出这条语录的作者"，不是错误：
    /// revoke() 完全可能收到一个从未真正入过库的 id）。撤稿路径靠这个反查
    /// "该清理哪一个人的 hikari:byuser:{user_id}"——message_id 本身不带
    /// user_id，撤稿请求只给了一个 id，唯一还能问到作者的地方就是这条语录
    /// 自己的 hash，而且必须在 DEL 把这份 hash 删掉**之前**问，问完之后
    /// 就再也无处可查了。假定调用方已经持有 self.mutex。
    fn quoteUserIdLocked(self: *Store, message_id: i64) Error!?u64 {
        var kb: [64]u8 = undefined;
        const v = try self.client.command(&.{ "HGET", quoteKey(&kb, message_id), "user_id" });
        defer v.deinit(self.client.gpa);
        return switch (v) {
            .bulk => |b| if (b) |raw| (std.fmt.parseInt(u64, raw, 10) catch null) else null,
            else => null,
        };
    }

    /// 原来 revoke() 的全部内容，改名后专门处理"这个 id 不属于任何链"的情形。
    /// 假定调用方已经持有 self.mutex。
    fn revokeSingleLocked(self: *Store, message_id: i64) Error!void {
        var kb: [64]u8 = undefined;
        const qk = quoteKey(&kb, message_id);
        var idb: [32]u8 = undefined;
        const ids = std.fmt.bufPrint(&idb, "{d}", .{message_id}) catch unreachable;

        // 这一步是纯读，不写任何东西，放在最前面不影响下面"tombstone 先
        // 落盘"这条不变式——它只是为了在 DEL 抹掉 hash 之前，把
        // hikari:byuser 该清理哪个键问出来。
        const owner = try self.quoteUserIdLocked(message_id);

        // tombstone 先落盘：它是这次作废唯一持久的事实（"这条消息永远不再入库"），
        // 而删索引、删 hash 都只是它的后果。这样任何一次部分失败最坏留下一个
        // 孤儿 hash（没人索引得到它，只占空间），而不是 hikari:index 里一个
        // 没有 hash 的悬空 id——后者会被 randomAny 抽中、HGETALL 回空，让一个
        // 非空的库对外返回 404，且永远不会自愈。SREM 也排在 ZREM 前面，理由
        // 同 add()：index 是对外可见性的开关，先关它。
        try self.client.commandOk(&.{ "SADD", key_tomb, ids });
        try self.client.commandOk(&.{ "SREM", key_index, ids });
        try self.client.commandOk(&.{ "ZREM", key_bylen, ids });
        // 问到作者才发这条 ZREM：问不到（hash 已经不存在、或者压根没有
        // user_id 字段——理论上不该发生，防御性处理）就跳过，是无害的
        // "没什么可清理"，不是错误。
        if (owner) |uid| {
            var ubuf: [64]u8 = undefined;
            try self.client.commandOk(&.{ "ZREM", byUserKey(&ubuf, uid), ids });
        }
        try self.client.commandOk(&.{ "DEL", qk });
    }

    /// 撤一整条 🔥 链：`pid` 是链主键（revoke() 从 chainmember 映射里查到的），
    /// `fallback_id` 是 revoke() 最初收到的那个 id（当 `hikari:chain:{pid}`
    /// 意外为空——比如上一次撤稿已经清理过、这次映射尚未清理的半成品状态——
    /// 时用来兜底，保证这次撤稿至少不是彻底的空操作）。假定调用方已经持有
    /// self.mutex。
    ///
    /// 命令顺序：SMEMBERS 读出全部成员 → SADD tomb（全部成员，tombstone 先
    /// 落盘，理由同 revokeSingleLocked）→ SREM index / ZREM bylen（对非主键
    /// 成员是无害空操作，它们从未被单独索引过）→ DEL 主键的 hash → 最后一步
    /// 清理映射本身（每个成员的 chainmember 键 + chain 成员集），不清理的话
    /// 撤过的链会在 Redis 里留下一份不再对应任何真实语录的映射，永久占位。
    fn revokeChainLocked(self: *Store, pid: i64, fallback_id: i64) Error!void {
        var pkb: [64]u8 = undefined;
        const chain_key = chainKey(&pkb, pid);
        const members_v = try self.client.command(&.{ "SMEMBERS", chain_key });
        defer members_v.deinit(self.client.gpa);
        const items: []const resp.Value = switch (members_v) {
            .array => |a| if (a) |arr| arr else &[_]resp.Value{},
            else => &[_]resp.Value{},
        };

        var members: std.ArrayList(i64) = .empty;
        defer members.deinit(self.gpa);
        for (items) |it| {
            const s = switch (it) {
                .bulk => |b| b orelse continue,
                else => continue,
            };
            const mid = std.fmt.parseInt(i64, s, 10) catch continue;
            try members.append(self.gpa, mid);
        }
        if (members.items.len == 0) {
            // 兜底：hikari:chain:{pid} 缺失或损坏时，至少把 revoke() 原始收到
            // 的 id 纳入清理，不让这一步彻底什么都不做——这个 id 本身仍然是
            // 一个真实的、需要被 tombstone 的 message_id。
            try members.append(self.gpa, fallback_id);
        }

        const member_strs = try formatIds(self.gpa, members.items);
        defer freeIdStrings(self.gpa, member_strs);

        // 整条链只有主键有 hash，作者也只能从主键那份 hash 上问出来——跟
        // revokeSingleLocked 一样，必须在下面的 DEL 之前问。非主键成员
        // 从来没进过 hikari:byuser，对它们发 ZREM 是无害空操作（member_strs
        // 里带上全部成员一起发，理由跟 SREM index / ZREM bylen 对它们的
        // 处理一致：反正是空操作，没必要为了"只清理主键"单独拆一条命令）。
        const owner = try self.quoteUserIdLocked(pid);

        {
            const args = try buildMultiArgs(self.gpa, "SADD", key_tomb, member_strs);
            defer self.gpa.free(args);
            try self.client.commandOk(args);
        }
        {
            const args = try buildMultiArgs(self.gpa, "SREM", key_index, member_strs);
            defer self.gpa.free(args);
            try self.client.commandOk(args);
        }
        {
            const args = try buildMultiArgs(self.gpa, "ZREM", key_bylen, member_strs);
            defer self.gpa.free(args);
            try self.client.commandOk(args);
        }
        if (owner) |uid| {
            var ubuf: [64]u8 = undefined;
            const args = try buildMultiArgs(self.gpa, "ZREM", byUserKey(&ubuf, uid), member_strs);
            defer self.gpa.free(args);
            try self.client.commandOk(args);
        }

        var qkb: [64]u8 = undefined;
        try self.client.commandOk(&.{ "DEL", quoteKey(&qkb, pid) });

        {
            const del_args = try self.gpa.alloc([]const u8, 1 + members.items.len + 1);
            defer self.gpa.free(del_args);
            del_args[0] = "DEL";
            const key_bufs = try self.gpa.alloc([64]u8, members.items.len);
            defer self.gpa.free(key_bufs);
            for (members.items, 0..) |mid, i| {
                del_args[1 + i] = chainMemberKey(&key_bufs[i], mid);
            }
            del_args[del_args.len - 1] = chain_key;
            try self.client.commandOk(del_args);
        }
    }

    /// `message_id` 是否是某条已入库 🔥 链的成员（不管是不是主键）。runner.zig
    /// 在把候选写库之前用这个作第三道关卡（tombstone、exists 之后）：一条链
    /// 一旦成功入库，它的非主键成员永远不会出现在 `hikari:index` 里（只有主键
    /// 会），单靠 exists() 拦不住它们被后续某次扫描当成独立消息重新收录——
    /// 见本文件顶部 key_chainmember_prefix 的注释与 addChain 的写入顺序说明。
    pub fn isChainMember(self: *Store, message_id: i64) Error!bool {
        var kb: [64]u8 = undefined;
        const key = chainMemberKey(&kb, message_id);
        self.mutex.lock();
        defer self.mutex.unlock();
        return (try self.client.commandInt(&.{ "EXISTS", key })) == 1;
    }

    /// `chainMemberKey(message_id)` 映射到的主键，nil（没有映射）时返回
    /// null——跟 isChainMember 的区别是它交回**原始的 GET 结果**而不是一个
    /// 布尔值，因为调用方（runner.zig，🔥 链候选自己的写前守卫）需要区分
    /// "这个 id 完全没有映射" 与 "这个 id 映射到它自己" 两种情况：addChain
    /// 把每个成员（含主键自己）的映射写在 HSET/ZADD/SADD 提交点**之前**
    /// （见 addChain 的说明），所以主键那条候选如果上一次 addChain 在映射
    /// 写完、HSET 还没提交前失败，chainPrimaryOf(主键) 会返回主键自己——
    /// 这不是"已经被别的链吸收"，是"上一次没提交完，这次该原样重试"，
    /// isChainMember 单纯判 EXISTS 分不清这两种情况，会把后一种也当成前
    /// 一种拦下，导致这条链永远卡住、永远重试不了。
    pub fn chainPrimaryOf(self: *Store, message_id: i64) Error!?i64 {
        var kb: [64]u8 = undefined;
        const key = chainMemberKey(&kb, message_id);
        self.mutex.lock();
        defer self.mutex.unlock();
        const v = try self.client.command(&.{ "GET", key });
        defer v.deinit(self.client.gpa);
        return switch (v) {
            .bulk => |b| if (b) |s| (std.fmt.parseInt(i64, s, 10) catch null) else null,
            else => null,
        };
    }

    /// 刷新这个用户当前的群名片快照（`hikari:username:{user_id}`）。调用方
    /// （`scan/runner.zig` 的 `authorCard`）只在这一轮真的问到
    /// `get_group_member_info` 的结果时才调用；问不到（网络失败、这个人已经
    /// 离群）就完全不碰这个键，保留上一次成功写入的值——这正是"作者离群"
    /// 这种情形下渲染时仍然拿得到"最后已知的名字"而不是被空白覆盖掉的原因。
    pub fn setUsername(self: *Store, user_id: u64, name: []const u8) Error!void {
        var kb: [64]u8 = undefined;
        const key = usernameKey(&kb, user_id);
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.client.commandOk(&.{ "SET", key, name });
    }

    /// 刷新这个群当前的群名快照（`hikari:groupname:{group_id}`），用法和理由
    /// 跟 setUsername 对称。
    pub fn setGroupName(self: *Store, group_id: u64, name: []const u8) Error!void {
        var kb: [64]u8 = undefined;
        const key = groupNameKey(&kb, group_id);
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.client.commandOk(&.{ "SET", key, name });
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
        var q = (try quoteFromPairs(gpa, items)) orelse return null;
        errdefer q.deinit(gpa);
        try self.resolveDisplayNames(gpa, &q);
        return q;
    }

    /// 渲染前用当前的 `hikari:username:{user_id}` / `hikari:groupname:{group_id}`
    /// 覆盖 hash 里冻结的 `from_who` / `from` 快照——这是"改名一次性反映到这个人
    /// 说过的全部历史语录"的落点。只在 fetchById 内部调用，此时锁已经被持有
    /// （同 fetchById 本身的纪律），这里不再加锁。
    ///
    /// **哪个赢，为什么**：MGET 命中（哪怕命中的值本身是空串）就覆盖，因为
    /// 命中代表"这个 user_id / group_id 最近一次被成功刷新过"，是比收录当时
    /// 冻结进 hash 的快照更新的事实——这正是这次改动要解决的问题本身（改名
    /// 之后旧语录不该继续挂着旧名字）。MGET 未命中（nil）则退回 hash 里存的
    /// 旧值：可能是这条语录是 `import` 写进来的（`import.zig` 不刷新这两个
    /// 键，见 import.zig 的说明）、这个人从没在任何一次扫描里当过候选作者、
    /// 或者他已经离群且这份映射本身从来没写成功过。136 条现存生产语录全部
    /// 落在这条 fallback 分支：它们的 hash 里已经有 `user_id`/`group_id`
    /// （`hashFields`/`quoteFromPairs` 一直都在读写这两个字段，不是这次改动
    /// 新增的），`hikari:username`/`hikari:groupname` 这两个键此前从未存在过，
    /// 所以 MGET 对它们必然回 nil、直接落回 hash 里的旧值——不需要任何迁移
    /// 脚本去补写这两个键。
    ///
    /// MGET 失败统一走同一条策略：任何不是"成功拿到一个数组"的结果都向上
    /// 传播成一个真正的 Error，不在这里为任何一种分支静默 return——早期
    /// 版本只让传输层/协议层错误（`self.client.command` 本身 `try` 失败）
    /// 经过传播，但 Redis 对 MGET 回一个合法的 `-ERR ...`（`resp.Value` 的
    /// `.err` 分支）时 `command()` 并不会把它转成 Zig error（那是
    /// commandOk/commandInt 自己做的转换，见 redis/client.zig），直接查
    /// `.array` 会落进 `else` 分支被悄悄吞掉，跟"这个键不存在"混成同一种
    /// 结果——这是本方法此前不一致的地方，已按 review 意见改成两种情况都
    /// 显式返回 Error。
    ///
    /// 为什么不能吞：这是一条单连接、请求/响应严格配对的协议，Store 层没有
    /// 重新对齐帧边界的机制。MGET 一旦在读到一半时失败（不管是传输层错误、
    /// 协议解析错误，还是服务端合法返回的 `-ERR`），这条连接接下来读到的
    /// 字节是不是下一条命令真正的回复，已经没有任何保证——真正的风险不是
    /// "这次渲染用了旧名字"，是"连接的帧对齐从这里起就不可信，后面所有
    /// 命令都可能读到错位的回复"。把这类失败原样 try 出去，让上层（HTTP
    /// 500 / scanGroup 的 Failed 行）看见，才对得上"连接可能已经不可信"
    /// 这个事实；静默吞掉只会把一个连接层面的问题伪装成一次内容层面的巧合。
    fn resolveDisplayNames(self: *Store, gpa: std.mem.Allocator, q: *Quote) Error!void {
        var ukb: [64]u8 = undefined;
        var gkb: [64]u8 = undefined;
        const ukey = usernameKey(&ukb, q.user_id);
        const gkey = groupNameKey(&gkb, q.group_id);
        const v = try self.client.command(&.{ "MGET", ukey, gkey });
        defer v.deinit(self.client.gpa);
        const items: []const resp.Value = switch (v) {
            .array => |a| a orelse return error.ProtocolError,
            .err => return error.RedisError,
            else => return error.ProtocolError,
        };
        if (items.len >= 1) {
            if (bulkOrNull(items[0])) |name| {
                const dup = try gpa.dupe(u8, name);
                gpa.free(q.from_who);
                q.from_who = dup;
            }
        }
        if (items.len >= 2) {
            if (bulkOrNull(items[1])) |name| {
                const dup = try gpa.dupe(u8, name);
                gpa.free(q.from);
                q.from = dup;
            }
        }
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

    /// `ZRANGEBYSCORE {key} {min} {max}`，`key` 是 `hikari:byuser:{uid}` 还是
    /// 全库的 `hikari:bylen` 由调用方决定。三个过滤过的读方法（
    /// `randomFiltered`/`allFiltered`/`randomManyFiltered`）的 `user_id`
    /// 分支与"只有长度过滤"分支因此共用同一段查询逻辑，"user_id 和长度
    /// 组合起来"不是一条单独维护的路径。假定调用方已经持有 self.mutex。
    fn scoreRangeAtLocked(self: *Store, key: []const u8, min: usize, max: usize) Error!resp.Value {
        var minb: [32]u8 = undefined;
        var maxb: [32]u8 = undefined;
        const mins = std.fmt.bufPrint(&minb, "{d}", .{min}) catch unreachable;
        const maxs = std.fmt.bufPrint(&maxb, "{d}", .{max}) catch unreachable;
        return self.client.command(&.{ "ZRANGEBYSCORE", key, mins, maxs });
    }

    /// `filter` 里 `user_id` 决定 key，是 null 时落回全库的 `hikari:bylen`；
    /// 假定调用方已经持有 self.mutex。
    fn rangeKeyLocked(filter: Filter, buf: *[64]u8) []const u8 {
        return if (filter.user_id) |uid| byUserKey(buf, uid) else key_bylen;
    }

    /// `GET /` 的统一入口，供 server.zig 在 `user_id` 存在时使用。
    ///
    /// `filter.user_id == null` 时**逐字节委托**给改动前就有的
    /// `randomAny`/`randomByLength`——不是重新实现同样的逻辑，是直接调用
    /// 它们：这样不带 `user_id` 的请求命令序列跟这次改动之前完全相同，
    /// 那两个函数已有的测试不需要跟着改，也不需要为"没有 user_id 时行为
    /// 不变"这件事另外证明什么。只有 `user_id` 非 null 时才会走下面全新的
    /// `hikari:byuser` 路径。
    pub fn randomFiltered(self: *Store, gpa: std.mem.Allocator, filter: Filter) Error!?Quote {
        if (filter.user_id == null) {
            if (filter.min_length != null or filter.max_length != null) {
                return self.randomByLength(gpa, filter.minScore(), filter.maxScore());
            }
            return self.randomAny(gpa);
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        var kb: [64]u8 = undefined;
        const key = rangeKeyLocked(filter, &kb);
        const v = try self.scoreRangeAtLocked(key, filter.minScore(), filter.maxScore());
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

    /// `/extra/all` 的统一入口。`filter.isUnfiltered()` 时逐字节委托给
    /// `allQuotes`（理由同 `randomFiltered`）；带任何过滤（`user_id` 和/或
    /// 长度）时走 `ZRANGEBYSCORE` + `fetchMany`——`/extra/all` 在这次改动
    /// 之前完全不支持长度过滤，所以"只有长度、没有 user_id"这个分支对它
    /// 而言也是新代码，跟 `user_id` 分支共用同一个 `rangeKeyLocked`。
    pub fn allFiltered(self: *Store, gpa: std.mem.Allocator, filter: Filter) Error![]Quote {
        if (filter.isUnfiltered()) return self.allQuotes(gpa);

        self.mutex.lock();
        defer self.mutex.unlock();
        var kb: [64]u8 = undefined;
        const key = rangeKeyLocked(filter, &kb);
        const v = try self.scoreRangeAtLocked(key, filter.minScore(), filter.maxScore());
        defer v.deinit(self.client.gpa);
        const items: []const resp.Value = switch (v) {
            .array => |a| if (a) |arr| arr else &[_]resp.Value{},
            else => &[_]resp.Value{},
        };
        return self.fetchMany(gpa, items);
    }

    /// `/extra/batch/:count` 的统一入口。`filter.isUnfiltered()` 时逐字节
    /// 委托给 `randomMany`（理由同 `randomFiltered`）；带任何过滤时先
    /// `ZRANGEBYSCORE` 拿到候选集合，再在本地**有放回**地抽 `count`
    /// 次——`randomMany` 的 `SRANDMEMBER` 负数形式做不到"从这个人的语录
    /// 里"这件事（`SRANDMEMBER` 只能整个 SET 一起抽，不能先按 `user_id`
    /// 或长度过滤），所以过滤路径必须先把候选集合读到本地，"允许重复"这条
    /// 承诺靠 `fetchSampled` 的有放回抽样维持，不能因为换了实现路径就悄悄
    /// 变成去重语义。
    pub fn randomManyFiltered(self: *Store, gpa: std.mem.Allocator, filter: Filter, count: usize) Error![]Quote {
        if (filter.isUnfiltered()) return self.randomMany(gpa, count);

        self.mutex.lock();
        defer self.mutex.unlock();
        var kb: [64]u8 = undefined;
        const key = rangeKeyLocked(filter, &kb);
        const v = try self.scoreRangeAtLocked(key, filter.minScore(), filter.maxScore());
        defer v.deinit(self.client.gpa);
        const items: []const resp.Value = switch (v) {
            .array => |a| if (a) |arr| arr else &[_]resp.Value{},
            else => &[_]resp.Value{},
        };
        return self.fetchSampled(gpa, items, count);
    }

    /// 从候选 id 集合（`ZRANGEBYSCORE` 回复里的 bulk string 数组）里**有
    /// 放回**地抽 `count` 条展开。清理纪律跟 `fetchMany` 逐字相同（同一段
    /// errdefer + append 失败时就地释放 q，理由见 `fetchMany` 的文档注释）。
    /// 只在 `randomManyFiltered` 内部调用，此时锁已经被持有。
    fn fetchSampled(self: *Store, gpa: std.mem.Allocator, ids: []const resp.Value, count: usize) Error![]Quote {
        var out: std.ArrayList(Quote) = .empty;
        errdefer {
            for (out.items) |q| q.deinit(gpa);
            out.deinit(gpa);
        }
        if (ids.len > 0) {
            var n: usize = 0;
            while (n < count) : (n += 1) {
                const pick = ids[std.crypto.random.uintLessThan(usize, ids.len)];
                const id_str = switch (pick) {
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
    shutdown: std.atomic.Value(bool),
    stopped: bool,

    fn serve(self: *FakeServer) void {
        const conn = self.listener.accept() catch return;
        defer conn.stream.close();
        if (self.shutdown.load(.acquire)) return;
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
            .shutdown = .init(false),
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
        // 不能从控制线程直接 close 正阻塞在 accept() 的监听 fd：Darwin 会让
        // std.posix.accept 收到 BADF，而 Zig 把它判作竞态并 unreachable panic。
        // 先用本机连接正常唤醒 accept；服务线程看见 shutdown 后立即退出，等
        // join 确认它不再访问 listener，最后才安全关闭监听 fd。
        self.shutdown.store(true, .release);
        if (std.net.tcpConnectToAddress(self.listener.listen_address)) |wake| {
            wake.close();
        } else |_| {}
        self.thread.join();
        self.listener.deinit();
    }
};

test "FakeServer.stop：没有客户端 connect 时也能安全唤醒 accept" {
    const gpa = std.testing.allocator;
    const srv = try FakeServer.start(gpa, "+OK\r\n");
    defer {
        srv.stop();
        srv.received.deinit(gpa);
        gpa.destroy(srv);
    }

    // 不建立客户端连接：stop 自己必须唤醒服务线程，不能并发 close listener
    // 触发 Darwin BADF panic，也不能把 join 永久卡在 accept 上。
    srv.stop();
    try std.testing.expectEqual(@as(usize, 0), srv.received.items.len);
}

/// 把 args[skip..] 编码成一段 RESP bulk-string 数组回复，字节布局与
/// `resp.encodeCommand` 完全相同（都是 `*N\r\n$len\r\nval\r\n...`），
/// 用来伪造 HGETALL 的数组回复。
fn encodeArrayReply(gpa: std.mem.Allocator, items: []const []const u8) ![]u8 {
    return resp.encodeCommand(gpa, items);
}

/// fetchById 现在在每次 HGETALL 之后紧跟着发一条 `MGET hikari:username:{id}
/// hikari:groupname:{id}`（resolveDisplayNames）。绝大多数既有测试关心的是
/// hash 本身的内容，不关心改名覆盖这件事，所以给它们喂一对 nil——两个键都
/// 没写过，回退到 hash 里的旧值，测试原有的内容断言不用跟着改。改名覆盖 /
/// fallback 本身的行为在下面单独的测试里覆盖。
const mget_nil_reply = "*2\r\n$-1\r\n$-1\r\n";

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

test "add 依次发 HSET / ZADD(bylen) / ZADD(byuser) / SADD —— hikari:index 是提交点" {
    const gpa = std.testing.allocator;
    const srv = try FakeServer.start(gpa, ":15\r\n:1\r\n:1\r\n:1\r\n");
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
    // 扫描会原样重做一遍（HSET/ZADD/ZADD/SADD 都幂等）。反过来把 SADD 放在
    // 任何一条 ZADD 前面的话，"其余命令成功、某条 ZADD 失败" 会让这条语录
    // exists() == true，从此每次扫描都跳过它，而它永远进不了对应的索引——
    // GET / 能随机到，任何带 min_length/max_length（或 /?user_id=）的查询
    // 都永远看不见，且不会自愈。sampleQuote() 的 user_id 是 10001。
    try expectFrameSequence(srv.received.items, &.{
        "*32\r\n$4\r\nHSET\r\n$18\r\nhikari:quote:12345\r\n",
        "*4\r\n$4\r\nZADD\r\n$12\r\nhikari:bylen\r\n$1\r\n7\r\n$5\r\n12345\r\n",
        "*4\r\n$4\r\nZADD\r\n$19\r\nhikari:byuser:10001\r\n$1\r\n7\r\n$5\r\n12345\r\n",
        "*3\r\n$4\r\nSADD\r\n$12\r\nhikari:index\r\n$5\r\n12345\r\n",
    });
}

test "revoke（非链成员）先 GET chainmember 查不到，HGET 问出作者，再依次发 SADD tomb / SREM / ZREM(bylen) / ZREM(byuser) / DEL —— tombstone 先落盘" {
    const gpa = std.testing.allocator;
    // 第一条回复是 GET hikari:chainmember:12345 的结果：nil，表示这个 id
    // 不属于任何链，revoke() 据此走 revokeSingleLocked。第二条回复是
    // HGET hikari:quote:12345 user_id 的结果："10001"——revokeSingleLocked
    // 在 DEL 之前先问出作者，才知道该清理 hikari:byuser 的哪个键；后面
    // 五条回复是 SADD tomb / SREM index / ZREM bylen / ZREM byuser / DEL。
    const srv = try FakeServer.start(gpa, "$-1\r\n$5\r\n10001\r\n:1\r\n:1\r\n:1\r\n:1\r\n:1\r\n");
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

    // tombstone 是这次作废唯一持久的事实：它一旦落盘，即使后面几步全失败，
    // 下一次扫描的 isTombstoned 也会挡住重新入库，而运营方看到的是"还能查到
    // 这条语录"这种可见、可重试的故障。反过来先 DEL 再 SREM 的话，DEL 成功、
    // SREM 失败会在 hikari:index 里留下一个没有 hash 的悬空 id：randomAny
    // 抽中它，HGETALL 回空，非空库对外返回 404，而且永远不会自愈。HGET 本身
    // 是纯读，排在最前面不影响这条不变式。
    try expectFrameSequence(srv.received.items, &.{
        "*2\r\n$3\r\nGET\r\n$24\r\nhikari:chainmember:12345\r\n",
        "*3\r\n$4\r\nHGET\r\n$18\r\nhikari:quote:12345\r\n$7\r\nuser_id\r\n",
        "*3\r\n$4\r\nSADD\r\n$11\r\nhikari:tomb\r\n$5\r\n12345\r\n",
        "*3\r\n$4\r\nSREM\r\n$12\r\nhikari:index\r\n$5\r\n12345\r\n",
        "*3\r\n$4\r\nZREM\r\n$12\r\nhikari:bylen\r\n$5\r\n12345\r\n",
        "*3\r\n$4\r\nZREM\r\n$19\r\nhikari:byuser:10001\r\n$5\r\n12345\r\n",
        "*2\r\n$3\r\nDEL\r\n$18\r\nhikari:quote:12345\r\n",
    });
}

// ---------------------------------------------------------------------------
// addChain / 🔥 链撤稿：见 store.zig 顶部 key_chainmember_prefix / key_chain_prefix
// 的注释。这组测试覆盖"跨扫描窗口撤稿"这个 gap 本身——rules.classify 的
// chainOf 只能在当次窗口重建出的链里查找，💦 引用的目标若来自缓冲池或
// get_msg 回补（窗口外），chainOf 必然返回 null；这里验证的是 Store 层
// 不依赖窗口、单靠 Redis 里持久化的映射就能把同样的作废展开到全部成员。

test "addChain 依次发每个成员的 SET 映射 / SADD chain 集 / HSET / ZADD(bylen) / ZADD(byuser) / SADD —— 映射先于 index 提交点落盘" {
    const gpa = std.testing.allocator;
    const srv = try FakeServer.start(gpa, "+OK\r\n+OK\r\n+OK\r\n+OK\r\n+OK\r\n+OK\r\n+OK\r\n");
    defer {
        srv.stop();
        srv.received.deinit(gpa);
        gpa.destroy(srv);
    }
    var c = try redis.Client.connect(gpa, "127.0.0.1", srv.port(), null, 0);
    defer c.deinit();
    var store = Store.init(gpa, &c);

    // sampleQuote() 的 message_id 是 12345（链主键）；999 是链的第二个成员。
    // sampleQuote() 的 user_id 是 10001。
    try store.addChain(sampleQuote(), &.{ 12345, 999 });

    c.deinit();
    srv.stop();

    // 顺序原则跟 add() 反过来：映射（每个成员一条 SET，外加 chain 成员集的
    // SADD）必须先于 HSET/ZADD/ZADD/SADD 落盘，理由见 addChain 的文档注释——
    // "index 提交成功、映射写失败" 会让非主键成员逃过 isChainMember 守卫。
    // hikari:byuser 只记主键，跟 hikari:bylen 一致。
    try expectFrameSequence(srv.received.items, &.{
        "*3\r\n$3\r\nSET\r\n$24\r\nhikari:chainmember:12345\r\n$5\r\n12345\r\n",
        "*3\r\n$3\r\nSET\r\n$22\r\nhikari:chainmember:999\r\n$5\r\n12345\r\n",
        "*4\r\n$4\r\nSADD\r\n$18\r\nhikari:chain:12345\r\n$5\r\n12345\r\n$3\r\n999\r\n",
        "*32\r\n$4\r\nHSET\r\n$18\r\nhikari:quote:12345\r\n",
        "*4\r\n$4\r\nZADD\r\n$12\r\nhikari:bylen\r\n$1\r\n7\r\n$5\r\n12345\r\n",
        "*4\r\n$4\r\nZADD\r\n$19\r\nhikari:byuser:10001\r\n$1\r\n7\r\n$5\r\n12345\r\n",
        "*3\r\n$4\r\nSADD\r\n$12\r\nhikari:index\r\n$5\r\n12345\r\n",
    });
}

fn checkAddChainAlloc(gpa: std.mem.Allocator) !void {
    const net_gpa = std.testing.allocator;
    const srv = try FakeServer.start(net_gpa, "+OK\r\n+OK\r\n+OK\r\n+OK\r\n+OK\r\n+OK\r\n+OK\r\n");
    defer {
        srv.stop();
        srv.received.deinit(net_gpa);
        net_gpa.destroy(srv);
    }
    var c = try redis.Client.connect(net_gpa, "127.0.0.1", srv.port(), null, 0);
    defer c.deinit();
    var st = Store.init(gpa, &c);
    try st.addChain(sampleQuote(), &.{ 12345, 999 });
}

test "addChain 在分配失败时不泄漏（checkAllAllocationFailures）" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkAddChainAlloc, .{});
}

test "revoke：💦 引用一条跨窗口链的非主键成员——GET 查到主键，SMEMBERS 展开全部成员，全部 tombstone 且映射被清理" {
    const gpa = std.testing.allocator;
    // 场景：链 {12345, 999}（主键 12345）是之前某次扫描收录的，这次扫描的
    // 窗口里已经看不到 12345/999 本身了（chainOf 在内存里重建不出这条链），
    // 💦 引用的是非主键成员 999——revoke(999) 必须只靠 Redis 里的映射就能
    // 解析出整条链并作废，这正是本次改动要补的 gap。
    // HGET hikari:quote:12345 user_id -> "10001"（revokeChainLocked 在
    // DEL 之前问出主键那份 hash 的作者，才知道清理 hikari:byuser 的哪个
    // 键）之后是 SADD tomb / SREM index / ZREM bylen / ZREM byuser / DEL
    // quote / DEL 映射清理。
    const script = "$5\r\n12345\r\n" ++ // GET hikari:chainmember:999 -> "12345"
        "*2\r\n$5\r\n12345\r\n$3\r\n999\r\n" ++ // SMEMBERS hikari:chain:12345 -> {12345, 999}
        "$5\r\n10001\r\n" ++ // HGET hikari:quote:12345 user_id -> "10001"
        ":1\r\n:1\r\n:1\r\n:1\r\n:1\r\n:1\r\n";
    const srv = try FakeServer.start(gpa, script);
    defer {
        srv.stop();
        srv.received.deinit(gpa);
        gpa.destroy(srv);
    }
    var c = try redis.Client.connect(gpa, "127.0.0.1", srv.port(), null, 0);
    defer c.deinit();
    var store = Store.init(gpa, &c);

    try store.revoke(999);

    c.deinit();
    srv.stop();

    try expectFrameSequence(srv.received.items, &.{
        "*2\r\n$3\r\nGET\r\n$22\r\nhikari:chainmember:999\r\n",
        "*2\r\n$8\r\nSMEMBERS\r\n$18\r\nhikari:chain:12345\r\n",
        "*3\r\n$4\r\nHGET\r\n$18\r\nhikari:quote:12345\r\n$7\r\nuser_id\r\n",
        "*4\r\n$4\r\nSADD\r\n$11\r\nhikari:tomb\r\n$5\r\n12345\r\n$3\r\n999\r\n",
        "*4\r\n$4\r\nSREM\r\n$12\r\nhikari:index\r\n$5\r\n12345\r\n$3\r\n999\r\n",
        "*4\r\n$4\r\nZREM\r\n$12\r\nhikari:bylen\r\n$5\r\n12345\r\n$3\r\n999\r\n",
        // byuser 的 ZREM 带上链的全部成员（12345、999），跟 index/bylen 的
        // 处理一致——非主键成员对它是无害空操作。
        "*4\r\n$4\r\nZREM\r\n$19\r\nhikari:byuser:10001\r\n$5\r\n12345\r\n$3\r\n999\r\n",
        "*2\r\n$3\r\nDEL\r\n$18\r\nhikari:quote:12345\r\n",
        // 映射清理不能省：这一步删掉两个成员各自的 chainmember 键与 chain
        // 成员集本身，"mapping 必须不泄漏" 靠这一帧钉死——只查子串存在性会让
        // 参数换位/漏删悄悄通过，见 store.zig 别处同类注释。
        "*4\r\n$3\r\nDEL\r\n$24\r\nhikari:chainmember:12345\r\n$22\r\nhikari:chainmember:999\r\n$18\r\nhikari:chain:12345\r\n",
    });
}

test "revoke：💦 引用链的主键本身——同样走 GET/SMEMBERS 展开，与引用非主键成员时行为一致" {
    const gpa = std.testing.allocator;
    const script = "$5\r\n12345\r\n" ++ // GET hikari:chainmember:12345 -> "12345"（主键映射到自己）
        "*2\r\n$5\r\n12345\r\n$3\r\n999\r\n" ++
        "$5\r\n10001\r\n" ++ // HGET hikari:quote:12345 user_id -> "10001"
        ":1\r\n:1\r\n:1\r\n:1\r\n:1\r\n:1\r\n";
    const srv = try FakeServer.start(gpa, script);
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

    try expectFrameSequence(srv.received.items, &.{
        "*2\r\n$3\r\nGET\r\n$24\r\nhikari:chainmember:12345\r\n",
        "*2\r\n$8\r\nSMEMBERS\r\n$18\r\nhikari:chain:12345\r\n",
        "*3\r\n$4\r\nHGET\r\n$18\r\nhikari:quote:12345\r\n$7\r\nuser_id\r\n",
        "*4\r\n$4\r\nSADD\r\n$11\r\nhikari:tomb\r\n$5\r\n12345\r\n$3\r\n999\r\n",
        "*4\r\n$4\r\nSREM\r\n$12\r\nhikari:index\r\n$5\r\n12345\r\n$3\r\n999\r\n",
        "*4\r\n$4\r\nZREM\r\n$12\r\nhikari:bylen\r\n$5\r\n12345\r\n$3\r\n999\r\n",
        "*4\r\n$4\r\nZREM\r\n$19\r\nhikari:byuser:10001\r\n$5\r\n12345\r\n$3\r\n999\r\n",
        "*2\r\n$3\r\nDEL\r\n$18\r\nhikari:quote:12345\r\n",
        "*4\r\n$3\r\nDEL\r\n$24\r\nhikari:chainmember:12345\r\n$22\r\nhikari:chainmember:999\r\n$18\r\nhikari:chain:12345\r\n",
    });
}

fn checkRevokeChainAlloc(gpa: std.mem.Allocator) !void {
    const net_gpa = std.testing.allocator;
    const script = "$5\r\n12345\r\n" ++
        "*2\r\n$5\r\n12345\r\n$3\r\n999\r\n" ++
        "$5\r\n10001\r\n" ++
        ":1\r\n:1\r\n:1\r\n:1\r\n:1\r\n:1\r\n";
    const srv = try FakeServer.start(net_gpa, script);
    defer {
        srv.stop();
        srv.received.deinit(net_gpa);
        net_gpa.destroy(srv);
    }
    var c = try redis.Client.connect(net_gpa, "127.0.0.1", srv.port(), null, 0);
    defer c.deinit();
    var st = Store.init(gpa, &c);
    try st.revoke(999);
}

test "revoke 撤链路径（revokeChainLocked）在分配失败时不泄漏（checkAllAllocationFailures）" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkRevokeChainAlloc, .{});
}

test "isChainMember 发 EXISTS hikari:chainmember:{id} 并解读结果" {
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
        try std.testing.expect(try store.isChainMember(999));
        c.deinit();
        srv.stop();
        try expectFrameSequence(srv.received.items, &.{
            "*2\r\n$6\r\nEXISTS\r\n$22\r\nhikari:chainmember:999\r\n",
        });
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
        try std.testing.expect(!try store.isChainMember(999));
    }
}

test "chainPrimaryOf 发 GET hikari:chainmember:{id}，nil 返回 null，命中时解析出主键" {
    const gpa = std.testing.allocator;
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
        try std.testing.expectEqual(@as(?i64, null), try store.chainPrimaryOf(999));
        c.deinit();
        srv.stop();
        try expectFrameSequence(srv.received.items, &.{
            "*2\r\n$3\r\nGET\r\n$22\r\nhikari:chainmember:999\r\n",
        });
    }
    {
        // 命中：映射存在，指向主键 1——这条测试同时覆盖"指向别的主键"
        // （runner.zig 据此拦下这条候选）与"指向自己"（1 GET
        // hikari:chainmember:1 -> "1"，runner.zig 据此允许 addChain
        // 重试）这两种在 runner.zig 里语义完全不同、但在这个方法这一层
        // 都只是"原样交回 GET 到的整数"的情形；两种语义的区分留给
        // 调用方，这个方法本身不做判断。
        const srv = try FakeServer.start(gpa, "$1\r\n1\r\n");
        defer {
            srv.stop();
            srv.received.deinit(gpa);
            gpa.destroy(srv);
        }
        var c = try redis.Client.connect(gpa, "127.0.0.1", srv.port(), null, 0);
        defer c.deinit();
        var store = Store.init(gpa, &c);
        try std.testing.expectEqual(@as(?i64, 1), try store.chainPrimaryOf(1));
    }
}

test "revoke：hikari:chain 集合意外为空时兜底用原始 id 完成撤稿（不是彻底空操作）" {
    const gpa = std.testing.allocator;
    // GET 查到主键 12345，但 SMEMBERS hikari:chain:12345 回一个空数组——
    // 模拟数据异常/上一次撤稿留下的半成品状态。revokeChainLocked 的兜底
    // 应该退回用 revoke() 最初收到的 id（这里是 12345 自己）继续走完
    // tombstone/清理，而不是对着空 members 发出参数个数为 0 的非法 SADD。
    const script = "$5\r\n12345\r\n" ++ "*0\r\n" ++ "$5\r\n10001\r\n" ++ ":1\r\n:1\r\n:1\r\n:1\r\n:1\r\n:1\r\n";
    const srv = try FakeServer.start(gpa, script);
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

    try expectFrameSequence(srv.received.items, &.{
        "*2\r\n$3\r\nGET\r\n$24\r\nhikari:chainmember:12345\r\n",
        "*2\r\n$8\r\nSMEMBERS\r\n$18\r\nhikari:chain:12345\r\n",
        "*3\r\n$4\r\nHGET\r\n$18\r\nhikari:quote:12345\r\n$7\r\nuser_id\r\n",
        "*3\r\n$4\r\nSADD\r\n$11\r\nhikari:tomb\r\n$5\r\n12345\r\n",
        "*3\r\n$4\r\nSREM\r\n$12\r\nhikari:index\r\n$5\r\n12345\r\n",
        "*3\r\n$4\r\nZREM\r\n$12\r\nhikari:bylen\r\n$5\r\n12345\r\n",
        // 兜底路径同样只把 fallback_id（12345 自己）纳入 byuser 的清理。
        "*3\r\n$4\r\nZREM\r\n$19\r\nhikari:byuser:10001\r\n$5\r\n12345\r\n",
        "*2\r\n$3\r\nDEL\r\n$18\r\nhikari:quote:12345\r\n",
        // 兜底只把 fallback_id（12345 自己）纳入清理，所以最后这条 DEL 只有
        // 两个 key：它自己的 chainmember 键 + chain 集合本身，不是三个成员。
        "*3\r\n$3\r\nDEL\r\n$24\r\nhikari:chainmember:12345\r\n$18\r\nhikari:chain:12345\r\n",
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

    const script = try std.mem.concat(gpa, u8, &.{ "$5\r\n12345\r\n", hgetall_reply, mget_nil_reply });
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
    // resolveDisplayNames 的 MGET 也确实发出去了，key 按 hash 里的 user_id/
    // group_id（10001/999）拼，不是随便两个 nil 键。
    try std.testing.expect(std.mem.indexOf(u8, srv.received.items, "MGET") != null);
    try std.testing.expect(std.mem.indexOf(u8, srv.received.items, "hikari:username:10001") != null);
    try std.testing.expect(std.mem.indexOf(u8, srv.received.items, "hikari:groupname:999") != null);
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

    const script = try std.mem.concat(gpa, u8, &.{ "*1\r\n$5\r\n12345\r\n", hgetall_reply, mget_nil_reply });
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
// Filter / randomFiltered / allFiltered / randomManyFiltered —— `/?user_id=`
// 在三个端点上的统一实现。`isUnfiltered()` 时逐字节委托给改动前就有的
// randomAny/randomByLength/allQuotes/randomMany（那几个函数的测试已经钉死
// 了这条路径，这里不重复钉），只有真的带 user_id 和/或长度时才会走下面
// 这条全新的 ZRANGEBYSCORE 路径。

test "randomFiltered 带 user_id 时走 hikari:byuser（不是 hikari:index），命令帧钉死" {
    const gpa = std.testing.allocator;
    const args = try hashFields(gpa, sampleQuote());
    defer freeHashFields(gpa, args);
    const hgetall_reply = try encodeArrayReply(gpa, args[2..]);
    defer gpa.free(hgetall_reply);

    // ZRANGEBYSCORE hikari:byuser:10001 0 4294967295 -> {"12345"}，接着
    // HGETALL + MGET（resolveDisplayNames，命中 nil，回退 hash 快照）。
    const script = try std.mem.concat(gpa, u8, &.{ "*1\r\n$5\r\n12345\r\n", hgetall_reply, mget_nil_reply });
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

    var q = (try store.randomFiltered(gpa, .{ .user_id = 10001 })).?;
    defer q.deinit(gpa);
    try std.testing.expectEqualStrings("今天也是好天气", q.hitokoto);

    c.deinit();
    srv.stop();
    // 整条命令帧钉死，不是分别 indexOf——key/min/max 换位不能悄悄通过。
    try std.testing.expect(std.mem.indexOf(
        u8,
        srv.received.items,
        "*4\r\n$13\r\nZRANGEBYSCORE\r\n$19\r\nhikari:byuser:10001\r\n$1\r\n0\r\n$10\r\n4294967295\r\n",
    ) != null);
    // hikari:index/hikari:bylen 完全没有被碰过——user_id 存在时不会退回
    // 全库索引。
    try std.testing.expect(std.mem.indexOf(u8, srv.received.items, "hikari:index") == null);
    try std.testing.expect(std.mem.indexOf(u8, srv.received.items, "hikari:bylen") == null);
}

test "randomFiltered 带 user_id + 长度区间：score 范围跟着 min/max 走，key 仍是 hikari:byuser" {
    const gpa = std.testing.allocator;
    const args = try hashFields(gpa, sampleQuote());
    defer freeHashFields(gpa, args);
    const hgetall_reply = try encodeArrayReply(gpa, args[2..]);
    defer gpa.free(hgetall_reply);

    const script = try std.mem.concat(gpa, u8, &.{ "*1\r\n$5\r\n12345\r\n", hgetall_reply, mget_nil_reply });
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

    var q = (try store.randomFiltered(gpa, .{ .user_id = 10001, .min_length = 5, .max_length = 10 })).?;
    defer q.deinit(gpa);
    try std.testing.expectEqualStrings("今天也是好天气", q.hitokoto);

    c.deinit();
    srv.stop();
    try std.testing.expect(std.mem.indexOf(
        u8,
        srv.received.items,
        "*4\r\n$13\r\nZRANGEBYSCORE\r\n$19\r\nhikari:byuser:10001\r\n$1\r\n5\r\n$2\r\n10\r\n",
    ) != null);
}

test "randomFiltered：user_id 对应的候选集合为空（含 136 条无索引的历史语录这种情形）返回 null" {
    const gpa = std.testing.allocator;
    // ZRANGEBYSCORE 对一个从未被 ZADD 过的 key（这个人从来没在
    // hikari:byuser 里出现过——不管是因为他真的没有语录，还是因为他的
    // 语录属于本次改动之前收录、从未被回填过的 136 条历史语录之一）跟
    // "存在但恰好被过滤空了"在协议层面是同一个回复：一个空数组，不是
    // nil、不是错误。randomFiltered 因此对两种成因给出完全相同的结果——
    // 404（经 server.zig），这正是 store.zig 顶部 key_byuser_prefix 注释
    // 里记录的、本次改动刻意接受的已知行为。
    const srv = try FakeServer.start(gpa, "*0\r\n");
    defer {
        srv.stop();
        srv.received.deinit(gpa);
        gpa.destroy(srv);
    }
    var c = try redis.Client.connect(gpa, "127.0.0.1", srv.port(), null, 0);
    defer c.deinit();
    var store = Store.init(gpa, &c);
    try std.testing.expectEqual(@as(?Quote, null), try store.randomFiltered(gpa, .{ .user_id = 99999 }));
}

test "randomFiltered 只有长度、没有 user_id 时委托给 randomByLength（跟改动前逐字节相同）" {
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
    try std.testing.expectEqual(@as(?Quote, null), try store.randomFiltered(gpa, .{ .min_length = 1, .max_length = 100 }));
    c.deinit();
    srv.stop();
    try std.testing.expect(std.mem.indexOf(u8, srv.received.items, "hikari:bylen") != null);
    try std.testing.expect(std.mem.indexOf(u8, srv.received.items, "hikari:byuser") == null);
}

test "randomFiltered 全空（无 user_id 无长度）时委托给 randomAny" {
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
    try std.testing.expectEqual(@as(?Quote, null), try store.randomFiltered(gpa, .{}));
    c.deinit();
    srv.stop();
    try std.testing.expect(std.mem.indexOf(u8, srv.received.items, "SRANDMEMBER") != null);
    try std.testing.expect(std.mem.indexOf(u8, srv.received.items, key_index) != null);
}

// ---------------------------------------------------------------------------
// hikari:username / hikari:groupname —— 改名一次性反映到全部历史语录。
// setUsername/setGroupName 是 scan/runner.zig 每次扫描按遇到的作者/群刷新
// 这两个键的落点；resolveDisplayNames（经 fetchById，randomAny 是它最简单的
// 入口）是渲染时读它们、决定"改名覆盖"还是"回退到 hash 里的旧快照"的落点。
// 136 条现存生产语录全部落在 fallback 分支——见 resolveDisplayNames 顶部的
// 说明与下面"fallback"测试的注释，不需要任何迁移脚本。

test "setUsername 发 SET hikari:username:{user_id}" {
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

    try store.setUsername(10001, "新名字");

    c.deinit();
    srv.stop();
    try expectFrameSequence(srv.received.items, &.{
        "*3\r\n$3\r\nSET\r\n$21\r\nhikari:username:10001\r\n$9\r\n新名字\r\n",
    });
}

test "setGroupName 发 SET hikari:groupname:{group_id}" {
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

    try store.setGroupName(999, "新群名");

    c.deinit();
    srv.stop();
    try expectFrameSequence(srv.received.items, &.{
        "*3\r\n$3\r\nSET\r\n$20\r\nhikari:groupname:999\r\n$9\r\n新群名\r\n",
    });
}

test "randomAny：hikari:username/hikari:groupname 命中时覆盖 hash 里冻结的 from_who/from（改名场景）" {
    const gpa = std.testing.allocator;
    const args = try hashFields(gpa, sampleQuote());
    defer freeHashFields(gpa, args);
    const hgetall_reply = try encodeArrayReply(gpa, args[2..]);
    defer gpa.free(hgetall_reply);

    // sampleQuote() 收录时冻结的快照是 from_who="小明"、from="测试群"。这里
    // 模拟"小明"改名成 NewName、群改名成 NewGroup 之后的一次渲染：MGET 命中
    // 两个键，覆盖必须真的发生，不能停留在 hash 里的旧值上——这正是这次改动
    // 要解决的问题本身。
    const script = try std.mem.concat(gpa, u8, &.{
        "$5\r\n12345\r\n", hgetall_reply, "*2\r\n$7\r\nNewName\r\n$8\r\nNewGroup\r\n",
    });
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

    try std.testing.expectEqualStrings("NewName", q.from_who);
    try std.testing.expectEqualStrings("NewGroup", q.from);
    // 其余字段不受影响，改名覆盖只碰这两个字段。
    try std.testing.expectEqualStrings("今天也是好天气", q.hitokoto);
}

test "randomAny：hikari:username/hikari:groupname 缺失（nil）时落回 hash 里存的旧值——fallback，覆盖 import 语录与从未被刷新过的作者" {
    const gpa = std.testing.allocator;
    const args = try hashFields(gpa, sampleQuote());
    defer freeHashFields(gpa, args);
    const hgetall_reply = try encodeArrayReply(gpa, args[2..]);
    defer gpa.free(hgetall_reply);

    // 两个键都没写过（MGET 回两个 nil）：136 条现存生产语录的处境完全一样
    // ——它们的 hash 早就带着 user_id/group_id，但 hikari:username/
    // hikari:groupname 这两个键在这次改动之前根本不存在，MGET 对它们必然
    // 回 nil。不需要任何迁移脚本：这条 fallback 分支本来就是为它们准备的。
    const script = try std.mem.concat(gpa, u8, &.{ "$5\r\n12345\r\n", hgetall_reply, mget_nil_reply });
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

    try std.testing.expectEqualStrings("小明", q.from_who);
    try std.testing.expectEqualStrings("测试群", q.from);
}

test "randomAny：resolveDisplayNames 的 MGET 收到 -ERR 回复时向上传播 error.RedisError，不是静默落回 hash 的旧值" {
    const gpa = std.testing.allocator;
    const args = try hashFields(gpa, sampleQuote());
    defer freeHashFields(gpa, args);
    const hgetall_reply = try encodeArrayReply(gpa, args[2..]);
    defer gpa.free(hgetall_reply);

    // MGET 回一个合法的 RESP error（"-ERR ...\r\n"）——这不是传输层/协议层
    // 失败（`self.client.command` 本身不会因为收到 `.err` 而 `try` 失败，
    // 那是 commandOk/commandInt 自己转换的），是服务端明确拒绝了这条命令。
    // resolveDisplayNames 必须把它当成一个真正的 Error 传播出去，不能落进
    // "当作没找到、退回 hash 旧值"这条分支——见该方法文档注释：这是单连接
    // 协议，一条读到一半的失败意味着后续帧对齐都不再可信，不能被静默吞掉
    // 伪装成一次内容层面的巧合。
    const script = try std.mem.concat(gpa, u8, &.{ "$5\r\n12345\r\n", hgetall_reply, "-ERR unknown command 'MGET'\r\n" });
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

    try std.testing.expectError(error.RedisError, store.randomAny(gpa));
}

test "randomAny：作者已经离群——hikari:username 从未刷新成功过时同样落回旧值（fallback 的另一种成因，不是另一条代码路径）" {
    const gpa = std.testing.allocator;
    const args = try hashFields(gpa, sampleQuote());
    defer freeHashFields(gpa, args);
    const hgetall_reply = try encodeArrayReply(gpa, args[2..]);
    defer gpa.free(hgetall_reply);

    // 群本身还在（hikari:groupname 命中，覆盖成 NewGroup2），但这条语录的
    // 作者已经离群：他从这次改动上线起就再也没被任何一次扫描当过候选作者，
    // hikari:username:10001 从来没被 setUsername 写过，MGET 对它回 nil——
    // 跟上一条"从未刷新过"测试机制完全相同，单独起一条是为了让 brief 明确
    // 点名的"作者离群"场景在测试列表里有名字对得上号的一条。
    const script = try std.mem.concat(gpa, u8, &.{
        "$5\r\n12345\r\n", hgetall_reply, "*2\r\n$-1\r\n$9\r\nNewGroup2\r\n",
    });
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

    try std.testing.expectEqualStrings("小明", q.from_who); // fallback：作者已经离群
    try std.testing.expectEqualStrings("NewGroup2", q.from); // 群名照常覆盖
}

fn checkRandomAnyDisplayNameAlloc(gpa: std.mem.Allocator) !void {
    const net_gpa = std.testing.allocator;
    const args = try hashFields(net_gpa, sampleQuote());
    defer freeHashFields(net_gpa, args);
    const hgetall_reply = try encodeArrayReply(net_gpa, args[2..]);
    defer net_gpa.free(hgetall_reply);

    const script = try std.mem.concat(net_gpa, u8, &.{
        "$5\r\n12345\r\n", hgetall_reply, "*2\r\n$7\r\nNewName\r\n$8\r\nNewGroup\r\n",
    });
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

    if (try st.randomAny(gpa)) |q| q.deinit(gpa);
}

test "randomAny 的 hikari:username/hikari:groupname 覆盖路径（resolveDisplayNames 的两次 gpa.dupe）在分配失败时不泄漏（checkAllAllocationFailures）" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkRandomAnyDisplayNameAlloc, .{});
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

    const script = try std.mem.concat(gpa, u8, &.{ smembers, h1, mget_nil_reply, h2, mget_nil_reply });
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
    const script = try std.mem.concat(gpa, u8, &.{
        srandmember, h, mget_nil_reply, h, mget_nil_reply, h, mget_nil_reply,
    });
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

    const script = try std.mem.concat(net_gpa, u8, &.{ smembers, h1, mget_nil_reply, h2, mget_nil_reply });
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

// ---------------------------------------------------------------------------
// allFiltered / randomManyFiltered / fetchSampled —— `/extra/all` 与
// `/extra/batch/:count` 上的 `user_id`/长度过滤。跟上面 randomFiltered 一样，
// `isUnfiltered()` 时逐字节委托给 allQuotes/randomMany；带任何过滤时才会走
// ZRANGEBYSCORE + fetchMany/fetchSampled 这条全新的路径。

test "allFiltered 带 user_id 时走 hikari:byuser + 逐个 HGETALL 展开，命令帧" {
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

    // ZRANGEBYSCORE hikari:byuser:10001 0 4294967295 -> {"12345", "999"}
    // （sampleQuote 与 q2 都是作者 10001 的语录）。
    const script = try std.mem.concat(gpa, u8, &.{
        "*2\r\n$5\r\n12345\r\n$3\r\n999\r\n",
        h1,
        mget_nil_reply,
        h2,
        mget_nil_reply,
    });
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

    const quotes = try store.allFiltered(gpa, .{ .user_id = 10001 });
    defer {
        for (quotes) |q| q.deinit(gpa);
        gpa.free(quotes);
    }
    try std.testing.expectEqual(@as(usize, 2), quotes.len);

    c.deinit();
    srv.stop();
    try std.testing.expect(std.mem.indexOf(
        u8,
        srv.received.items,
        "*4\r\n$13\r\nZRANGEBYSCORE\r\n$19\r\nhikari:byuser:10001\r\n$1\r\n0\r\n$10\r\n4294967295\r\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, srv.received.items, "hikari:quote:12345") != null);
    try std.testing.expect(std.mem.indexOf(u8, srv.received.items, "hikari:quote:999") != null);
    try std.testing.expect(std.mem.indexOf(u8, srv.received.items, "SMEMBERS") == null);
}

test "allFiltered 全空时委托给 allQuotes（逐字节相同）" {
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

    const quotes = try store.allFiltered(gpa, .{});
    defer gpa.free(quotes);
    try std.testing.expectEqual(@as(usize, 0), quotes.len);

    c.deinit();
    srv.stop();
    try std.testing.expect(std.mem.indexOf(u8, srv.received.items, "SMEMBERS") != null);
    try std.testing.expect(std.mem.indexOf(u8, srv.received.items, "ZRANGEBYSCORE") == null);
}

test "allFiltered：user_id 过滤后候选为空返回长度 0 的切片（对应无索引的历史语录场景）" {
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

    const quotes = try store.allFiltered(gpa, .{ .user_id = 99999 });
    defer gpa.free(quotes);
    try std.testing.expectEqual(@as(usize, 0), quotes.len);
}

test "randomManyFiltered 带 user_id 时有放回抽样——同一个 id 被抽中 3 次，各自单独 HGETALL（允许重复）" {
    const gpa = std.testing.allocator;
    const args = try hashFields(gpa, sampleQuote());
    defer freeHashFields(gpa, args);
    const hgetall_reply = try encodeArrayReply(gpa, args[2..]);
    defer gpa.free(hgetall_reply);

    // 候选集合只有一个 id（"12345"），count=3：uintLessThan(1) 恒为 0，
    // 三次抽样确定性地都落在同一个 id 上，脚本据此重复三份 HGETALL+MGET。
    const one_fetch = try std.mem.concat(gpa, u8, &.{ hgetall_reply, mget_nil_reply });
    defer gpa.free(one_fetch);
    const script = try std.mem.concat(gpa, u8, &.{
        "*1\r\n$5\r\n12345\r\n",
        one_fetch,
        one_fetch,
        one_fetch,
    });
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

    const quotes = try store.randomManyFiltered(gpa, .{ .user_id = 10001 }, 3);
    defer {
        for (quotes) |q| q.deinit(gpa);
        gpa.free(quotes);
    }
    try std.testing.expectEqual(@as(usize, 3), quotes.len);

    c.deinit();
    srv.stop();
    try std.testing.expect(std.mem.indexOf(
        u8,
        srv.received.items,
        "*4\r\n$13\r\nZRANGEBYSCORE\r\n$19\r\nhikari:byuser:10001\r\n$1\r\n0\r\n$10\r\n4294967295\r\n",
    ) != null);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, srv.received.items, "HGETALL"));
    try std.testing.expect(std.mem.indexOf(u8, srv.received.items, "SRANDMEMBER") == null);
}

test "randomManyFiltered 全空时委托给 randomMany（逐字节相同，负数 SRANDMEMBER）" {
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

    const quotes = try store.randomManyFiltered(gpa, .{}, 5);
    defer gpa.free(quotes);
    try std.testing.expectEqual(@as(usize, 0), quotes.len);

    c.deinit();
    srv.stop();
    try std.testing.expect(std.mem.indexOf(u8, srv.received.items, "SRANDMEMBER") != null);
    try std.testing.expect(std.mem.indexOf(u8, srv.received.items, "-5") != null);
}

test "randomManyFiltered：user_id 过滤后候选为空返回长度 0 的切片，不崩" {
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

    const quotes = try store.randomManyFiltered(gpa, .{ .user_id = 99999 }, 5);
    defer gpa.free(quotes);
    try std.testing.expectEqual(@as(usize, 0), quotes.len);
}

/// checkAllAllocationFailures 专用：跟 checkAllQuotesAlloc 同一套纪律（网络层
/// 全部用不参与失败注入的 net_gpa），这里专门覆盖 fetchSampled——它是这次
/// 改动新增的函数，虽然清理逻辑跟 fetchMany 逐字同构，但复制出来的这份
/// 代码没有理由假定它"自动"继承 fetchMany 已经测过的保证，必须单独证明。
fn checkFetchSampledAlloc(gpa: std.mem.Allocator) !void {
    const net_gpa = std.testing.allocator;

    const args = try hashFields(net_gpa, sampleQuote());
    defer freeHashFields(net_gpa, args);
    const h = try encodeArrayReply(net_gpa, args[2..]);
    defer net_gpa.free(h);

    const one_fetch = try std.mem.concat(net_gpa, u8, &.{ h, mget_nil_reply });
    defer net_gpa.free(one_fetch);
    const script = try std.mem.concat(net_gpa, u8, &.{
        "*1\r\n$5\r\n12345\r\n",
        one_fetch,
        one_fetch,
    });
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

    const quotes = try st.randomManyFiltered(gpa, .{ .user_id = 10001 }, 2);
    for (quotes) |q| q.deinit(gpa);
    gpa.free(quotes);
}

test "fetchSampled（经 randomManyFiltered）在分配失败时不泄漏、不重复释放（checkAllAllocationFailures）" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkFetchSampledAlloc, .{});
}

// ---------------------------------------------------------------------------
// reindexByUser（`hikari reindex`）：把 `hikari:index` 里已有的语录逐条补进
// `hikari:byuser:{user_id}`。这是一条**只由运营方手动触发**的修复路径，进程
// 启动、扫描、任何读路径都不会碰它——见 reindexByUser 的文档注释。

test "reindexByUser：SMEMBERS 之后逐条 HMGET，问到作者与长度就 ZADD 进 hikari:byuser" {
    const gpa = std.testing.allocator;
    // 索引里三条：12345（🔥 链语录的主键，正数 message_id）、-4242（hikari
    // import 写进来的语录，合成的负数 message_id）、777（hash 已经不在了的
    // 悬空 id）。脚本依次是 SMEMBERS 回复、三次 HMGET 回复、两次 ZADD 回复。
    const script = "*3\r\n$5\r\n12345\r\n$5\r\n-4242\r\n$3\r\n777\r\n" ++ // SMEMBERS hikari:index
        "*2\r\n$5\r\n10001\r\n$1\r\n7\r\n" ++ // HMGET hikari:quote:12345 -> user_id=10001, length=7
        ":1\r\n" ++ // ZADD hikari:byuser:10001
        "*2\r\n$5\r\n20002\r\n$2\r\n12\r\n" ++ // HMGET hikari:quote:-4242 -> user_id=20002, length=12
        ":1\r\n" ++ // ZADD hikari:byuser:20002
        "*2\r\n$-1\r\n$-1\r\n"; // HMGET hikari:quote:777 -> 两个字段都 nil（hash 不在了）
    const srv = try FakeServer.start(gpa, script);
    defer {
        srv.stop();
        srv.received.deinit(gpa);
        gpa.destroy(srv);
    }
    var c = try redis.Client.connect(gpa, "127.0.0.1", srv.port(), null, 0);
    defer c.deinit();
    var store = Store.init(gpa, &c);

    const s = try store.reindexByUser();
    try std.testing.expectEqual(@as(usize, 3), s.seen);
    try std.testing.expectEqual(@as(usize, 2), s.reindexed);
    try std.testing.expectEqual(@as(usize, 1), s.missing_hash);
    try std.testing.expectEqual(@as(usize, 1), s.skipped());

    c.deinit();
    srv.stop();

    // 帧必须逐字节钉死：只查 "ZADD" 与 "hikari:byuser:10001" 两个子串各自
    // 存在，会让 score 与 member 换位（`ZADD key 12345 7`）照样通过——这个
    // 仓库已经因为两条独立的 indexOf 断言放过一次参数换位了。
    try expectFrameSequence(srv.received.items, &.{
        "*2\r\n$8\r\nSMEMBERS\r\n$12\r\nhikari:index\r\n",
        "*4\r\n$5\r\nHMGET\r\n$18\r\nhikari:quote:12345\r\n$7\r\nuser_id\r\n$6\r\nlength\r\n",
        "*4\r\n$4\r\nZADD\r\n$19\r\nhikari:byuser:10001\r\n$1\r\n7\r\n$5\r\n12345\r\n",
        "*4\r\n$5\r\nHMGET\r\n$18\r\nhikari:quote:-4242\r\n$7\r\nuser_id\r\n$6\r\nlength\r\n",
        "*4\r\n$4\r\nZADD\r\n$19\r\nhikari:byuser:20002\r\n$2\r\n12\r\n$5\r\n-4242\r\n",
        "*4\r\n$5\r\nHMGET\r\n$16\r\nhikari:quote:777\r\n$7\r\nuser_id\r\n$6\r\nlength\r\n",
    });
    // 悬空 id 不产生任何写命令：reindex 只补索引，绝不创造语录。
    try std.testing.expect(std.mem.indexOf(u8, srv.received.items, "hikari:byuser:0") == null);
}

test "reindexByUser：连跑两次——第二次逐字节发出同一串命令，ZADD 覆盖是无害的" {
    const gpa = std.testing.allocator;
    const first = "*1\r\n$5\r\n12345\r\n" ++ "*2\r\n$5\r\n10001\r\n$1\r\n7\r\n" ++ ":1\r\n";
    // 第二次：同样的索引、同样的 hash，ZADD 回 0（成员已经在，score 原样
    // 覆盖）。幂等在这里的准确含义不是"第二次什么都不发"，而是"第二次发的
    // 是同一串命令，且不改变任何状态"——ZADD 是幂等的，所以可以随便重跑。
    const second = "*1\r\n$5\r\n12345\r\n" ++ "*2\r\n$5\r\n10001\r\n$1\r\n7\r\n" ++ ":0\r\n";
    const srv = try FakeServer.start(gpa, first ++ second);
    defer {
        srv.stop();
        srv.received.deinit(gpa);
        gpa.destroy(srv);
    }
    var c = try redis.Client.connect(gpa, "127.0.0.1", srv.port(), null, 0);
    defer c.deinit();
    var store = Store.init(gpa, &c);

    const a = try store.reindexByUser();
    const b = try store.reindexByUser();
    try std.testing.expectEqual(a, b);
    try std.testing.expectEqual(@as(usize, 1), b.reindexed);
    try std.testing.expectEqual(@as(usize, 0), b.skipped());

    c.deinit();
    srv.stop();

    // 整个连接上发出去的字节 = 同一串三条命令，原样两遍。用等值断言而不是
    // 逐帧查找：这条测试要说的正是"第二次没有多发、也没有少发任何东西"。
    const once = "*2\r\n$8\r\nSMEMBERS\r\n$12\r\nhikari:index\r\n" ++
        "*4\r\n$5\r\nHMGET\r\n$18\r\nhikari:quote:12345\r\n$7\r\nuser_id\r\n$6\r\nlength\r\n" ++
        "*4\r\n$4\r\nZADD\r\n$19\r\nhikari:byuser:10001\r\n$1\r\n7\r\n$5\r\n12345\r\n";
    try std.testing.expectEqualStrings(once ++ once, srv.received.items);
}

test "reindexByUser：空索引只发一条 SMEMBERS，一条 HMGET 都不发" {
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

    const s = try store.reindexByUser();
    try std.testing.expectEqual(@as(usize, 0), s.seen);
    try std.testing.expectEqual(@as(usize, 0), s.reindexed);
    try std.testing.expectEqual(@as(usize, 0), s.skipped());

    c.deinit();
    srv.stop();
    try std.testing.expectEqualStrings("*2\r\n$8\r\nSMEMBERS\r\n$12\r\nhikari:index\r\n", srv.received.items);
}

test "reindexByUser：字段缺失的三种情形各自归类，都不发 ZADD" {
    const gpa = std.testing.allocator;
    // 三条索引成员：1（只缺 user_id）、2（只缺 length）、3（length 不是
    // 数字）。三条都必须被跳过并各自计数，而不是拿 0 当默认值写进
    // hikari:byuser:0 ——那会造出一个谁也查不到、却真实存在的假索引。
    const script = "*3\r\n$1\r\n1\r\n$1\r\n2\r\n$1\r\n3\r\n" ++
        "*2\r\n$-1\r\n$1\r\n7\r\n" ++
        "*2\r\n$5\r\n10001\r\n$-1\r\n" ++
        "*2\r\n$5\r\n10001\r\n$3\r\nabc\r\n";
    const srv = try FakeServer.start(gpa, script);
    defer {
        srv.stop();
        srv.received.deinit(gpa);
        gpa.destroy(srv);
    }
    var c = try redis.Client.connect(gpa, "127.0.0.1", srv.port(), null, 0);
    defer c.deinit();
    var store = Store.init(gpa, &c);

    const s = try store.reindexByUser();
    try std.testing.expectEqual(@as(usize, 3), s.seen);
    try std.testing.expectEqual(@as(usize, 0), s.reindexed);
    try std.testing.expectEqual(@as(usize, 1), s.missing_user_id);
    try std.testing.expectEqual(@as(usize, 2), s.missing_length);
    try std.testing.expectEqual(@as(usize, 3), s.skipped());

    c.deinit();
    srv.stop();
    try std.testing.expect(std.mem.indexOf(u8, srv.received.items, "ZADD") == null);
}

test "reindexByUser：索引里混进一个不是整数的成员 → 记 bad_id，不去碰它的 hash" {
    const gpa = std.testing.allocator;
    const script = "*2\r\n$3\r\nnah\r\n$5\r\n12345\r\n" ++
        "*2\r\n$5\r\n10001\r\n$1\r\n7\r\n" ++ ":1\r\n";
    const srv = try FakeServer.start(gpa, script);
    defer {
        srv.stop();
        srv.received.deinit(gpa);
        gpa.destroy(srv);
    }
    var c = try redis.Client.connect(gpa, "127.0.0.1", srv.port(), null, 0);
    defer c.deinit();
    var store = Store.init(gpa, &c);

    const s = try store.reindexByUser();
    try std.testing.expectEqual(@as(usize, 2), s.seen);
    try std.testing.expectEqual(@as(usize, 1), s.reindexed);
    try std.testing.expectEqual(@as(usize, 1), s.bad_id);

    c.deinit();
    srv.stop();
    try std.testing.expect(std.mem.indexOf(u8, srv.received.items, "hikari:quote:nah") == null);
}

test "formatReindexSummary 产出的文本带全部计数与各自的跳过原因" {
    const gpa = std.testing.allocator;
    const s: ReindexSummary = .{
        .seen = 136,
        .reindexed = 130,
        .bad_id = 1,
        .missing_hash = 2,
        .missing_user_id = 1,
        .missing_length = 2,
    };
    const text = try formatReindexSummary(gpa, s);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "136") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "130") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "no quote hash 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "no user_id 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "no length 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "malformed index member 1") != null);
}

fn checkReindexAlloc(gpa: std.mem.Allocator) !void {
    const net_gpa = std.testing.allocator;
    const script = "*3\r\n$5\r\n12345\r\n$5\r\n-4242\r\n$3\r\n777\r\n" ++
        "*2\r\n$5\r\n10001\r\n$1\r\n7\r\n" ++ ":1\r\n" ++
        "*2\r\n$5\r\n20002\r\n$2\r\n12\r\n" ++ ":1\r\n" ++
        "*2\r\n$-1\r\n$-1\r\n";
    const srv = try FakeServer.start(net_gpa, script);
    defer {
        srv.stop();
        srv.received.deinit(net_gpa);
        net_gpa.destroy(srv);
    }
    var c = try redis.Client.connect(net_gpa, "127.0.0.1", srv.port(), null, 0);
    defer c.deinit();
    var st = Store.init(gpa, &c);
    _ = try st.reindexByUser();
}

test "reindexByUser 在分配失败时不泄漏（checkAllAllocationFailures）" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkReindexAlloc, .{});
}

fn checkFormatReindexSummaryAlloc(gpa: std.mem.Allocator) !void {
    const text = try formatReindexSummary(gpa, .{ .seen = 136, .reindexed = 130, .missing_hash = 6 });
    gpa.free(text);
}

test "formatReindexSummary 在分配失败时不泄漏（checkAllAllocationFailures）" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkFormatReindexSummaryAlloc, .{});
}
