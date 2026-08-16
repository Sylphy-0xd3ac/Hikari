const std = @import("std");
const runner = @import("scan/runner.zig");
const store = @import("store.zig");

const ws = " \t\r\n";

/// 一段被 fixed seed 固定住的 Wyhash 种子，只在这个文件里用，跟其他任何哈希
/// 用途不共享——换种子会让所有已导入语录在下一次 import 时被判定为"新文本"，
/// 全部重复入库一遍，所以这个常量一旦跑过一次生产导入就不能再改。
const id_seed: u64 = 0x48696b6172694332; // "HikariC2" 的 ASCII，纯粹为了不用 0

/// 把导入行的文本确定性地映射成一个负的 message_id。
///
/// 为什么必须是负数：真实的 NapCat 短 id 出自 MessageUnique.createUniqueMsgId，
/// 其实现对 MD5 结果的最高字节做 `hash[0] &= 0x7f`（清最高位）后再转换，
/// 所以真实短 id 在构造上恒为非负数。只要保证合成 id 恒为负，就与任何真实
/// id 从两个不相交的取值集合里各取一个，天然不会相撞——不需要跟 NapCat 或
/// 历史数据做任何比对。
///
/// 为什么必须是文本的确定性函数而不是自增序号：`message_id` 是
/// `hikari:quote:{message_id}` 的主键，重新运行 import 时唯一能让第二次的
/// 候选 id 落在 store.exists() 已知集合里的办法，就是同一行文本两次算出
/// 同一个 id。自增序号做不到——每次进程重启序号从哪起都不确定，就算确定，
/// 文件里插入/删除一行也会让后面所有行的 id 整体错位，第二次运行会把整份
/// 语录当成"从未见过"重新写一遍。
///
/// 碰撞：63 位取值空间下，118 行文本发生哈希碰撞是生日悖论量级的天文小
/// 概率。即便真的发生，后果也只是其中一行被 exists()/isTombstoned() 误判
/// 而跳过（或者反过来，日后重新导入时被当成是另一行的重复），不是数据
/// 损坏，本实现不做碰撞检测或处理。
pub fn deriveId(text: []const u8) i64 {
    const h = std.hash.Wyhash.hash(id_seed, text);
    // 清最高位压进 [0, 2^63) 再 |1 保证非零（h>>1 == 0 只有 h 本身是 0 或 1
    // 时才会发生，但即便如此也要保底，避免 0 取负后仍是 0，不满足"恒为负"）。
    const magnitude: u64 = (h >> 1) | 1;
    // magnitude 落在 [1, 2^63-1]，稳稳落在 i64 的表示范围内，取负不会溢出
    // （i64 最小值是 -2^63，比 -(2^63-1) 还小一）。
    return -@as(i64, @intCast(magnitude));
}

/// 一段文件内容按行拆开、trim 掉首尾空白（与 onebot.Message.renderText 用的
/// 空白字符集一致），空行（trim 后长度为 0）整行丢弃、只计数，不进 `lines`。
///
/// `lines` 借用 `contents` 的内存（切片，不拷贝），调用方必须保证 `contents`
/// 活得比 `lines` 久。
pub const ParsedLines = struct {
    lines: [][]const u8,
    /// 文件里出现的换行分隔段总数，包括被跳过的空行；如果文件以换行符结尾，
    /// 会多算一段末尾的空段（这本身也会被计入 blank_skipped）。这是个粗粒度
    /// 的"读到了多少行"计数，用于摘要输出，不追求跟人眼数出来的行数位位对齐。
    total: usize,
    blank_skipped: usize,
};

pub fn parseLines(gpa: std.mem.Allocator, contents: []const u8) !ParsedLines {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);

    var total: usize = 0;
    var blank_skipped: usize = 0;
    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |raw| {
        total += 1;
        const t = std.mem.trim(u8, raw, ws);
        if (t.len == 0) {
            blank_skipped += 1;
            continue;
        }
        try out.append(gpa, t);
    }
    return .{ .lines = try out.toOwnedSlice(gpa), .total = total, .blank_skipped = blank_skipped };
}

/// 落库前的三道关卡，跟 scanGroup 第 7 步的判定顺序一致：先看这条消息有没
/// 有被作废过，再看是不是已经入过库，最后（防御性地）看文本是不是空的——
/// 这条在 import 的调用路径里理论上永远不会命中，因为 parseLines 已经把
/// 空行滤掉了；留着它是为了让优先级顺序有一处能独立单测、不用起 Redis 的
/// 说明，也防着以后有别的调用方拿未经 parseLines 处理的文本直接喂进来。
///
/// 这个函数本身**不是** importLine 实际调用的代码路径：importLine 为了
/// 少打一次 Redis 往返，跟 scanGroup 一样用短路的 if 链——查到已作废就
/// 不再查是否已存在。这里把同样的优先级顺序抽成一个把两个布尔值都当
/// 参数收下的纯函数，只是为了能在不跑 Redis 的前提下把"tombstoned 优先于
/// exists 优先于 empty"这条规则钉成一个测试。
pub const Gate = enum { proceed, tombstoned, exists, empty };

pub fn gateCheck(trimmed_text: []const u8, tombstoned: bool, exists: bool) Gate {
    if (tombstoned) return .tombstoned;
    if (exists) return .exists;
    if (trimmed_text.len == 0) return .empty;
    return .proceed;
}

/// 摘要计数：总行数、跳过的空行，以及每条候选最终落在哪个关卡上。
pub const Summary = struct {
    total_lines: usize = 0,
    blank_skipped: usize = 0,
    added: usize = 0,
    tombstoned_skipped: usize = 0,
    exists_skipped: usize = 0,
    empty_skipped: usize = 0,
    write_failed: usize = 0,

    pub fn skipped(self: Summary) usize {
        return self.blank_skipped + self.tombstoned_skipped + self.exists_skipped + self.empty_skipped;
    }
};

pub fn formatSummary(gpa: std.mem.Allocator, s: Summary) ![]u8 {
    return std.fmt.allocPrint(gpa,
        \\Read {d} line(s) from file.
        \\Added {d}, skipped {d} (blank {d}, tombstoned {d}, already in store {d}, empty {d}), failed to write {d}.
        \\
    , .{
        s.total_lines,
        s.added,
        s.skipped(),
        s.blank_skipped,
        s.tombstoned_skipped,
        s.exists_skipped,
        s.empty_skipped,
        s.write_failed,
    });
}

/// 单行的落库过程：算 id -> 过三道关卡 -> 建语录 -> 写。跟 scanGroup 第 7 步
/// 的顺序、关卡语义完全一致，唯一的区别是 commit_from 固定为 "import"，
/// message_id 是 deriveId 算出来的合成负数，created_at 是导入时刻而不是
/// 消息原始时间（这条文本压根没有"消息原始时间"）。
///
/// isTombstoned / exists / nextId 的 Redis 错误直接 try 向上传播，中止整个
/// import——这类错误意味着 Redis 连不上了或者协议解析坏了，继续往下逐行跑
/// 只会重复报同一个错误，没有价值。store.add 的失败则单独捕获计数、继续
/// 处理下一行，跟 scanGroup 对 add_failed 的处理方式一样：这一行没写进去，
/// 下次重新 import 同一个文件时它还会被重试（因为它没进 hikari:index，
/// exists() 还是 false）。
fn importLine(
    deps: runner.Deps,
    text: []const u8,
    from: []const u8,
    from_who: []const u8,
    group_id: u64,
    /// 导入进来的这批语录算谁说的。命令行还没有 --user 之前，取
    /// OBSERVED_QQS 的第一个；观察全员（空集）时没有可归属的人，调用方
    /// 在进入循环之前就已经拒绝了，不会走到这里。
    attribution_qq: u64,
    now: i64,
    summary: *Summary,
) !void {
    const mid = deriveId(text);

    // 短路：跟 scanGroup 一样，查到已作废就不用再多打一次 Redis 往返去查
    // 是否已存在。gateCheck 单测了这条优先级规则；这里就是它的实际实现。
    if (try deps.st.isTombstoned(mid)) {
        summary.tombstoned_skipped += 1;
        return;
    }
    if (try deps.st.exists(mid)) {
        summary.exists_skipped += 1;
        return;
    }
    if (text.len == 0) {
        summary.empty_skipped += 1;
        return;
    }

    const id = try deps.st.nextId();
    const q = try runner.buildQuote(deps.gpa, .{
        .id = id,
        .text = text,
        .from = from,
        .from_who = from_who,
        .created_at = now,
        .message_id = mid,
        .group_id = group_id,
        .user_id = attribution_qq,
        .commit_from = "import",
    });
    defer runner.freeQuote(deps.gpa, q);

    deps.st.add(q) catch |e| {
        std.log.warn("import: writing synthetic id {d} failed: {s}", .{ mid, @errorName(e) });
        summary.write_failed += 1;
        return;
    };
    summary.added += 1;
}

/// 读文件、按行导入。`deps.group_ids[0]` 是唯一使用的群——config.load 保证
/// `group_ids` 至少有一个元素（parseUintList 对空列表返回 error），所以这里
/// 直接下标取而不再判空。
///
/// 归属（群名 / 被观察者名片）解析不出来就直接 error.AttributionUnavailable，
/// 一条都不写：跟 scanGroup 同样的理由，但这里更严格——scanGroup 至少还有
/// "这个群这一轮失败，下次/补跑再试"的退路，import 是一次性手工操作，没有
/// 重跑窗口的概念，写出去的残缺归属字段就是永久的（design.md：入库后只能
/// 被 💦 作废，没有编辑路径）。
pub fn run(deps: runner.Deps, path: []const u8, now: i64) !Summary {
    const contents = try std.fs.cwd().readFileAlloc(deps.gpa, path, 64 * 1024 * 1024);
    defer deps.gpa.free(contents);

    const parsed = try parseLines(deps.gpa, contents);
    defer deps.gpa.free(parsed.lines);

    var summary: Summary = .{ .total_lines = parsed.total, .blank_skipped = parsed.blank_skipped };

    var ar = std.heap.ArenaAllocator.init(deps.gpa);
    defer ar.deinit();
    const a = ar.allocator();

    const group_id = deps.group_ids[0];

    // 观察全员时没有"那一个被观察者"可以把这批语录记在名下。与其静默挑一个
    // 或者写个空归属（入库后没有编辑路径，写错就是永久的），不如直接拒绝，
    // 等 --user 参数落地后由操作者显式指定。
    const attribution_qq = if (deps.observed_qqs.len == 0)
        return error.AttributionUnavailable
    else
        deps.observed_qqs[0];

    const from = runner.groupName(deps, a, group_id) orelse return error.AttributionUnavailable;
    const from_who = runner.memberCard(deps, a, group_id, attribution_qq) orelse return error.AttributionUnavailable;

    for (parsed.lines) |line| {
        try importLine(deps, line, from, from_who, group_id, attribution_qq, now, &summary);
    }

    return summary;
}

// ---------------------------------------------------------------------------
// 纯函数测试：id 推导的确定性/负性/区分度，行解析的 trim/空行处理，
// 关卡判定与摘要计数。

test "deriveId 对同一段文本恒定输出同一个 id" {
    const a = deriveId("我不是给");
    const b = deriveId("我不是给");
    try std.testing.expectEqual(a, b);
}

test "deriveId 对不同文本给出不同 id" {
    const a = deriveId("我不是给");
    const b = deriveId("67");
    const c = deriveId("请善待二旬老人");
    try std.testing.expect(a != b);
    try std.testing.expect(b != c);
    try std.testing.expect(a != c);
}

test "deriveId 的输出恒为负数，覆盖多种输入形状" {
    const samples = [_][]const u8{
        "",
        "a",
        "67",
        "我不是给",
        "@bobo@bobo我是 gay 都行",
        "@蓝影Shadow 那需要不少电，先生",
        "x" ** 500,
    };
    for (samples) |s| {
        try std.testing.expect(deriveId(s) < 0);
    }
}

test "deriveId 永不为 0" {
    // 0 不是负数：即便某个输入让 Wyhash 输出恰好是 0 或 1，magnitude 的 |1
    // 兜底也必须保证结果非零。这里用大量不同输入扫一遍，不指望撞上那个
    // 具体输入，只是确认没有任何一次输出踩到 0。
    var i: u32 = 0;
    var buf: [16]u8 = undefined;
    while (i < 10000) : (i += 1) {
        const s = std.fmt.bufPrint(&buf, "line-{d}", .{i}) catch unreachable;
        try std.testing.expect(deriveId(s) != 0);
    }
}

test "parseLines 跳过空行与纯空白行，trim 首尾空白" {
    const gpa = std.testing.allocator;
    const content = "我不是给\n \n67\n\t\n请善待二旬老人\n";
    const parsed = try parseLines(gpa, content);
    defer gpa.free(parsed.lines);

    try std.testing.expectEqual(@as(usize, 3), parsed.lines.len);
    try std.testing.expectEqualStrings("我不是给", parsed.lines[0]);
    try std.testing.expectEqualStrings("67", parsed.lines[1]);
    try std.testing.expectEqualStrings("请善待二旬老人", parsed.lines[2]);
    // splitScalar 在末尾的 '\n' 之后还会多切出一段空段，所以空行数是 3
    // （" "、"\t"、末尾那段空段）而不是肉眼数的 2 段空白行；总段数相应是 6。
    try std.testing.expectEqual(@as(usize, 3), parsed.blank_skipped);
    try std.testing.expectEqual(@as(usize, 6), parsed.total);
}

test "parseLines 保留行内的 @昵称 原样，不做任何变换" {
    const gpa = std.testing.allocator;
    const content = "  @蓝影Shadow 那需要不少电，先生  \r\n";
    const parsed = try parseLines(gpa, content);
    defer gpa.free(parsed.lines);

    try std.testing.expectEqual(@as(usize, 1), parsed.lines.len);
    try std.testing.expectEqualStrings("@蓝影Shadow 那需要不少电，先生", parsed.lines[0]);
}

test "parseLines 空文件产出零行" {
    const gpa = std.testing.allocator;
    const parsed = try parseLines(gpa, "");
    defer gpa.free(parsed.lines);
    try std.testing.expectEqual(@as(usize, 0), parsed.lines.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.blank_skipped);
}

test "gateCheck 判定顺序：tombstoned > exists > empty > proceed" {
    try std.testing.expectEqual(Gate.tombstoned, gateCheck("x", true, true));
    try std.testing.expectEqual(Gate.tombstoned, gateCheck("x", true, false));
    try std.testing.expectEqual(Gate.exists, gateCheck("x", false, true));
    try std.testing.expectEqual(Gate.empty, gateCheck("", false, false));
    try std.testing.expectEqual(Gate.proceed, gateCheck("x", false, false));
}

test "Summary.skipped 汇总四类跳过原因，不含 added / write_failed" {
    const s: Summary = .{
        .total_lines = 10,
        .blank_skipped = 1,
        .added = 3,
        .tombstoned_skipped = 2,
        .exists_skipped = 4,
        .empty_skipped = 0,
        .write_failed = 1,
    };
    try std.testing.expectEqual(@as(usize, 7), s.skipped());
}

test "formatSummary 产出的文本包含全部计数字段" {
    const gpa = std.testing.allocator;
    const s: Summary = .{
        .total_lines = 118,
        .blank_skipped = 1,
        .added = 100,
        .tombstoned_skipped = 2,
        .exists_skipped = 14,
        .empty_skipped = 0,
        .write_failed = 1,
    };
    const text = try formatSummary(gpa, s);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "118") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Added 100") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "failed to write 1") != null);
}

// ---------------------------------------------------------------------------
// 端到端测试：需要一条 Redis 连接与一个 NapCat HTTP 端点。用跟 store.zig /
// napcat.zig 现有单测同样的思路起本地假服务器——Redis 侧按脚本顺序吐预先
// 写好的 RESP 回复（不解析请求内容，只按发出顺序回复），NapCat 侧起一个
// 真的本地 HTTP server，按调用顺序回预先写好的 JSON。
//
// store.zig 里的 FakeServer 只接一条连接：脚本条数如果比客户端实际发的命令
// 少，客户端会卡在读取下一条回复上，测试挂起而不是失败——所以下面两个测试
// 的脚本长度都严格对应 run() 在这条路径上实际会发出的命令/请求数。

const redis = @import("redis/client.zig");
const napcat = @import("napcat.zig");

const FakeRedisServer = struct {
    listener: std.net.Server,
    thread: std.Thread,
    script: []const u8,
    received: std.ArrayList(u8),
    gpa: std.mem.Allocator,
    stopped: bool,

    fn serve(self: *FakeRedisServer) void {
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

    fn start(gpa: std.mem.Allocator, script: []const u8) !*FakeRedisServer {
        const self = try gpa.create(FakeRedisServer);
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

    fn port(self: *FakeRedisServer) u16 {
        return self.listener.listen_address.getPort();
    }

    fn stop(self: *FakeRedisServer) void {
        if (self.stopped) return;
        self.stopped = true;
        self.listener.deinit();
        self.thread.join();
    }
};

/// 接受一条连接，在这条连接上依次收 `replies.len` 个 HTTP 请求、按顺序各
/// 回一个预先写好的 JSON body——跟 napcat.zig「call 发出带 Bearer token
/// 的 POST 请求」测试用的是同一套 std.http.Server 搭法，只是把单次请求-响应
/// 循环了 replies.len 次，好覆盖 groupName + memberCard 两次调用。
const FakeNapcatServer = struct {
    listener: std.net.Server,
    thread: std.Thread,
    replies: []const []const u8,
    gpa: std.mem.Allocator,

    fn serve(self: *FakeNapcatServer) void {
        // 一条连接、依次答完全部 replies——不是每条回复起一条新连接。
        // std.http.Client 默认按 keep-alive 池住到同一 host:port 的连接：
        // 如果这里每答一次就把 socket 关掉，napcat.Client 第二次调用会先
        // 试着复用池子里那条其实已经被我们关掉的连接，写失败报
        // error.RequestFailed，而不是真的发起一条新连接——所以这里必须
        // 老老实实地在同一条连接上循环 receiveHead，模拟真实的 keep-alive
        // 服务端行为。
        const conn = self.listener.accept() catch return;
        defer conn.stream.close();
        var rbuf: [8192]u8 = undefined;
        var wbuf: [8192]u8 = undefined;
        var sr = conn.stream.reader(&rbuf);
        var sw = conn.stream.writer(&wbuf);
        var hs = std.http.Server.init(sr.interface(), &sw.interface);
        for (self.replies) |body| {
            var req = hs.receiveHead() catch return;
            var body_buf: [4096]u8 = undefined;
            const body_reader = req.readerExpectNone(&body_buf);
            if (body_reader.allocRemaining(self.gpa, .unlimited) catch null) |b| self.gpa.free(b);
            req.respond(body, .{
                .status = .ok,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            }) catch return;
        }
    }

    fn start(gpa: std.mem.Allocator, replies: []const []const u8) !*FakeNapcatServer {
        const self = try gpa.create(FakeNapcatServer);
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        self.* = .{
            .listener = try addr.listen(.{ .reuse_address = true }),
            .thread = undefined,
            .replies = replies,
            .gpa = gpa,
        };
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    fn port(self: *FakeNapcatServer) u16 {
        return self.listener.listen_address.getPort();
    }

    fn stop(self: *FakeNapcatServer) void {
        self.listener.deinit();
        self.thread.join();
        self.gpa.destroy(self);
    }
};

/// 在 .zig-cache/tmp 下写一个临时输入文件，返回它的绝对路径（调用方持有的
/// 内存，需要 free）。用绝对路径是因为 run() 内部用 std.fs.cwd() 打开文件，
/// 绝对路径在 POSIX 上会绕过那个基准目录，不依赖测试进程的当前工作目录。
fn writeTempInput(gpa: std.mem.Allocator, tmp: *std.testing.TmpDir, content: []const u8) ![]u8 {
    try tmp.dir.writeFile(.{ .sub_path = "input.txt", .data = content });
    return tmp.dir.realpathAlloc(gpa, "input.txt");
}

test "run 端到端：新文本正常入库，已存在的候选被 exists 关卡挡下" {
    const gpa = std.testing.allocator;

    // 两行输入：第一行是全新文本，走完整路径（isTombstoned / exists / nextId
    // / HSET / ZADD / SADD）；第二行模拟"这条文本对应的合成 id 已经在库里"
    // （isTombstoned=0, exists=1），代表重复运行 import 时第二次遇到同一行
    // 会发生的事——deriveId 对同一段文本恒定输出同一个 id 已经在上面的纯
    // 函数测试里钉住了，这里钉的是"exists 命中时 Store 层面确实会被挡下"。
    const redis_script = ":0\r\n" ++ ":0\r\n" ++ ":1\r\n" ++ ":15\r\n" ++ ":1\r\n" ++ ":1\r\n" ++ ":0\r\n" ++ ":1\r\n";
    const redis_srv = try FakeRedisServer.start(gpa, redis_script);
    defer {
        redis_srv.stop();
        redis_srv.received.deinit(gpa);
        gpa.destroy(redis_srv);
    }

    const group_info = "{\"status\":\"ok\",\"retcode\":0,\"data\":{\"group_name\":\"测试群\"}}";
    const member_info = "{\"status\":\"ok\",\"retcode\":0,\"data\":{\"card\":\"\",\"nickname\":\"小明\"}}";
    const nap_srv = try FakeNapcatServer.start(gpa, &.{ group_info, member_info });
    defer nap_srv.stop();

    var c = try redis.Client.connect(gpa, "127.0.0.1", redis_srv.port(), null, 0);
    defer c.deinit();
    var st = store.Store.init(gpa, &c);

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{nap_srv.port()});
    defer gpa.free(base);
    var nap = napcat.Client.init(gpa, base, "test-token");
    defer nap.deinit();

    const deps: runner.Deps = .{
        .gpa = gpa,
        .nap = &nap,
        .st = &st,
        .observed_qqs = &.{123456},
        .admin_qqs = &.{},
        .group_ids = &.{10001},
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempInput(gpa, &tmp, "新的一行文本\n已经入库过的文本\n");
    defer gpa.free(path);

    const summary = try run(deps, path, 1_700_000_000);

    // 文件以 '\n' 结尾，splitScalar 会多切出一段末尾空段，所以 total_lines
    // 是 3（两条真实文本 + 一段末尾空段）、blank_skipped 是 1。
    try std.testing.expectEqual(@as(usize, 3), summary.total_lines);
    try std.testing.expectEqual(@as(usize, 1), summary.blank_skipped);
    try std.testing.expectEqual(@as(usize, 1), summary.added);
    try std.testing.expectEqual(@as(usize, 1), summary.exists_skipped);
    try std.testing.expectEqual(@as(usize, 0), summary.tombstoned_skipped);
    try std.testing.expectEqual(@as(usize, 0), summary.write_failed);

    c.deinit();
    redis_srv.stop();
    // 落库的语录带着 commit_from=import 与合成负 message_id，两者都必须能在
    // 发给 Redis 的 HSET 帧里找到——这才是这条测试真正在钉的东西：光看
    // summary.added==1 钉不住 commit_from 有没有被正确改写成 "import"。
    try std.testing.expect(std.mem.indexOf(u8, redis_srv.received.items, "import") != null);
    try std.testing.expect(std.mem.indexOf(u8, redis_srv.received.items, "新的一行文本") != null);
    const want_id = try std.fmt.allocPrint(gpa, "{d}", .{deriveId("新的一行文本")});
    defer gpa.free(want_id);
    try std.testing.expect(std.mem.indexOf(u8, redis_srv.received.items, want_id) != null);
}

test "run 端到端：群归属解析不出来就整体中止，一条候选都不落 Redis" {
    const gpa = std.testing.allocator;

    // 脚本留空：这条路径上 groupName 失败发生在任何 Store 调用之前，
    // 断言的重点就是"一个字节都不该发到 Redis"。
    const redis_srv = try FakeRedisServer.start(gpa, "");
    defer {
        redis_srv.stop();
        redis_srv.received.deinit(gpa);
        gpa.destroy(redis_srv);
    }

    // get_group_info 本身请求成功，但信封里 retcode != 0——NapCat 拒绝了
    // 这次调用，extractData 返回 NapCatError，groupName 捕获后返回 null。
    const rejected = "{\"status\":\"failed\",\"retcode\":100,\"data\":null}";
    const nap_srv = try FakeNapcatServer.start(gpa, &.{rejected});
    defer nap_srv.stop();

    var c = try redis.Client.connect(gpa, "127.0.0.1", redis_srv.port(), null, 0);
    defer c.deinit();
    var st = store.Store.init(gpa, &c);

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{nap_srv.port()});
    defer gpa.free(base);
    var nap = napcat.Client.init(gpa, base, "test-token");
    defer nap.deinit();

    const deps: runner.Deps = .{
        .gpa = gpa,
        .nap = &nap,
        .st = &st,
        .observed_qqs = &.{123456},
        .admin_qqs = &.{},
        .group_ids = &.{10001},
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempInput(gpa, &tmp, "这一行永远不该被写进去\n");
    defer gpa.free(path);

    try std.testing.expectError(error.AttributionUnavailable, run(deps, path, 1_700_000_000));

    c.deinit();
    redis_srv.stop();
    try std.testing.expectEqual(@as(usize, 0), redis_srv.received.items.len);
}
