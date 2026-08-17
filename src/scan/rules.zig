const std = @import("std");
const onebot = @import("../onebot.zig");

pub const star = "✨";
pub const drop = "💦";
/// 💨 = 给本轮尚未入库的候选追加一段正文。回复目标必须最终成为候选；控制
/// 回复可含 text/at，at 会移到补丁最前，整个补丁直接拼接且不自动插入空格。
pub const append = "💨";
/// 💤 = U+1F4A4。管理员在窗口内发一条**只有** 💤 的消息，再由同一个管理员
/// 给这条消息点一个 💤 表情回应，才等于「这个群这一轮别收录任何东西」。
/// 单独的 💤 只是普通聊天，没有任何控制效果。
pub const sleep = "💤";

const ws = " \t\r\n";

pub const Path = enum { emoji_reaction, quoted_star, admin_manual, admin_quoted, fire_chain };

pub const Candidate = struct {
    message_id: i64,
    path: Path,
    /// 路径3、路径4专用：已经算好、不需要再从目标消息提取的正文。路径3是剥掉
    /// ✨ 前缀后的内容；路径4是链上各成员依次取正文（同样剥过各自的 ✨ 前缀，
    /// 见 finalizeChain）后用空格拼接的结果。路径1、2 为 null，表示按
    /// renderText 从目标消息提取。
    text_override: ?[]u8,
    /// 窗口内引用这条候选的 `💨 内容` 控制回复，按时间顺序拼好后的尾巴。
    /// runner 先取得正常正文（必要时 OCR），确认它不是空文本后，再把这里的
    /// 字节无分隔符追加上去；因此它不会把原本应当按 empty 跳过的消息救活。
    text_suffix: ?[]u8 = null,
    /// 路径4专用：这条链的全部**内容**成员 message_id（时间升序，
    /// `chain_members[0] == message_id`，即主键）。路径1/2/3 为 null。
    ///
    /// 桥（只带 🔥 不带 ✨、可以是任何人发的那些消息）**不在**这里：它们的
    /// 正文没有进这条语录，因此既不该被抑制、也不该被 tombstone，💦 一座桥
    /// 更不该撤掉这条链。完整理由见 Chain 的文档注释。
    ///
    /// 这份数据是从 Chain.members dupe 出来的独立分配（不是转移所有权）：
    /// Chain.members 在整个 classify() 执行期间还要继续被 chainOf 用来判定
    /// "某个 window 里的消息是不是链成员"（Pass B 主循环、Pass A 的 💦 展开），
    /// 不能在插入 fire_chain 候选时就被掏空。
    ///
    /// runner.zig 靠这个字段把整条链的成员列表持久化进 Redis
    /// （`store.Store.addChain`）：rules.classify 只能在当次扫描窗口里重建出
    /// 链，💦 撤稿一条早先已经入库的链语录时，引用目标很可能落在窗口外
    /// （缓冲池 / get_msg 回补），chainOf 在那种情况下必然返回 null——没有这份
    /// 持久化，非主键成员就永远等不到被跨窗口撤稿。见 store.zig 顶部
    /// key_chainmember_prefix 的注释。
    chain_members: ?[]i64,

    /// 路径3专用：`✨ @某人 内容` 这条可选语法里被 at 的那个人的 QQ——
    /// 这条语录的**作者**（`from_who` / `hikari:byuser:{user_id}` 该记的人），
    /// 不是敲这条指令的管理员。`null` 表示没有用这条语法（`✨ 内容`），作者
    /// 落回"发这条消息的人"，跟改动之前逐字一致。
    ///
    /// `creator` / `creator_uid` **不**跟着走这个字段：Hitokoto 语义下
    /// creator 是"把这条语录加进来的人"，那永远是敲指令的管理员本人；作者
    /// （from_who）才是"说这句话的人"。改动之前两者恰好是同一个人，所以
    /// runner.zig 只算了一次；现在必须分开算，见 scanGroup 里
    /// `author_uid` / `sender_uid` 那两行。
    ///
    /// 被 at 的人**不要求**在 `OBSERVED_QQS` 里：管理员是在显式断言"这句话
    /// 是他说的"，要求目标必须被观察会让这条语法在配置了子集时彻底没法用
    /// （生产上观察集合是空的，任何人都算被观察，这条限制本来也不起作用）。
    author_uid: ?u64,

    /// 显式管理员收录命令的发送者。路径3（`✨ 内容` / `✨ @某人 内容`）和
    /// 新的引用归属命令（回复目标并只发 `✨ @某人`）填写；自动路径为 null。
    /// 不能从 `message_id` 对应目标的发送者反推：引用归属命令的目标与敲命令
    /// 的管理员本来就是两条不同消息。
    creator_uid: ?u64 = null,
};

pub const Params = struct {
    /// 被观察者集合。**空切片 = 观察所有人**。
    observed_qqs: []const u64,
    admin_qqs: []const u64,
    /// 已经由 runner 通过 `get_msg` + `get_emoji_likes` 确认“消息发送者本人点了
    /// 💤 表情回应”的 message_id。默认空，保持 rules 的绝大多数纯函数测试与
    /// 其它调用点无需关心 NapCat 数据来源。
    sleep_reaction_ids: []const i64 = &.{},

    /// "这个 QQ 算不算被观察者" 的**唯一**判定点。自动收录路径、Pass A 的
    /// 撤稿目标判定、🔥 链的成员资格全部走这一个函数，不允许任何一处再写
    /// 一份自己的 `for (observed_qqs) |o| ...`——"空集合 = 全部" 这条规则
    /// 抄四遍就是四次抄错的机会，而抄错的后果分别是：漏收（判成 false）、
    /// 或者把不该作废的消息永久 tombstone（判成 true）。
    pub fn isObserved(self: Params, qq: u64) bool {
        if (self.observed_qqs.len == 0) return true;
        for (self.observed_qqs) |o| if (o == qq) return true;
        return false;
    }
};

pub const Outcome = struct {
    revoked: []i64,
    candidates: []Candidate,
    unresolved: []i64,

    /// 💤：窗口内有管理员发过一条"只有 💤"的消息，runner 又确认同一个管理员
    /// 给它点了 💤 表情回应，且这条消息**没有**被同一个窗口里的管理员 💦
    /// 引用取消 → 这个群这一轮一条都不收录。
    ///
    /// 刻意**不**在 rules.zig 里把 candidates 清空：运营方要求这一轮照样扫、
    /// 照样发七行日志，并且把每一条候选都如实计进 `skipped`（`Added 0
    /// messages, skipped N messages.`）——"这个群今天什么都没发"跟"这个服务
    /// 死了"必须在群里长得不一样。候选列表因此原样返回，由 runner.zig 决定
    /// 不写库、只计数。
    ///
    /// 这个标志**不影响** `revoked`：💤 的意思是"今天别加东西"，不是"忽略
    /// 撤稿"。一条被 💤 吞掉的 💦 正是这个项目一直在消灭的那种静默失败。
    skip_collection: bool,

    pub fn deinit(self: *Outcome, gpa: std.mem.Allocator) void {
        for (self.candidates) |c| {
            if (c.text_override) |t| gpa.free(t);
            if (c.text_suffix) |t| gpa.free(t);
            if (c.chain_members) |cm| gpa.free(cm);
        }
        gpa.free(self.candidates);
        gpa.free(self.revoked);
        gpa.free(self.unresolved);
    }
};

fn isAdmin(p: Params, qq: u64) bool {
    for (p.admin_qqs) |a| if (a == qq) return true;
    return false;
}

/// 路径3的判定结果：正文 + （可选的）被 at 出来的作者。
pub const Manual = struct {
    /// 剥掉 `✨` 前缀（以及、若有的话，紧跟其后作为作者标记的那个 at 段）
    /// 之后 trim 过的正文。新分配，调用方负责 free。
    body: []u8,
    /// `✨ @某人 内容` 里被 at 的那个人的 QQ；`✨ 内容` 时为 null。
    author_uid: ?u64,
};

/// 按 `onebot.Message.renderText` 的同一套规则渲染一段 segment 序列
/// （text 原样、at → `@昵称`（缺 name 退回 `@QQ号`）、其余段丢弃），**不** trim，
/// 前面先拼上 `prefix`（承载 `✨` 的那个 text 段被剥掉前缀后剩下的尾巴）。
///
/// 单独抽出来是因为路径3现在必须在**段列表**上判定而不是渲染文本上：
/// renderText 把 at 段烧成 `@昵称` 并把 QQ 号彻底丢掉，而 `✨ @某人 内容`
/// 恰恰需要那个 QQ 号。判定完之后正文仍然要按同一套规则渲染，于是渲染这一
/// 半在这里复用，两处不会漂移。
fn renderSegments(gpa: std.mem.Allocator, segs: []const onebot.Segment, prefix: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    try list.appendSlice(gpa, prefix);
    for (segs) |s| switch (s) {
        .text => |t| try list.appendSlice(gpa, t),
        .at => |a| {
            try list.append(gpa, '@');
            try list.appendSlice(gpa, a.name orelse a.qq);
        },
        else => {},
    };
    return list.toOwnedSlice(gpa);
}

/// 路径3格式判定：发送者是管理员、不含 reply 段、（按段序渲染出来的）文本以
/// `✨` 开头、剥掉前缀后非空。命中返回正文与可选作者，否则 null。
///
/// **判定走段列表，不走渲染文本。** 两种语法：
///
/// ```
/// ✨ @某人 内容   → 作者 = 被 at 的人，正文 = 内容
/// ✨ 内容         → 作者 = 敲指令的管理员（改动之前的行为，逐字不变）
/// ```
///
/// 为什么必须在段上判定：`renderText` 把 at 段渲染成 `@昵称` 就把
/// `at.data.qq` 丢了，而"这句话是谁说的"只能从那个 QQ 号来——在渲染文本上
/// 反解 `@昵称` 既不可靠（昵称可以带空格、可以跟正文粘在一起、可以重名）
/// 也拿不到 QQ 号。
///
/// 走法（与 renderText 的口径逐条对齐，保证"改动前能命中的今天照样命中"）：
///
///   1. 找承载 `✨` 的那个 text 段：按段序往后走，`.other` 段丢弃（renderText
///      也丢），左 trim 之后为空的 text 段跳过（它对渲染结果没有贡献）。第一
///      个有内容的段若是 `.at`，渲染出来就是 `@…` 开头而不是 `✨` 开头 → 不
///      是路径3；若是 text 但不以 `✨` 开头 → 同样不是。
///   2. 只有当 `✨` 之后这个 text 段里**再没有别的内容**时，才去看下一个有内容
///      的段是不是 `at`——`✨ 你好 @某人` 里的 at 前面已经有正文了，它是普通
///      内容，照旧渲染成 `@昵称`。**只有紧跟 `✨` 的那个 at 才是作者标记。**
///   3. 作者标记的 at 之后的全部段（含后面的 at）就是正文，按 renderSegments
///      渲染 + trim；`✨ @某人` 没有正文时仍返回一个 body 为空的 Manual，让
///      路径3赢过路径1，并由 runner 的既有空文本关卡诚实计入 skipped。
///   4. `at.data.qq` 解析不出 u64（`@全体成员` 的 `"all"` 就是这种）→ 不当作
///      者标记，退回"没有 at"那一支，这个 at 照旧渲染进正文。
pub fn manualParse(gpa: std.mem.Allocator, m: onebot.Message, p: Params) !?Manual {
    if (!isAdmin(p, m.user_id)) return null;
    if (m.replyTarget() != null) return null;

    // 1. 定位 ✨。
    var i: usize = 0;
    var rest_first: []const u8 = "";
    var found = false;
    while (i < m.segments.len) : (i += 1) {
        switch (m.segments[i]) {
            .text => |t| {
                const lt = std.mem.trimLeft(u8, t, ws);
                if (lt.len == 0) continue;
                if (!std.mem.startsWith(u8, lt, star)) return null;
                rest_first = lt[star.len..];
                found = true;
            },
            .at => return null, // 渲染出来是 @… 开头，不是 ✨
            else => continue, // .other（reply 段上面已经排除）
        }
        if (found) break;
    }
    if (!found) return null;
    i += 1; // 跳过承载 ✨ 的那个 text 段本身

    // 2/3/4. 紧跟 ✨ 的那个 at（如果有）就是作者标记。
    var author_uid: ?u64 = null;
    var body_start = i;
    if (std.mem.trim(u8, rest_first, ws).len == 0) {
        var j = i;
        while (j < m.segments.len) : (j += 1) {
            switch (m.segments[j]) {
                .text => |t| {
                    if (std.mem.trim(u8, t, ws).len == 0) continue;
                    break; // 先撞上正文 → 没有作者标记
                },
                .at => |a| {
                    const qq = std.fmt.parseInt(u64, std.mem.trim(u8, a.qq, ws), 10) catch break;
                    author_uid = qq;
                    body_start = j + 1;
                    rest_first = "";
                    break;
                },
                else => continue,
            }
        }
    }

    const rendered = try renderSegments(gpa, m.segments[body_start..], rest_first);
    defer gpa.free(rendered);
    const body = std.mem.trim(u8, rendered, ws);
    // 光杆 `✨` 维持旧行为（不是候选）；但 `✨ @某人` 已经明确命中了新增的
    // 路径3语法，即使正文为空也必须作为空候选返回。否则它若又被贴了 ✨，会
    // 从路径3漏下去被路径1收成字面量 `✨ @某人`，同时 skipped 也少算一条。
    // 光杆 `✨` 仍不是候选；但同一条消息带图片时，✨ 已经明确是在要求收录
    // 那张图，正文交给 runner 的 `.ocr_image` 回填。
    if (body.len == 0 and author_uid == null and !m.hasImage()) return null;
    return .{ .body = try gpa.dupe(u8, body), .author_uid = author_uid };
}

/// 只要正文、不要作者的调用点（🔥 链拼接、Pass A 判"这条消息是不是路径3格式"）
/// 的薄包装。链的作者由 `buildChains` 的同一发送者约束定死，不看这个字段。
pub fn manualBody(gpa: std.mem.Allocator, m: onebot.Message, p: Params) !?[]u8 {
    const parsed = try manualParse(gpa, m, p) orelse return null;
    // Pass A 的“是不是可作废的路径3目标”和 🔥 链正文剥前缀只接受有正文的
    // 手动收录；空 Manual 只为 Pass B 生成空候选、走 skipped 关卡。
    if (parsed.body.len == 0) {
        gpa.free(parsed.body);
        return null;
    }
    return parsed.body;
}

pub const QuotedAuthor = struct {
    target_id: i64,
    author_uid: u64,
};

fn replyCount(m: onebot.Message) usize {
    var n: usize = 0;
    for (m.segments) |s| switch (s) {
        .reply => n += 1,
        else => {},
    };
    return n;
}

/// 管理员显式给一条引用消息指定作者：除了唯一 reply 段外，只有 `✨`、一个
/// 数字 QQ 的 at 段和任意空白 text 段。目标可以是管理员自己或任何群成员，
/// 被 at 的人也不要求属于 OBSERVED_QQS。
pub fn quotedAuthorCommand(m: onebot.Message, p: Params) ?QuotedAuthor {
    if (!isAdmin(p, m.user_id) or replyCount(m) != 1) return null;
    const target_id = m.replyTarget() orelse return null;

    var saw_star = false;
    var author_uid: ?u64 = null;
    for (m.segments) |s| switch (s) {
        .reply => {},
        .text => |t| {
            const trimmed = std.mem.trim(u8, t, ws);
            if (trimmed.len == 0) continue;
            if (saw_star or author_uid != null or !std.mem.eql(u8, trimmed, star)) return null;
            saw_star = true;
        },
        .at => |a| {
            if (!saw_star or author_uid != null) return null;
            author_uid = std.fmt.parseInt(u64, std.mem.trim(u8, a.qq, ws), 10) catch return null;
        },
        else => return null,
    };
    return .{ .target_id = target_id, .author_uid = author_uid orelse return null };
}

/// `reply + 💨 + text/at` 的正文补丁。所有 at 段按原顺序移动到补丁最前面，
/// 再接控制符后的文本；at 之间、at 与文本之间规范化为一个空格。返回值由
/// gpa 分配，调用方负责释放。系统把它追加到原语录时不会再补任何空格。
pub fn tailAppendBody(gpa: std.mem.Allocator, m: onebot.Message) !?[]u8 {
    if (replyCount(m) != 1) return null;

    var texts: std.ArrayList(u8) = .empty;
    defer texts.deinit(gpa);
    var ats: std.ArrayList(onebot.At) = .empty;
    defer ats.deinit(gpa);
    for (m.segments) |segment| switch (segment) {
        .reply => {},
        .text => |text| try texts.appendSlice(gpa, text),
        .at => |at| try ats.append(gpa, at),
        else => return null,
    };

    const trimmed = std.mem.trim(u8, texts.items, ws);
    if (!std.mem.startsWith(u8, trimmed, append)) return null;
    const text_body = std.mem.trim(u8, trimmed[append.len..], ws);
    if (text_body.len == 0 and ats.items.len == 0) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (ats.items, 0..) |at, i| {
        if (i > 0) try out.append(gpa, ' ');
        try out.append(gpa, '@');
        const display = if (at.name) |name| if (name.len > 0) name else at.qq else at.qq;
        try out.appendSlice(gpa, display);
    }
    if (text_body.len > 0) {
        if (out.items.len > 0) try out.append(gpa, ' ');
        try out.appendSlice(gpa, text_body);
    }
    return try out.toOwnedSlice(gpa);
}

/// 这条消息是不是一条"路径2的 ✨ 触发消息"——除 reply 段外只有一个文本段、
/// 文本 trim 之后正好是 `✨`，且确实引用了某条消息。是的话返回它引用的
/// `message_id`。
///
/// 这里只识别消息形状；路径2还要求触发者与原消息作者不是同一个人。Pass A
/// 一跳在拿到被引用的原消息之后补做这条身份判定，不能把“自己回自己 ✨”误认
/// 成第三方认可。
///
///   - Pass A 的 💦 一跳（4.3 节）：管理员看得见的是群里那条 `✨`，让他 💦 那
///     一条比让他翻回去找原文自然得多。这里把目标换成"那条 ✨ 引用的消息"，
///     然后所有既有的目标判定（含 🔥 链展开）原样再跑一遍。
///   - `scan/runner.zig` 步骤 3：为这一跳预解析目标。💦 引用的那条 ✨ 很可能
///     是几天前的（语录是在收录它的那次扫描**之后**才出现在 `GET /` 里的），
///     落在窗口外、只能靠 get_msg 回补，它自己的 reply 目标不会被窗口内那轮
///     解析捎带上，必须显式再补一次。
pub fn starTriggerTarget(m: onebot.Message) ?i64 {
    const rid = m.replyTarget() orelse return null;
    const txt = m.soleTextBesidesReply() orelse return null;
    if (!std.mem.eql(u8, std.mem.trim(u8, txt, ws), star)) return null;
    return rid;
}

/// runner 为窗口外的控制目标补拉第二跳时使用。普通路径2的 `reply + ✨` 与
/// 管理员的 `reply + ✨ @某人` 都会把被引用原消息变成候选，二者都必须预取。
pub fn triggerTarget(m: onebot.Message, p: Params) ?i64 {
    if (quotedAuthorCommand(m, p)) |q| return q.target_id;
    return starTriggerTarget(m);
}

/// 这条消息是不是 💤 控制命令的**文本锚点**。锚点本身不产生控制效果；
/// sleepCommand 还会要求 runner 已确认发送者本人点过 💤 表情回应。
///
/// **"只有 💤" 的精确定义**（三条同时成立）：
///
///   1. 发送者 ∈ `ADMIN_QQS`。
///   2. **不含 reply 段**。💤 是一条群级指令，没有作用对象；带 reply 段的
///      消息在这套语法里一律是"针对被引用那条"的意思（路径2 的 `✨`、
///      Pass A 的 `💦`），让 💤 也能带 reply 就是让两套语法打架，跟路径3
///      "含 reply 段的一律走路径2判定"是同一条既有原则。
///   3. 除此之外**恰好只有一个 text 段**（`soleTextBesidesReply`：夹带
///      image/face/at/多个 text 段一律不算），且它 trim（空格/制表/CR/LF）
///      之后逐字节等于 `💤`。
///
/// 注意"trim 之后等于"用的是字节比较，不是"包含 💤"：`💤💤`、`睡了💤`、
/// `💤 明天见` 都不是锚点。
pub fn sleepAnchor(m: onebot.Message, p: Params) bool {
    if (!isAdmin(p, m.user_id)) return false;
    if (m.replyTarget() != null) return false;
    const txt = m.soleTextBesidesReply() orelse return false;
    return std.mem.eql(u8, std.mem.trim(u8, txt, ws), sleep);
}

fn sleepCommand(m: onebot.Message, p: Params) bool {
    return sleepAnchor(m, p) and contains(p.sleep_reaction_ids, m.message_id);
}

fn lookup(pool: []const onebot.Message, id: i64) ?onebot.Message {
    for (pool) |m| if (m.message_id == id) return m;
    return null;
}

fn contains(list: []const i64, id: i64) bool {
    for (list) |x| if (x == id) return true;
    return false;
}

/// 一条已并链的 🔥 chain：members 按时间升序，member[0] 是主键（"句子的开头"）。
///
/// **members 里只有内容消息，没有桥。** 桥（只带 🔥、不带 ✨ 的消息，见
/// isBridge）的正文一个字都没有进这条语录，它只是在说"这句话还没说完"；
/// 而且桥可以是**任何人**发的。成员资格在这个系统里恰好等价于一件事——
/// "你的正文在这条语录里"，抑制（不再单独收录）、tombstone、持久化进
/// `hikari:chainmember:{id}` 的映射三件事全都从这一个事实推出来：
///
///   - 抑制：内容成员必须让路给链，否则碎句和整句会同时入库；桥的正文
///     不在语录里，单独收录它不产生任何重复，因此不该抑制。
///   - tombstone：4.4 节要求链的成员全部 tombstone，理由是"往后 🔥 被撤掉、
///     链散架时，幸存成员会退回路径1，已作废的内容会原样复活"。这条理由
///     只对内容成员成立——桥的正文从来不在这条语录里，它复活也复活不出
///     任何被撤掉的内容。
///   - 💦：因此 💦 一座桥不作废这条链，退化成对桥自己的一次普通撤稿。反过来
///     做的话，一个只是恰好被贴了 🔥 的路人的消息，会变成撤掉别人语录的开关。
///
/// text 是拼接后的 joined 正文，直到被并入某个 Candidate.text_override 之前
/// 一直非 null；一旦转移所有权，置 null 防止 deinit 时重复释放——跟
/// Candidate.text_override 是同一个套路。
const Chain = struct {
    members: []i64,
    text: ?[]u8,

    fn deinit(self: *Chain, gpa: std.mem.Allocator) void {
        gpa.free(self.members);
        if (self.text) |t| gpa.free(t);
    }
};

/// 🔥 = "这条消息和下一条属于同一句话"。它是**唯一**的相邻规则：一段连续的
/// 🔥 走到第一条没有 🔥 的消息就结束。带不带 ✨、是谁发的，都不影响这一条。
fn carriesFire(m: onebot.Message, fire_ids: []const i64) bool {
    return contains(fire_ids, m.message_id);
}

/// **内容**消息：同时带 ✨ 与 🔥，且作者是被观察者。它的正文会进这条语录。
/// 调用方保证已经确认过 carriesFire。
fn isChainContent(gpa: std.mem.Allocator, m: onebot.Message, star_ids: []const i64, p: Params) !bool {
    // 控制回复即使碰巧也被点了 ✨/🔥，其字面量也不应进入语录正文。
    if (try tailAppendBody(gpa, m)) |body| {
        gpa.free(body);
        return false;
    }
    if (quotedAuthorCommand(m, p) != null) return false;
    return p.isObserved(m.user_id) and contains(star_ids, m.message_id);
}

/// window 按 message_id 去重后的序列，只保留每个 id 首次出现的那条。
///
/// 陷阱（本文件加的测试专门覆盖）：NapCat 分页是闭区间，相邻两页会把锚点消息
/// 重复拉一遍，同一条消息因此可能在 window 里出现两次。链必须走这个去重后的
/// 序列：同一条内容消息被重复走一遍，会让它的正文在 joined 语录里出现两次
/// （"上 中 中 下"），也会让重复的 message_id 进 chain_members——而
/// chain_members 会被原样持久化进 `hikari:chain:{主键}`，撤稿展开跟着一起
/// 重复。这种页边界重叠几乎不可复现（只有页边界恰好落在两条消息之间才会
/// 触发），所以必须在这一层一次性挡掉。
fn distinctWindow(gpa: std.mem.Allocator, window: []const onebot.Message) ![]onebot.Message {
    var out: std.ArrayList(onebot.Message) = .empty;
    errdefer out.deinit(gpa);
    outer: for (window) |m| {
        for (out.items) |x| if (x.message_id == m.message_id) continue :outer;
        try out.append(gpa, m);
    }
    return out.toOwnedSlice(gpa);
}

/// 把 members（时间升序）拼成一条 Chain 并追加到 chains。
///
/// 拼接每个成员时优先走 manualBody（路径3判定）：若这个成员自己就是合法的
/// "✨ 内容" 管理员手动收录格式（这要求被观察者同时在 ADMIN_QQS 里），拼进
/// joined 正文的是剥掉 ✨ 前缀后的内容，而不是带着 ✨ 的原始渲染文本。✨ 在这个
/// 系统里到处都是控制符不是正文——路径3自己会剥掉它，路径4的联动如果不剥，
/// 会拼出"你们有钱 ✨ 你们潇洒"这种带着控制符残留的语录。manualBody 内部已经
/// 处理了"不含 reply 段"这个前提，链成员本来就不含 reply 段（reply 段是路径2的
/// 语法，和链成员资格互斥的场景在实践中不会出现，即便出现 manualBody 也会
/// 正确返回 null 退回原始渲染文本）。
fn finalizeChain(gpa: std.mem.Allocator, chains: *std.ArrayList(Chain), members: []const onebot.Message, p: Params) !void {
    var ids: std.ArrayList(i64) = .empty;
    errdefer ids.deinit(gpa);
    for (members) |m| try ids.append(gpa, m.message_id);
    const ids_owned = try ids.toOwnedSlice(gpa);
    errdefer gpa.free(ids_owned);

    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    for (members, 0..) |m, i| {
        const piece: []const u8 = if (try manualBody(gpa, m, p)) |body| body else try m.renderText(gpa);
        defer gpa.free(piece);
        if (i > 0) try text.append(gpa, ' ');
        try text.appendSlice(gpa, piece);
    }
    const text_owned = try text.toOwnedSlice(gpa);
    errdefer gpa.free(text_owned);

    try chains.append(gpa, .{ .members = ids_owned, .text = text_owned });
}

/// 扫出窗口内全部 🔥 链：一条链是"≥2 条内容消息 + 它们之间不间断的 🔥"。
///
/// 走法（按去重后的窗口序列从前往后逐条走）：
///
///   - 这条消息**没有 🔥** → 当前这一段连续的 🔥 到此为止：手上攒够 ≥2 条
///     内容消息就收成一条链，然后清空重来。🔥 的连续性是唯一的相邻规则，
///     它取代了旧版那条"两条合格消息之间最多隔 3 条"的间距上限（间距上限
///     连同 chain_max_gap 已经整个删掉）。
///   - 有 🔥 且是**内容**（✨ + 🔥 + 作者是被观察者）→ 并进当前这条链。
///   - 有 🔥 但不是内容 → **桥**：正文丢弃，不进 members，但连续段继续往下
///     走。桥可以是**任何人**发的，这正是它存在的理由——它让一条链跨过别人
///     的插话。注意"带了 ✨ 但作者不是被观察者"的消息也落在这一支：内容要求
///     三件事同时成立，缺一件就不是内容，而它带着 🔥，所以连续段不在它这里
///     结束。
///
/// 同一发送者约束：一条链的**内容**消息必须全是同一个人发的。作者 U 由这条
/// 链的第一条内容消息确定（`OBSERVED_QQS` 为空、观察所有人时没有配置里的
/// 唯一被观察者可以锚定，只能这样定），后面每条内容消息都要 `user_id == U`
/// 才能并进来。中途冒出另一个被观察者的内容消息时：它不并进当前这条链，而是
/// **就地终止当前 run、以它自己为起点另起一条**。选这个而不是"当桥跳过它"
/// 的理由：内容消息本身就是它自己的作者在宣告"我这句话还没说完"，让 U 的链
/// 跨过 B 自己的句子开头连下去，等于把 B 的 🔥 记在 U 头上；run 的归属在这
/// 一刻换了人，才是这段 🔥 唯一说得通的读法。副作用也更安全：被跳过的那条
/// 内容消息如果没能另起一条链，它会原样退回路径1单独收录，不会被静默吞掉。
/// 桥不参与这条约束（桥没有作者要求，也不改变 U）。
///
/// 只有真正并成链（≥2 条内容消息）的才会出现在返回值里；一条内容消息后面
/// 只跟着几座桥（"这句话还没说完"，但续写要么没被 ✨ 认可、要么不是这个人
/// 发的）不产生 Chain，调用方据此让它退回普通路径1候选。
fn buildChains(
    gpa: std.mem.Allocator,
    window: []const onebot.Message,
    star_ids: []const i64,
    fire_ids: []const i64,
    excluded_content_ids: []const i64,
    p: Params,
) ![]Chain {
    const distinct = try distinctWindow(gpa, window);
    defer gpa.free(distinct);

    var chains: std.ArrayList(Chain) = .empty;
    errdefer {
        for (chains.items) |*c| c.deinit(gpa);
        chains.deinit(gpa);
    }

    // 当前这一段连续 🔥 上已经攒到的**内容**消息（桥不在里面）。
    var run: std.ArrayList(onebot.Message) = .empty;
    defer run.deinit(gpa);

    for (distinct) |m| {
        if (!carriesFire(m, fire_ids)) {
            // 连续段结束。
            if (run.items.len >= 2) try finalizeChain(gpa, &chains, run.items, p);
            run.clearRetainingCapacity();
            continue;
        }
        if (contains(excluded_content_ids, m.message_id) or !(try isChainContent(gpa, m, star_ids, p))) continue; // 桥：不进正文，也不断链
        if (run.items.len > 0 and run.items[0].user_id != m.user_id) {
            // 另一个被观察者的内容消息：当前 run 到此为止，它自己另起一条。
            if (run.items.len >= 2) try finalizeChain(gpa, &chains, run.items, p);
            run.clearRetainingCapacity();
        }
        try run.append(gpa, m);
    }
    if (run.items.len >= 2) try finalizeChain(gpa, &chains, run.items, p);

    return chains.toOwnedSlice(gpa);
}

/// rid 若落在某条链里（不管是不是主键成员），返回那条链；否则 null。
fn chainOf(chains: []const Chain, id: i64) ?*const Chain {
    for (chains) |*c| {
        for (c.members) |mid| if (mid == id) return c;
    }
    return null;
}

pub fn classify(
    gpa: std.mem.Allocator,
    window: []const onebot.Message,
    pool: []const onebot.Message,
    star_ids: []const i64,
    fire_ids: []const i64,
    p: Params,
) !Outcome {
    // `✨ @某人` 引用归属是管理员对“只收这条引用目标”的显式指令，优先于
    // 自动 🔥 分组。先收集这些目标，让它们在建链时只充当桥、不成为链正文；
    // 否则目标若是非主键链成员，后面的 Store 链成员关卡会把管理员的显式命令
    // 静默跳掉。
    var quoted_targets: std.ArrayList(i64) = .empty;
    defer quoted_targets.deinit(gpa);
    for (window) |m| {
        if (quotedAuthorCommand(m, p)) |q| {
            if (!contains(quoted_targets.items, q.target_id)) try quoted_targets.append(gpa, q.target_id);
        }
    }

    // 链必须在 Pass A 之前就构建好：💦 可能引用链上任意一个成员（不一定是
    // 主键那条），Pass A 要能把这次撤稿展开成"整条链的全部成员都要 tombstone"，
    // 就必须已经知道成员→链的映射。构建放在函数最前面，而不是让 Pass A 现算，
    // 是因为 Pass B 插入 fire_chain 候选、排除路径1里的链成员，同样需要这份
    // 映射——算一次，Pass A/Pass B 共用，也避免两处判定逻辑各写一份、悄悄分叉。
    const chains = try buildChains(gpa, window, star_ids, fire_ids, quoted_targets.items, p);
    defer {
        for (chains) |*c| c.deinit(gpa);
        gpa.free(chains);
    }

    var revoked: std.ArrayList(i64) = .empty;
    errdefer revoked.deinit(gpa);
    var unresolved: std.ArrayList(i64) = .empty;
    errdefer unresolved.deinit(gpa);
    var cands: std.ArrayList(Candidate) = .empty;
    errdefer {
        for (cands.items) |c| {
            if (c.text_override) |t| gpa.free(t);
            if (c.text_suffix) |t| gpa.free(t);
            if (c.chain_members) |cm| gpa.free(cm);
        }
        cands.deinit(gpa);
    }

    // 已经由 runner 确认过“发送者本人点了 💤 回应”的锚点，与“哪些消息被
    // 💦 引用过”这两份名单在 Pass A 里同时攒起来，循环结束后才算
    // skip_collection——💦 可能出现在窗口内锚点的前面或后面，边走边判会
    // 依赖出现顺序。
    var sleep_ids: std.ArrayList(i64) = .empty;
    defer sleep_ids.deinit(gpa);
    var drop_targets: std.ArrayList(i64) = .empty;
    defer drop_targets.deinit(gpa);

    // Pass A：收集作废指令（顺带收集经过表情回应二次确认的 💤 指令）
    for (window) |m| {
        if (!isAdmin(p, m.user_id)) continue;
        if (sleepCommand(m, p)) {
            if (!contains(sleep_ids.items, m.message_id)) try sleep_ids.append(gpa, m.message_id);
            continue;
        }
        const rid0 = m.replyTarget() orelse continue;
        const txt = m.soleTextBesidesReply() orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, txt, ws), drop)) continue;
        // 💦 **直接**引用的那个 id（一跳之前）——“💦 引用已确认的 💤 锚点就取消
        // 这一轮的跳过"看的是这个，不是一跳之后的目标，也不是 revoked：
        // 💤 那条消息的发送者是管理员，`OBSERVED_QQS` 配了子集且管理员不在
        // 里面时它压根不是一个"可作废的目标"（4.3 节），永远不会进 revoked，
        // 拿 revoked 判就会让取消功能在那种配置下静默失效。
        if (!contains(drop_targets.items, rid0)) try drop_targets.append(gpa, rid0);
        var rid = rid0;
        var target = lookup(pool, rid) orelse {
            if (!contains(unresolved.items, rid)) try unresolved.append(gpa, rid);
            continue;
        };
        var explicit_admin_trigger = false;
        // 管理员 `✨ @某人` 引用归属命令也是一条可见的收录触发消息。之后
        // 💦 引用这条命令，应与路径2的一跳一样撤掉真正入库的引用目标；它
        // 不要求原作者在 observed 集合内，也允许管理员引用自己的原消息。
        if (quotedAuthorCommand(target, p)) |quoted| {
            const hop_target = lookup(pool, quoted.target_id) orelse {
                if (!contains(unresolved.items, quoted.target_id)) try unresolved.append(gpa, quoted.target_id);
                continue;
            };
            rid = quoted.target_id;
            target = hop_target;
            explicit_admin_trigger = true;
        }
        // 一跳（4.3 节）：💦 的目标本身就是一条路径2的 `✨` 触发消息时，真正
        // 要撤的是**那条 ✨ 引用的消息**——那才是被收录进库的语录。管理员在群里
        // 看得见的是那条 ✨，让他去 💦 它是最自然的动作；改动之前这个动作什么
        // 都不会发生，而且没有任何反馈。
        //
        // 只跳这一次，跳完之后所有既有的目标判定（发送者是不是被观察者 /
        // 是不是路径3格式 / 🔥 链展开）原样再跑一遍，没有任何新语义。跳到的
        // 东西要是解析不出来（窗口外 + get_msg 也回补不到），跟改动之前一样
        // 什么都不发生，只是多记一条 unresolved 警告。
        if (!explicit_admin_trigger) {
            if (starTriggerTarget(target)) |hop| {
                const trigger = target;
                const hop_target = lookup(pool, hop) orelse {
                    if (!contains(unresolved.items, hop)) try unresolved.append(gpa, hop);
                    continue;
                };
                // 只有完整满足路径2资格才 hop：原消息必须被观察，且触发者必须是
                // 别人。否则这只是“一条长得像 ✨ 触发的普通引用消息”，保持旧的
                // 直接撤稿语义，继续对 rid0 / trigger 本身做下方资格判定。
                if (p.isObserved(hop_target.user_id) and trigger.user_id != hop_target.user_id) {
                    rid = hop;
                    target = hop_target;
                }
            }
        }
        var ok = explicit_admin_trigger or p.isObserved(target.user_id);
        if (!ok) {
            if (try manualBody(gpa, target, p)) |body| {
                gpa.free(body);
                ok = true;
            }
        }
        if (!ok) continue;
        // 💦 引用到链上任意一个成员都要作废整条链：把全部成员都塞进 revoked，
        // 不只是 rid 自己。这样：(1) 存的那条语录（主键 = 第一个成员）会被
        // 删掉——即便 💦 引用的是第二个成员；(2) 每个成员的 message_id 都会被
        // tombstone，哪怕它自己从没单独入库过。后者是必须的：往后一旦 🔥 被
        // 撤掉、链散架，幸存成员会退回路径1单独候选资格，若它没被 tombstone，
        // 已经作废的内容就会原样复活。
        if (chainOf(chains, rid)) |c| {
            for (c.members) |mid| {
                if (!contains(revoked.items, mid)) try revoked.append(gpa, mid);
            }
        } else if (!contains(revoked.items, rid)) {
            try revoked.append(gpa, rid);
        }
    }

    // 💤：窗口里存在一条“管理员发单独 💤 + 同一管理员亲自点 💤 回应”、且
    // **没有被 💦 引用**的确认指令 → 这一轮不收录。单独的文本锚点不会进入
    // sleep_ids，因此完全没有控制效果。两条已确认锚点只撤掉一条，剩下那条
    // 仍然生效；撤销必须逐条撤干净。
    var skip_collection = false;
    for (sleep_ids.items) |sid| {
        if (!contains(drop_targets.items, sid)) {
            skip_collection = true;
            break;
        }
    }

    // Pass B：先并入 🔥 链候选——每条链一个，正文是拼接好的 joined 文本，主键
    // 是第一个成员的 message_id。放在路径1/2/3 之前插入：下面的主循环会显式
    // 检查每条消息是否是某条链的成员（is_chain_member / chainOf），链成员一律
    // 不再生成路径1/2/3 的候选（见下方主循环里的说明），所以这里插入的顺序
    // 本身不再依赖 appendCandidate 的去重规则来"赢"——不会有路径1/2/3的候选
    // 冲着同一个链成员的 message_id 跑来跟它抢；先插入只是让 chains 的所有权
    // 转移（c.text = null）尽早发生，逻辑上更直接。
    for (chains) |*c| {
        if (c.text) |t| {
            // chain_members 是从 c.members dupe 出来的独立分配，不是转移
            // 所有权：c.members 在下面 Pass B 主循环、以及上面已经跑过的
            // Pass A 里都还要靠 chainOf 反复查——转移所有权（置 c.members
            // 为空切片）会让本函数剩下的全部 chainOf 调用当场失效。c.text
            // 那次是可以转移的，因为 joined 正文只在这里用一次。
            const members_dup = try gpa.dupe(i64, c.members);
            errdefer gpa.free(members_dup);
            try appendCandidate(gpa, &cands, .{
                .message_id = c.members[0],
                .path = .fire_chain,
                .text_override = t,
                .chain_members = members_dup,
                .author_uid = null,
            });
            c.text = null; // 所有权转移给 cands 了；防止函数末尾 chains 的 defer 重复释放
        }
    }

    // Pass B：收集候选
    for (window) |m| {
        // 💨 回复是候选的正文补丁，不是它自己的语录；即使这条控制消息碰巧
        // 被贴了 ✨，也不能把 `💨 内容` 字面量再收一份。
        if (try tailAppendBody(gpa, m)) |body| {
            gpa.free(body);
            continue;
        }

        // 链成员的个体收录资格对全部路径一律让路给路径4：链是更具体的信号
        // （群里明确把这几条标记成一句话），路径1/2/3 只是"这条消息本身也值得
        // 收录"的独立信号，两者同时生效会让语录库里同时存在碎句和整句
        // （"你们潇洒" 与 "你们有钱 你们潇洒"），GET / 随机吐出来的观感比只留
        // 其中一条更差。这条规则对链的第一个成员（主键）也成立，不只是非主键
        // 成员——即便主键那条自己长得也像路径3格式，也不再单独生成路径3候选，
        // 由链的 fire_chain 候选（已经在上面的循环里插入，且已经用 manualBody
        // 剥过它自己的 ✨ 前缀了，见 finalizeChain）代表它。这一条使路径4的
        // 优先级压过路径3，是本次改动特意翻转的：路径3优先于路径1是因为它是
        // 更具体的"作者本人手动指定"信号；路径4优先于路径3/路径1是因为它是
        // 更具体的"分组"信号，而分组这件事没有别的路径能表达。
        const is_chain_member = chainOf(chains, m.message_id) != null;

        // 管理员引用归属：回复目标并只发 `✨ @某人`。目标在建链前已被显式
        // 排除出链正文，所以这里不会被路径4吞掉；目标可以不是 observed，
        // 也可以是管理员自己的原消息。
        if (quotedAuthorCommand(m, p)) |quoted| {
            if (lookup(pool, quoted.target_id) == null) {
                if (!contains(unresolved.items, quoted.target_id)) try unresolved.append(gpa, quoted.target_id);
                continue;
            }
            try appendCandidate(gpa, &cands, .{
                .message_id = quoted.target_id,
                .path = .admin_quoted,
                .text_override = null,
                .chain_members = null,
                .author_uid = quoted.author_uid,
                .creator_uid = m.user_id,
            });
            continue;
        }

        // 路径3 优先于路径1（但链成员整体让路给路径4，见上）
        if (!is_chain_member) {
            if (try manualParse(gpa, m, p)) |manual| {
                errdefer gpa.free(manual.body);
                try appendCandidate(gpa, &cands, .{
                    .message_id = m.message_id,
                    .path = .admin_manual,
                    .text_override = manual.body,
                    .chain_members = null,
                    // `✨ @某人 内容` 时是被 at 的那个人；`✨ 内容` 时是 null，
                    // runner.zig 落回"发这条消息的人"（也就是这位管理员）。
                    .author_uid = manual.author_uid,
                    .creator_uid = m.user_id,
                });
                continue;
            }
        }

        // 路径1：被观察者本人的消息带 ✨ 表情回应，且不是已并入某条 🔥 链的成员
        // （链已经把它的内容拼进 joined 语录了；不排除的话 "你们有钱"、
        // "你们潇洒"、"你们有钱 你们潇洒" 会同时入库）
        if (p.isObserved(m.user_id) and contains(star_ids, m.message_id) and !is_chain_member) {
            try appendCandidate(gpa, &cands, .{
                .message_id = m.message_id,
                .path = .emoji_reaction,
                .text_override = null,
                .chain_members = null,
                .author_uid = null,
            });
            continue;
        }

        // 路径2：**别人**引用一条被观察者的消息，且除 reply 外只有一个 ✨ 文本段。
        //
        // "别人" 这个条件过去写成 `if (m.user_id == p.observed_qq) continue;`
        // ——只有一个被观察者时它等价于 "回复的人不是这条消息的作者"，因为
        // 目标本来就必须是那唯一一个被观察者。把它机械地换成
        // `if (p.isObserved(m.user_id)) continue;` 会在空集合（观察所有人）
        // 下让这一条恒为真，**整条路径2直接失效**，而且不会有任何测试以外
        // 的迹象。正确的推广是把它下移到解析出目标之后，判 "回复的人 ≠ 被
        // 引用消息的作者"：单被观察者配置下与旧行为逐字等价（目标必然是那
        // 个被观察者，于是 `m.user_id != target.user_id` ⇔
        // `m.user_id != observed_qq`），多被观察者/观察所有人时表达的也正是
        // 原本的意思——自己给自己的话贴 ✨ 不算数，别人认可才算。
        const rid = m.replyTarget() orelse continue;
        const txt = m.soleTextBesidesReply() orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, txt, ws), star)) continue;
        const target = lookup(pool, rid) orelse {
            if (!contains(unresolved.items, rid)) try unresolved.append(gpa, rid);
            continue;
        };
        if (!p.isObserved(target.user_id)) continue;
        if (m.user_id == target.user_id) continue;
        // 引用目标是链成员时同样让路给路径4：这条 ✨ 回复只是在说"这句话说得好"，
        // 链已经替它把这句话（连同它的邻居）收进 joined 语录了。
        if (chainOf(chains, rid) != null) continue;
        try appendCandidate(gpa, &cands, .{
            .message_id = rid,
            .path = .quoted_star,
            .text_override = null,
            .chain_members = null,
            .author_uid = null,
        });
    }

    // 剔除已作废的候选
    var kept: std.ArrayList(Candidate) = .empty;
    errdefer {
        // 存活候选的 text_override / chain_members 所有权在下面的循环里从
        // cands 转移到了 kept（cands 随后被 clearAndFree，不再持有它们）；
        // 若这里只 kept.deinit 而不遍历释放，一旦后面任何一次 toOwnedSlice
        // 触发 OOM，这些内存就会泄漏——本文件加的 checkAllAllocationFailures
        // 回归测试正是靠这条路径抓到的。
        for (kept.items) |c| {
            if (c.text_override) |t| gpa.free(t);
            if (c.text_suffix) |t| gpa.free(t);
            if (c.chain_members) |cm| gpa.free(cm);
        }
        kept.deinit(gpa);
    }
    for (cands.items) |*c| {
        if (contains(revoked.items, c.message_id)) {
            if (c.text_override) |t| gpa.free(t);
            if (c.text_suffix) |t| gpa.free(t);
            if (c.chain_members) |cm| gpa.free(cm);
            c.text_override = null; // 防止上方 errdefer 在后续 OOM 时对同一指针重复 free
            c.text_suffix = null;
            c.chain_members = null; // 同理
            continue;
        }
        try kept.append(gpa, c.*);
        c.text_override = null; // 所有权转移给 kept 了；同理防止 cands 的 errdefer 在后续 OOM 时重复 free
        c.text_suffix = null;
        c.chain_members = null; // 同理
    }
    // 用 clearAndFree 而非 deinit：deinit 会把 cands 设为 undefined，
    // 若下面 toOwnedSlice 触发 OOM，函数作用域的 errdefer 会遍历 cands.items
    // 读到 undefined 内存并段错误。clearAndFree 让 cands 保持合法的空列表，
    // errdefer 此时只是安全的空操作。
    cands.clearAndFree(gpa);

    // 💨 只修改已经通过分类、去重和同窗口撤稿的候选。分页边界可能让同一条
    // 回复在 window 里出现两次，所以先按 message_id 去重；随后按
    // time/message_id 排序，使多条补充的拼接顺序不依赖 NapCat 返回数组顺序。
    const tail_msgs = try distinctWindow(gpa, window);
    defer gpa.free(tail_msgs);
    std.mem.sort(onebot.Message, tail_msgs, {}, struct {
        fn lt(_: void, x: onebot.Message, y: onebot.Message) bool {
            return x.time < y.time or (x.time == y.time and x.message_id < y.message_id);
        }
    }.lt);
    for (tail_msgs) |m| {
        if (contains(revoked.items, m.message_id)) continue;
        const body = (try tailAppendBody(gpa, m)) orelse continue;
        defer gpa.free(body);
        const rid = m.replyTarget().?;
        for (kept.items) |*candidate| {
            var matches = candidate.message_id == rid;
            if (!matches) {
                if (candidate.chain_members) |members| matches = contains(members, rid);
            }
            if (!matches) continue;

            if (candidate.text_suffix) |old| {
                const joined = try gpa.alloc(u8, old.len + body.len);
                @memcpy(joined[0..old.len], old);
                @memcpy(joined[old.len..], body);
                gpa.free(old);
                candidate.text_suffix = joined;
            } else {
                candidate.text_suffix = try gpa.dupe(u8, body);
            }
            break;
        }
    }

    // 分三步而不是直接塞进返回结构体字面量：若三次 toOwnedSlice 中某一次
    // 先成功、后一次才因 OOM 失败，成功那次拿到的切片必须有名字才能被
    // errdefer 追上并释放；直接写进 `.field = try ...toOwnedSlice(gpa)` 的话，
    // 先成功的那份内存不会绑定到任何变量，一旦后续字段失败就直接泄漏——
    // 这也是本文件加的 checkAllAllocationFailures 回归测试实际抓到的第三条泄漏路径。
    const revoked_owned = try revoked.toOwnedSlice(gpa);
    errdefer gpa.free(revoked_owned);

    const candidates_owned = try kept.toOwnedSlice(gpa);
    errdefer {
        for (candidates_owned) |c| {
            if (c.text_override) |t| gpa.free(t);
            if (c.text_suffix) |t| gpa.free(t);
            if (c.chain_members) |cm| gpa.free(cm);
        }
        gpa.free(candidates_owned);
    }

    const unresolved_owned = try unresolved.toOwnedSlice(gpa);

    return .{
        .revoked = revoked_owned,
        .candidates = candidates_owned,
        .unresolved = unresolved_owned,
        .skip_collection = skip_collection,
    };
}

/// 按 message_id 去重。显式管理员路径优先于自动路径；其中 admin_quoted 又比
/// admin_manual 更具体（管理员明确指定了“引用哪条、署名给谁”）。
///
/// 两个分支里的 free 都不能删——但注意它们的写法本身不依赖"哪个路径今天
/// 带不带 text_override/chain_members"这类判断：`if (optional) |x| gpa.free(x)`
/// 只看这个候选自己的字段是不是 null，不看 `path`。这不是巧合，是刻意的写法：
/// 一旦要靠"某个路径的 text_override 恒为 null"这种断言来判断该不该 free，
/// 断言本身就必须永远正确——而这类断言天生跟着新路径的增加而变质。这个模块
/// 已经有过两次因为这类假设过期而产生的 double free；本次改动新增的 fire_chain
/// （非 admin_manual 路径）就正好把"只有 admin_manual 带 text_override"这条
/// 旧断言变成了假话，同时它还带上了 chain_members——两个可选字段都必须无
/// 条件按"非 null 就 free"来处理，不看 c.path/existing.path 是谁。
///
///   - else 分支（丢弃新来的 c）：**今天就会被走到**，且不止一种触发方式。
///     一是同一条管理员消息在 window 里出现了两次（c 与 existing 都是
///     admin_manual）——README 线上假设 #2 说明这很可能是 NapCat 的常态行为
///     （`message_seq` 若是闭区间，相邻两页会重叠）。二是理论上若 fire_chain
///     与另一个候选发生 message_id 碰撞也会落到这里（today 不会真的发生，
///     见下一条），c.chain_members 就会在这个分支被释放。删掉这个 free 就是
///     在团队已经预料会走到的路径上引入泄漏。
///   - if 分支（替换掉 existing）：**today**，走到这个分支时 `existing` 只可能
///     是 star_reaction / quoted_star（text_override/chain_members 恒为
///     null），因为 fire_chain 候选在 Pass B 主循环之前就已经全部插入，而
///     Pass B 主循环对任何链成员的 message_id 都不会再产生 admin_manual/
///     emoji_reaction/quoted_star 候选（见 classify 里 `is_chain_member` 那个
///     判断）——appendCandidate 自己看不到这个约束，它活在调用方（classify
///     的 Pass B 循环结构）里，是一处"距离较远"的不变量，不是本函数能强制的
///     局部条件。正因为不能强制，这里的 free 才特意不依赖它：不管这条不变量
///     将来是否被打破，`if (existing.text_override) |t| gpa.free(t)` 和对
///     chain_members 的同款处理都会正确地释放 existing 身上真正持有的东西，
///     不会因为"理论上不该发生"就漏释放。
fn appendCandidate(gpa: std.mem.Allocator, list: *std.ArrayList(Candidate), c: Candidate) !void {
    for (list.items) |*existing| {
        if (existing.message_id != c.message_id) continue;
        const new_priority: u8 = switch (c.path) {
            .admin_quoted => 2,
            .admin_manual => 1,
            else => 0,
        };
        const old_priority: u8 = switch (existing.path) {
            .admin_quoted => 2,
            .admin_manual => 1,
            else => 0,
        };
        if (new_priority > old_priority) {
            if (existing.text_override) |t| gpa.free(t);
            if (existing.text_suffix) |t| gpa.free(t);
            if (existing.chain_members) |cm| gpa.free(cm);
            existing.* = c;
        } else {
            if (c.text_override) |t| gpa.free(t);
            if (c.text_suffix) |t| gpa.free(t);
            if (c.chain_members) |cm| gpa.free(cm);
        }
        return;
    }
    try list.append(gpa, c);
}

const OBSERVED: u64 = 10001;
const ADMIN: u64 = 20001;
const OUTSIDER: u64 = 30001;

fn params() Params {
    return .{ .observed_qqs = &.{OBSERVED}, .admin_qqs = &.{ADMIN} };
}

// 注意：这两个 helper 的形参必须是 comptime。它们的 .segments 指向一个匿名数组
// 字面量（`&.{...}`）。当实参是 comptime-known 时，Zig 会把该字面量常量提升
// （const-promote）为静态只读数据——它进了二进制镜像，不属于任何栈帧，天然与
// 程序同寿命，因此 `const msgs = [_]onebot.Message{ textMsg(...), ... }` 之后
// 无论怎么读都安全。参数一旦被声明为 comptime，调用方传入运行期值（比如循环变量
// 或 var）会直接编译失败，把这条生命周期不变量交给编译器强制执行，而不是依赖注释。
// （题外话：若形参是运行期参数，`&.{...}` 的存储归属于「构造该字面量的那次函数
// 调用」的栈帧，函数返回后即失效——这正是本文件原先出现过的悬垂指针 bug；单独
// 加 inline 在今天的 codegen 下恰好把它落在调用方栈帧里而“凑巧能用”，但不是编译器
// 保证的语义，故改为 comptime 形参从根上让编译器保证正确性。)
fn textMsg(comptime id: i64, comptime uid: u64, comptime txt: []const u8) onebot.Message {
    return .{
        .message_id = id,
        .user_id = uid,
        .time = 0,
        .segments = &.{.{ .text = txt }},
    };
}

fn replyMsg(comptime id: i64, comptime uid: u64, comptime target: i64, comptime txt: []const u8) onebot.Message {
    return .{
        .message_id = id,
        .user_id = uid,
        .time = 0,
        .segments = &.{ .{ .reply = target }, .{ .text = txt } },
    };
}

test "路径1：被观察者的消息带 ✨ 表情回应则入选" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, OBSERVED, "金句"), textMsg(2, OBSERVED, "普通话") };
    var out = try classify(gpa, &msgs, &msgs, &.{1}, &.{}, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(@as(i64, 1), out.candidates[0].message_id);
    try std.testing.expectEqual(Path.emoji_reaction, out.candidates[0].path);
    try std.testing.expectEqual(@as(?[]u8, null), out.candidates[0].text_override);
    try std.testing.expectEqual(@as(?[]i64, null), out.candidates[0].chain_members);
}

test "路径1：非被观察者的消息即使带 ✨ 也不入选" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{textMsg(1, OUTSIDER, "别人的话")};
    var out = try classify(gpa, &msgs, &msgs, &.{1}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
}

test "路径2：他人引用被观察者的消息并只回一个 ✨ → 收录被引用那条" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, OBSERVED, "金句"), replyMsg(2, OUTSIDER, 1, "✨") };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(@as(i64, 1), out.candidates[0].message_id);
    try std.testing.expectEqual(Path.quoted_star, out.candidates[0].path);
}

test "路径2：✨ 前后带空白仍然算数" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, OBSERVED, "金句"), replyMsg(2, OUTSIDER, 1, "  ✨ \n") };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
}

test "路径2：引用的不是被观察者的消息 → 不收录" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, OUTSIDER, "路人话"), replyMsg(2, OUTSIDER, 1, "✨") };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
}

test "路径2：引用消息夹带图片段 → 不收录" {
    const gpa = std.testing.allocator;
    const dirty: onebot.Message = .{
        .message_id = 2,
        .user_id = OUTSIDER,
        .time = 0,
        .segments = &.{ .{ .reply = 1 }, .{ .text = "✨" }, .other },
    };
    const msgs = [_]onebot.Message{ textMsg(1, OBSERVED, "金句"), dirty };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
}

test "路径2：引用目标在缓冲池里但不在窗口内 → 正常解析" {
    const gpa = std.testing.allocator;
    const old = textMsg(1, OBSERVED, "三天前的金句");
    const window = [_]onebot.Message{replyMsg(2, OUTSIDER, 1, "✨")};
    const pool = [_]onebot.Message{ old, window[0] };
    var out = try classify(gpa, &window, &pool, &.{}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(@as(i64, 1), out.candidates[0].message_id);
}

test "路径2：引用目标彻底解析不了 → 记入 unresolved，不中断" {
    const gpa = std.testing.allocator;
    const window = [_]onebot.Message{replyMsg(2, OUTSIDER, 999, "✨")};
    var out = try classify(gpa, &window, &window, &.{}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
    try std.testing.expectEqualSlices(i64, &.{999}, out.unresolved);
}

test "路径3：管理员发 ✨ 加内容 → 收录，正文剥掉前缀" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{textMsg(5, ADMIN, "✨ 手动补录的一句话")};
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(@as(i64, 5), out.candidates[0].message_id);
    try std.testing.expectEqual(Path.admin_manual, out.candidates[0].path);
    try std.testing.expectEqualStrings("手动补录的一句话", out.candidates[0].text_override.?);
}

test "路径3：✨ 与内容之间没有空格也认" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{textMsg(5, ADMIN, "✨紧贴的内容")};
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqualStrings("紧贴的内容", out.candidates[0].text_override.?);
}

test "路径3：管理员只发一个 ✨ → 剥完为空，不收录" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{textMsg(5, ADMIN, "✨   ")};
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
}

test "路径3：非管理员发 ✨ 加内容 → 不收录" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{textMsg(5, OUTSIDER, "✨ 我也想加一句")};
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
}

test "路径3：管理员发 ✨ 加内容但带了 reply 段 → 走路径2判定，不收录" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, OBSERVED, "金句"), replyMsg(5, ADMIN, 1, "✨ 加点评") };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
}

test "路径3 优先于路径1：被观察者兼任管理员时按路径3处理" {
    const gpa = std.testing.allocator;
    const p: Params = .{ .observed_qqs = &.{OBSERVED}, .admin_qqs = &.{OBSERVED} };
    const msgs = [_]onebot.Message{textMsg(5, OBSERVED, "✨ 我自己补一句")};
    var out = try classify(gpa, &msgs, &msgs, &.{5}, &.{}, p);
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(Path.admin_manual, out.candidates[0].path);
    try std.testing.expectEqualStrings("我自己补一句", out.candidates[0].text_override.?);
}

test "作废：管理员 💦 引用被观察者的消息" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, OBSERVED, "失言"), replyMsg(2, ADMIN, 1, "💦") };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqualSlices(i64, &.{1}, out.revoked);
}

test "作废：非管理员发 💦 无效" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, OBSERVED, "失言"), replyMsg(2, OUTSIDER, 1, "💦") };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), out.revoked.len);
}

test "作废：💦 引用管理员发的普通消息 → 不作废" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, ADMIN, "随便说说"), replyMsg(2, ADMIN, 1, "💦") };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), out.revoked.len);
}

test "作废：💦 引用一条路径3手动收录的指令消息 → 应当作废" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, ADMIN, "✨ 手动补录"), replyMsg(2, ADMIN, 1, "💦") };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqualSlices(i64, &.{1}, out.revoked);
    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
}

test "作废优先于收录：同一窗口内被 ✨ 又被 💦 → 不入库" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "争议发言"),
        replyMsg(2, OUTSIDER, 1, "✨"),
        replyMsg(3, ADMIN, 1, "💦"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{1}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqualSlices(i64, &.{1}, out.revoked);
    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
}

test "去重：同一条消息被表情回应与引用 ✨ 同时命中 → 只出现一次" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, OBSERVED, "金句"), replyMsg(2, OUTSIDER, 1, "✨") };
    var out = try classify(gpa, &msgs, &msgs, &.{1}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(@as(i64, 1), out.candidates[0].message_id);
}

test "重复页：同一条路径3消息在窗口里出现两次 → 只留一条候选，且不泄漏 text_override" {
    const gpa = std.testing.allocator;
    // README 线上假设 #2：`message_seq` 若是闭区间，相邻两页会重叠，同一条
    // 消息就会在 window 里出现两次。此时 appendCandidate 会为第二次也算出一份
    // text_override，然后走 else 分支把它丢掉——那个 free 少了的话，
    // std.testing.allocator 会在这个测试上报泄漏。这就是为什么那行不是死代码。
    const m = textMsg(1, ADMIN, "✨ 手动补录测试");
    const msgs = [_]onebot.Message{ m, m };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqualStrings("手动补录测试", out.candidates[0].text_override.?);
}

test "manualBody 单独可用" {
    const gpa = std.testing.allocator;
    const ok = (try manualBody(gpa, textMsg(1, ADMIN, "✨ abc"), params())).?;
    defer gpa.free(ok);
    try std.testing.expectEqualStrings("abc", ok);
    try std.testing.expectEqual(@as(?[]u8, null), try manualBody(gpa, textMsg(1, OUTSIDER, "✨ abc"), params()));
    try std.testing.expectEqual(@as(?[]u8, null), try manualBody(gpa, textMsg(1, ADMIN, "abc"), params()));
}

fn classifyUnderFailingAllocator(gpa: std.mem.Allocator) !void {
    // id=1：路径3候选，随后被 id=2 的 💦 作废 → 命中 :146/:151 附近的
    // free-then-maybe-double-free 路径；id=3：路径3候选且存活 → 让
    // 「剔除已作废候选」循环里 kept.append 之后还有后续工作（toOwnedSlice 等），
    // 从而在更多分配点上练到 :151 的 errdefer 复用问题。
    const msgs = [_]onebot.Message{
        textMsg(1, ADMIN, "✨ aaa"),
        replyMsg(2, ADMIN, 1, "💦"),
        textMsg(3, ADMIN, "✨ bbb"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    out.deinit(gpa);
}

test "OOM 回归：作废与存活的路径3候选混在一起时，任意分配点失败都不能段错误或重复释放" {
    // 覆盖 review 发现的两个缺陷：
    // 1) cands.deinit 把 cands 设为 undefined 后，若后续 toOwnedSlice 触发 OOM，
    //    errdefer 会遍历 undefined 内存并段错误（修复：改用 clearAndFree）。
    // 2) 剔除已作废候选时 free 了 text_override 却没有把它设为 null，若循环里
    //    后续的 append 触发 OOM，errdefer 会对同一指针 free 第二次（修复：free 后置 null）。
    // std.testing.allocator 单独跑无法触及这两条路径——只有在每个分配点都真实失败一次
    // 的穷举下才会暴露，所以用 checkAllAllocationFailures。
    try std.testing.checkAllAllocationFailures(std.testing.allocator, classifyUnderFailingAllocator, .{});
}

fn classifyManySurvivorsUnderFailingAllocator(gpa: std.mem.Allocator) !void {
    // 8 条互不作废的路径3候选，全部存活进 kept。第一次 kept.append 由
    // ArrayList 的初始容量吃掉，之后每次 append 都可能触发一次真正的分配
    // （扩容）。只有存活候选数够多、逼出至少一次「append 之后还有更多 append」
    // 的场景，才能覆盖到「c.* 被拷进 kept 后，cands 里原件的 text_override
    // 必须同步置 null，否则 append 失败时 kept 与 cands 的两个 errdefer
    // 会对同一指针各 free 一次」这条路径——单个存活候选的场景到不了这里。
    const msgs = [_]onebot.Message{
        textMsg(1, ADMIN, "✨ one"),
        textMsg(2, ADMIN, "✨ two"),
        textMsg(3, ADMIN, "✨ three"),
        textMsg(4, ADMIN, "✨ four"),
        textMsg(5, ADMIN, "✨ five"),
        textMsg(6, ADMIN, "✨ six"),
        textMsg(7, ADMIN, "✨ seven"),
        textMsg(8, ADMIN, "✨ eight"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    out.deinit(gpa);
}

test "OOM 回归：≥3 个存活的路径3候选（无作废）时，kept.append 扩容失败不能重复释放" {
    // 覆盖上一轮修复引入的新缺陷：给 kept 的 errdefer 加上按元素遍历释放
    // text_override 后，"剔除已作废候选" 循环里 try kept.append(gpa, c.*)
    // 成功之后，如果不把 cands 里那份原件的 text_override 同步置 null，
    // cands 的原件与 kept 里的拷贝会短暂共享同一个指针；只要循环里后面
    // 还有一次 kept.append 触发 OOM，两个 errdefer 就会各 free 一次，
    // 造成 double free。修复：append 成功后立刻把源指针置 null。
    try std.testing.checkAllAllocationFailures(std.testing.allocator, classifyManySurvivorsUnderFailingAllocator, .{});
}

// ---- 🔥 链式收录 ----

test "🔥链：两条相邻合格消息合并为一条候选，正文空格拼接，且不再各自单独入选" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "你们有钱"),
        textMsg(2, OBSERVED, "你们潇洒"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 2 }, &.{ 1, 2 }, params());
    defer out.deinit(gpa);

    // 只有一条候选（joined），不是三条（两条独立 + 一条 joined）。
    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(@as(i64, 1), out.candidates[0].message_id);
    try std.testing.expectEqual(Path.fire_chain, out.candidates[0].path);
    try std.testing.expectEqualStrings("你们有钱 你们潇洒", out.candidates[0].text_override.?);
    // chain_members 是 runner.zig 用来调用 store.Store.addChain 的关键：必须
    // 带上全部成员（含主键自己），顺序与时间升序一致，这样非主键成员才能被
    // 持久化映射到主键，跨窗口撤稿才有依据（见 store.zig key_chainmember_prefix）。
    try std.testing.expectEqualSlices(i64, &.{ 1, 2 }, out.candidates[0].chain_members.?);
}

test "🔥链：三条依次相连的消息合并成一条（不设两条的上限）" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "第一段"),
        textMsg(2, OBSERVED, "第二段"),
        textMsg(3, OBSERVED, "第三段"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 2, 3 }, &.{ 1, 2, 3 }, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(@as(i64, 1), out.candidates[0].message_id);
    try std.testing.expectEqual(Path.fire_chain, out.candidates[0].path);
    try std.testing.expectEqualStrings("第一段 第二段 第三段", out.candidates[0].text_override.?);
    try std.testing.expectEqualSlices(i64, &.{ 1, 2, 3 }, out.candidates[0].chain_members.?);
}

test "🔥链：桥接消息把整条链连起来——形状图端到端（内容/桥/桥/内容/桥/内容/断）" {
    const gpa = std.testing.allocator;
    // 设计文档 4.5 节路径4 的形状图逐条对应：
    //   1 ✨🔥 被观察者 U   → 内容
    //   2 🔥   任何人       → 桥，正文丢弃
    //   3 🔥   任何人       → 桥，正文丢弃
    //   4 ✨🔥 被观察者 U   → 内容，接上 1
    //   5 🔥   任何人       → 桥
    //   6 ✨🔥 被观察者 U   → 内容，接上
    //   7 无🔥              → 连续段在这里结束
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "A"),
        textMsg(2, OUTSIDER, "X"),
        textMsg(3, OUTSIDER, "Y"),
        textMsg(4, OBSERVED, "B"),
        textMsg(5, OUTSIDER, "Z"),
        textMsg(6, OBSERVED, "C"),
        textMsg(7, OUTSIDER, "D"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 4, 6 }, &.{ 1, 2, 3, 4, 5, 6 }, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(@as(i64, 1), out.candidates[0].message_id);
    try std.testing.expectEqual(Path.fire_chain, out.candidates[0].path);
    // 桥的正文（X / Y / Z）不进语录：桥只说"这句话还没说完"。
    try std.testing.expectEqualStrings("A B C", out.candidates[0].text_override.?);
    // 成员只有内容消息：桥不是成员（见 buildChains 顶部关于撤稿的说明）。
    try std.testing.expectEqualSlices(i64, &.{ 1, 4, 6 }, out.candidates[0].chain_members.?);
}

test "🔥链：桥来自另一个人——一条链可以跨过别人的插话（这正是桥存在的理由）" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "上半句"),
        textMsg(2, THIRD, "别人插了一嘴"),
        textMsg(3, OBSERVED, "下半句"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 3 }, &.{ 1, 2, 3 }, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(Path.fire_chain, out.candidates[0].path);
    try std.testing.expectEqualStrings("上半句 下半句", out.candidates[0].text_override.?);
    try std.testing.expectEqualSlices(i64, &.{ 1, 3 }, out.candidates[0].chain_members.?);
}

test "🔥链：只要 🔥 连续，中间隔多少座桥都相连——间距上限已经删掉了" {
    const gpa = std.testing.allocator;
    // 旧规则给"相邻"设了 3 条消息的间距上限，这里的 5 座桥会让两条内容
    // 消息断开。新规则里 🔥 的连续性**取代**了间距上限：中间这 5 条都带
    // 🔥，说明群里一路在说"这句话还没说完"，链就该一路连下去。
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "开头"),
        textMsg(2, OUTSIDER, "桥1"),
        textMsg(3, OUTSIDER, "桥2"),
        textMsg(4, OUTSIDER, "桥3"),
        textMsg(5, OUTSIDER, "桥4"),
        textMsg(6, OUTSIDER, "桥5"),
        textMsg(7, OBSERVED, "结尾"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 7 }, &.{ 1, 2, 3, 4, 5, 6, 7 }, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(Path.fire_chain, out.candidates[0].path);
    try std.testing.expectEqualStrings("开头 结尾", out.candidates[0].text_override.?);
    try std.testing.expectEqualSlices(i64, &.{ 1, 7 }, out.candidates[0].chain_members.?);
}

test "🔥链：中间一条没有🔥 → 连续段在那里断开，两侧不相连" {
    const gpa = std.testing.allocator;
    // 🔥 的连续性是唯一的相邻规则：中间这条没有 🔥，前后两条内容消息就不是
    // 同一句话，各自退回路径1。旧规则下"隔 1 条"是能连上的——这条测试正是
    // 新旧规则的分界。
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "开头"),
        textMsg(2, OUTSIDER, "无标记的闲聊"),
        textMsg(3, OBSERVED, "结尾"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 3 }, &.{ 1, 3 }, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), out.candidates.len);
    for (out.candidates) |c| {
        try std.testing.expectEqual(Path.emoji_reaction, c.path);
        try std.testing.expectEqual(@as(?[]u8, null), c.text_override);
    }
}

test "🔥链：一条内容消息 + 尾随的桥 → 不成链，退回路径1的普通语录" {
    const gpa = std.testing.allocator;
    // 一条链至少要两条内容消息。只有一条内容、后面跟着若干"这句话还没说完"
    // 的桥，说明那些续写要么没被 ✨ 认可、要么根本不是这个人发的——没有第二
    // 段正文可拼，这就是一条普通的路径1语录。
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "孤零零一句"),
        textMsg(2, OUTSIDER, "桥1"),
        textMsg(3, OUTSIDER, "桥2"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{1}, &.{ 1, 2, 3 }, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(@as(i64, 1), out.candidates[0].message_id);
    try std.testing.expectEqual(Path.emoji_reaction, out.candidates[0].path);
    try std.testing.expectEqual(@as(?[]u8, null), out.candidates[0].text_override);
    try std.testing.expectEqual(@as(?[]i64, null), out.candidates[0].chain_members);
}

test "🔥链：带 ✨ 但作者不在观察集合里的消息算桥——不进正文、也不断链" {
    const gpa = std.testing.allocator;
    // "内容" 要求三件事同时成立：✨、🔥、作者是被观察者。这条消息 ✨🔥 都有
    // 但作者不是被观察者，于是它不是内容；而它带着 🔥，所以连续段不在这里
    // 结束——按 🔥 连续性这条唯一的相邻规则，它就是一座桥。
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "上半句"),
        textMsg(2, OUTSIDER, "集合外的人也被贴了星火"),
        textMsg(3, OBSERVED, "下半句"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 2, 3 }, &.{ 1, 2, 3 }, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(Path.fire_chain, out.candidates[0].path);
    try std.testing.expectEqualStrings("上半句 下半句", out.candidates[0].text_override.?);
    try std.testing.expectEqualSlices(i64, &.{ 1, 3 }, out.candidates[0].chain_members.?);
}

test "🔥链：中途出现另一个被观察者的内容消息 → 不并入，且就地另起一条新链" {
    const gpa = std.testing.allocator;
    // subset 里 OBSERVED 与 OUTSIDER 都是被观察者。三条都 ✨🔥、🔥 连续，
    // 但作者是 A B B：B 的第一条内容消息不能并进 A 的链（同一发送者约束），
    // 它自己成为新 run 的起点，跟后面同作者的那条并成链；A 落单退回路径1。
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "甲的半句"),
        textMsg(2, OUTSIDER, "乙上"),
        textMsg(3, OUTSIDER, "乙下"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 2, 3 }, &.{ 1, 2, 3 }, subset);
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), out.candidates.len);
    try std.testing.expectEqual(Path.fire_chain, out.candidates[0].path);
    try std.testing.expectEqualStrings("乙上 乙下", out.candidates[0].text_override.?);
    try std.testing.expectEqualSlices(i64, &.{ 2, 3 }, out.candidates[0].chain_members.?);
    try std.testing.expectEqual(@as(i64, 1), out.candidates[1].message_id);
    try std.testing.expectEqual(Path.emoji_reaction, out.candidates[1].path);
}

test "🔥链撤稿：💦 引用一座桥 → 不作废这条链，只 tombstone 桥自己" {
    const gpa = std.testing.allocator;
    // 桥不是链的成员：它的正文一个字都没进这条语录，作者也可以是任何人。
    // 把 💦 一座桥当成"撤掉这条 joined 语录"，等于让一个只是恰好被贴了 🔥
    // 的路人替别人的语录做撤稿决定。这里钉死相反的行为：链照常入库。
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "上半句"),
        textMsg(2, THIRD, "桥"),
        textMsg(3, OBSERVED, "下半句"),
        replyMsg(4, ADMIN, 2, "💦"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 3 }, &.{ 1, 2, 3 }, everyone);
    defer out.deinit(gpa);

    // 只有桥自己进 revoked（它在 Redis 里没有任何语录，撤稿退化成一次
    // tombstone），链的两个内容成员都不受影响。
    try std.testing.expectEqualSlices(i64, &.{2}, out.revoked);
    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(Path.fire_chain, out.candidates[0].path);
    try std.testing.expectEqualSlices(i64, &.{ 1, 3 }, out.candidates[0].chain_members.?);
}

test "🔥链：只有✨没有🔥的消息不参与链，仍按路径1单独入选" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "只有星星"),
        textMsg(2, OBSERVED, "星星加火"),
    };
    // msg 1 只有 ✨，msg 2 星火俱全——但 2 落单（没有第二个"星火俱全"的伙伴），
    // 所以两条都退回路径1单独候选，互不合并。
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 2 }, &.{2}, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), out.candidates.len);
    for (out.candidates) |c| try std.testing.expectEqual(Path.emoji_reaction, c.path);
}

test "🔥链：只有🔥没有✨的消息什么都不产生" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{textMsg(1, OBSERVED, "只有火")};
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{1}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
}

test "🔥链：窗口内的重复消息（分页重叠）不会让同一段正文进两遍" {
    const gpa = std.testing.allocator;
    // NapCat 分页是闭区间，相邻两页会把锚点消息重复拉一遍，同一条消息因此
    // 可能在 window 里出现两次。链的正文按去重后的序列拼，否则重叠一次就会
    // 拼出"上 中 中 下"，而且 chain_members 里也会出现重复的 message_id
    // （持久化进 hikari:chain:{主键} 之后，撤稿展开也跟着重复）。
    const dup = textMsg(2, OBSERVED, "中");
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "上"),
        dup,
        dup,
        textMsg(3, OBSERVED, "下"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 2, 3 }, &.{ 1, 2, 3 }, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(Path.fire_chain, out.candidates[0].path);
    try std.testing.expectEqualStrings("上 中 下", out.candidates[0].text_override.?);
    try std.testing.expectEqualSlices(i64, &.{ 1, 2, 3 }, out.candidates[0].chain_members.?);
}

test "🔥链撤稿：💦 引用链上第二个成员，作废整条链，两个成员都进 revoked（都会被 tombstone）" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "你们有钱"),
        textMsg(2, OBSERVED, "你们潇洒"),
        replyMsg(3, ADMIN, 2, "💦"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 2 }, &.{ 1, 2 }, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
    try std.testing.expectEqualSlices(i64, &.{ 1, 2 }, out.revoked);
}

test "🔥链撤稿：💦 引用链上第一个成员（主键），同样作废整条链且两个成员都进 revoked" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "你们有钱"),
        textMsg(2, OBSERVED, "你们潇洒"),
        replyMsg(3, ADMIN, 1, "💦"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 2 }, &.{ 1, 2 }, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
    try std.testing.expectEqualSlices(i64, &.{ 1, 2 }, out.revoked);
}

test "🔥链：路径2引用链上成员被抑制——只留 fire_chain 一条候选，不重复收录被引用的碎句" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "你们有钱"),
        textMsg(2, OBSERVED, "你们潇洒"),
        replyMsg(3, OUTSIDER, 2, "✨"), // 有人单独对链上第二个成员回 ✨
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 2 }, &.{ 1, 2 }, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(@as(i64, 1), out.candidates[0].message_id);
    try std.testing.expectEqual(Path.fire_chain, out.candidates[0].path);
    try std.testing.expectEqualStrings("你们有钱 你们潇洒", out.candidates[0].text_override.?);
}

test "🔥链：非主键成员自身是路径3格式时被抑制为个体候选，joined正文剥掉它的✨前缀" {
    const gpa = std.testing.allocator;
    // 被观察者同时在 ADMIN_QQS 里，这样第二个成员的 "✨ 你们潇洒" 才满足路径3格式。
    const p: Params = .{ .observed_qqs = &.{OBSERVED}, .admin_qqs = &.{OBSERVED} };
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "你们有钱"),
        textMsg(2, OBSERVED, "✨ 你们潇洒"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 2 }, &.{ 1, 2 }, p);
    defer out.deinit(gpa);

    // 只有一条：fire_chain。若没有抑制，会多出一条路径3候选（message_id=2，
    // 正文"你们潇洒"）；若没有剥 ✨，joined 正文会是"你们有钱 ✨ 你们潇洒"。
    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(@as(i64, 1), out.candidates[0].message_id);
    try std.testing.expectEqual(Path.fire_chain, out.candidates[0].path);
    try std.testing.expectEqualStrings("你们有钱 你们潇洒", out.candidates[0].text_override.?);
}

test "🔥链：主键自身是路径3格式时同样被抑制，链仍然赢（路径4压过路径3）" {
    const gpa = std.testing.allocator;
    const p: Params = .{ .observed_qqs = &.{OBSERVED}, .admin_qqs = &.{OBSERVED} };
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "✨ 你们有钱"),
        textMsg(2, OBSERVED, "你们潇洒"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 2 }, &.{ 1, 2 }, p);
    defer out.deinit(gpa);

    // 若路径3仍然优先（旧规则），这里会得到 message_id=1、path=admin_manual、
    // 正文"你们有钱"（丢了"你们潇洒"）。新规则下链赢，两段都在，✨ 也被剥掉了。
    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(@as(i64, 1), out.candidates[0].message_id);
    try std.testing.expectEqual(Path.fire_chain, out.candidates[0].path);
    try std.testing.expectEqualStrings("你们有钱 你们潇洒", out.candidates[0].text_override.?);
}

fn classifyChainUnderFailingAllocator(gpa: std.mem.Allocator) !void {
    // 三条相连的合格消息：练到 distinctWindow、finalizeChain（ids 与 text 两次
    // ArrayList 构建）、buildChains 里 chains 列表的扩容，以及 Pass B 把 chain
    // 候选并入 cands 时的所有权转移，这些都是本次改动新增的分配点。
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "你们有钱"),
        textMsg(2, OBSERVED, "你们潇洒"),
        textMsg(3, OBSERVED, "还挺开心"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 2, 3 }, &.{ 1, 2, 3 }, params());
    out.deinit(gpa);
}

test "OOM 回归：🔥链构建（buildChains/finalizeChain）在任意分配点失败都不能段错误或重复释放" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, classifyChainUnderFailingAllocator, .{});
}

fn classifyChainRevokedUnderFailingAllocator(gpa: std.mem.Allocator) !void {
    // 链建好之后又被 💦 撤稿：额外练到 Pass A 里 chainOf 命中后把全部成员
    // 循环塞进 revoked 这条路径。
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "你们有钱"),
        textMsg(2, OBSERVED, "你们潇洒"),
        replyMsg(3, ADMIN, 2, "💦"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 2 }, &.{ 1, 2 }, params());
    out.deinit(gpa);
}

test "OOM 回归：🔥链被 💦 撤稿（revoked 展开为全部成员）时任意分配点失败都不能段错误或重复释放" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, classifyChainRevokedUnderFailingAllocator, .{});
}

fn classifyBridgedChainUnderFailingAllocator(gpa: std.mem.Allocator) !void {
    // 桥接形态的链构建：内容/桥/桥/内容/桥/内容/断——练 buildChains 新的
    // 走法上的每一个分配点（run 的扩容、桥不入 run 时的跳过分支、连续段
    // 结束时的 finalizeChain 里 ids 与 text 两次 ArrayList 构建、chains
    // 扩容、Pass B 转移所有权时的 chain_members dupe），并确保桥的存在
    // 不会在任何一个失败点上留下泄漏或重复释放。
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "A"),
        textMsg(2, OUTSIDER, "X"),
        textMsg(3, OUTSIDER, "Y"),
        textMsg(4, OBSERVED, "B"),
        textMsg(5, OUTSIDER, "Z"),
        textMsg(6, OBSERVED, "C"),
        textMsg(7, OUTSIDER, "D"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 4, 6 }, &.{ 1, 2, 3, 4, 5, 6 }, params());
    out.deinit(gpa);
}

test "OOM 回归：带桥的🔥链构建在任意分配点失败都不能段错误或重复释放" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, classifyBridgedChainUnderFailingAllocator, .{});
}

// ---------------------------------------------------------------------------
// 观察所有人（OBSERVED_QQS 为空）——这是部署上的常态配置，不是兜底分支。
// 下面这组测试逐条路径确认 Params.isObserved 的"空集合 = 全部"语义真的贯穿到
// 了四条收录路径、撤稿目标判定和链构建，而不是只改了其中几处。

const everyone: Params = .{ .observed_qqs = &.{}, .admin_qqs = &.{ADMIN} };
const subset: Params = .{ .observed_qqs = &.{ OBSERVED, OUTSIDER }, .admin_qqs = &.{ADMIN} };
const THIRD: u64 = 40001;

test "isObserved：空集合对任何人都为真，非空集合只对集合内的人为真" {
    try std.testing.expect(everyone.isObserved(OBSERVED));
    try std.testing.expect(everyone.isObserved(OUTSIDER));
    try std.testing.expect(everyone.isObserved(0));
    try std.testing.expect(subset.isObserved(OBSERVED));
    try std.testing.expect(subset.isObserved(OUTSIDER));
    try std.testing.expect(!subset.isObserved(THIRD));
}

test "观察所有人 · 路径1：任何人的消息带 ✨ 都入选" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, OUTSIDER, "路人甲的金句"), textMsg(2, THIRD, "路人乙的话") };
    var out = try classify(gpa, &msgs, &msgs, &.{1}, &.{}, everyone);
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(@as(i64, 1), out.candidates[0].message_id);
    try std.testing.expectEqual(Path.emoji_reaction, out.candidates[0].path);
}

test "观察所有人 · 路径2：任何人引用任何**别人**的消息回 ✨ 都收录被引用那条" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, OUTSIDER, "路人甲的金句"), replyMsg(2, THIRD, 1, "✨") };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, everyone);
    defer out.deinit(gpa);
    // 机械地把 `m.user_id == observed_qq` 换成 `isObserved(m.user_id)` 会让
    // 这条恒为真、整条路径2静默失效——这个测试就是那条回归的守卫。
    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(@as(i64, 1), out.candidates[0].message_id);
    try std.testing.expectEqual(Path.quoted_star, out.candidates[0].path);
}

test "观察所有人 · 路径2：自己给自己的话回 ✨ 不算数（自吹不是他人认可）" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, OUTSIDER, "我说得真好"), replyMsg(2, OUTSIDER, 1, "✨") };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, everyone);
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
}

test "配置了子集时 · 路径2：集合内的 A 认可集合内的 B → 收录（单人配置下这一条退化成旧行为）" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, OBSERVED, "B 的金句"), replyMsg(2, OUTSIDER, 1, "✨") };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, subset);
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(@as(i64, 1), out.candidates[0].message_id);
}

test "配置了子集时 · 路径1：集合外的人带 ✨ 仍然不入选" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{textMsg(1, THIRD, "集合外的人")};
    var out = try classify(gpa, &msgs, &msgs, &.{1}, &.{}, subset);
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
}

test "观察所有人 · 路径3：管理员手动收录不受影响（ADMIN_QQS 与观察集合是两回事）" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{textMsg(1, ADMIN, "✨ 手动补录")};
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, everyone);
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(Path.admin_manual, out.candidates[0].path);
    try std.testing.expectEqualStrings("手动补录", out.candidates[0].text_override.?);
}

test "观察所有人 · 路径4：任何人的连续消息带 ✨+🔥 都能并成链" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{
        textMsg(1, OUTSIDER, "你们有钱"),
        textMsg(2, OUTSIDER, "你们潇洒"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 2 }, &.{ 1, 2 }, everyone);
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(Path.fire_chain, out.candidates[0].path);
    try std.testing.expectEqualStrings("你们有钱 你们潇洒", out.candidates[0].text_override.?);
}

test "观察所有人 · 撤稿：管理员 💦 引用任何人的消息都能作废" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, THIRD, "路人的话"), replyMsg(2, ADMIN, 1, "💦") };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, everyone);
    defer out.deinit(gpa);
    try std.testing.expectEqualSlices(i64, &.{1}, out.revoked);
}

test "配置了子集时 · 撤稿：💦 引用集合外的人的普通消息 → 不作废（旧行为原样保留）" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{ textMsg(1, THIRD, "集合外的话"), replyMsg(2, ADMIN, 1, "💦") };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, subset);
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), out.revoked.len);
}

// ---------------------------------------------------------------------------
// 🔥 链的同一发送者约束。

test "🔥链：发送者中途变化 → 断链，两个人各自的半句不会被拼成一条" {
    const gpa = std.testing.allocator;
    // 两条相邻、都带 ✨+🔥，但分别是两个人发的。观察所有人之后这不是理论
    // 情形：任何两个人前后脚说话都可能撞上。合并会产出一条谁都没说过的
    // 语录，`from_who` 也只能取其中一个人——必须断开。
    const msgs = [_]onebot.Message{
        textMsg(1, OUTSIDER, "你们有钱"),
        textMsg(2, THIRD, "你们潇洒"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 2 }, &.{ 1, 2 }, everyone);
    defer out.deinit(gpa);

    // 两条都退回路径1单独收录，没有任何 fire_chain 候选。
    try std.testing.expectEqual(@as(usize, 2), out.candidates.len);
    for (out.candidates) |c| {
        try std.testing.expectEqual(Path.emoji_reaction, c.path);
        try std.testing.expectEqual(@as(?[]i64, null), c.chain_members);
    }
}

test "🔥链：A A B B → 断成两条各自成链，成员不跨作者混入" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{
        textMsg(1, OUTSIDER, "甲上"),
        textMsg(2, OUTSIDER, "甲下"),
        textMsg(3, THIRD, "乙上"),
        textMsg(4, THIRD, "乙下"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 2, 3, 4 }, &.{ 1, 2, 3, 4 }, everyone);
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), out.candidates.len);
    try std.testing.expectEqual(Path.fire_chain, out.candidates[0].path);
    try std.testing.expectEqualStrings("甲上 甲下", out.candidates[0].text_override.?);
    try std.testing.expectEqualSlices(i64, &.{ 1, 2 }, out.candidates[0].chain_members.?);
    try std.testing.expectEqual(Path.fire_chain, out.candidates[1].path);
    try std.testing.expectEqualStrings("乙上 乙下", out.candidates[1].text_override.?);
    try std.testing.expectEqualSlices(i64, &.{ 3, 4 }, out.candidates[1].chain_members.?);
}

test "🔥链：A B A（中间夹一条别人的合格消息）→ 两端的 A 不会跨过 B 连起来" {
    const gpa = std.testing.allocator;
    // 🔥 是连续的（三条都带），所以断链的原因不是相邻规则，而是同一发送者
    // 约束：中间那条是乙发的**内容**消息（✨+🔥+被观察者），它不并进甲的链、
    // 而是就地另起一条 run；甲的两条各自落单，三条全部退回路径1。
    const msgs = [_]onebot.Message{
        textMsg(1, OUTSIDER, "甲上"),
        textMsg(2, THIRD, "乙插话"),
        textMsg(3, OUTSIDER, "甲下"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 2, 3 }, &.{ 1, 2, 3 }, everyone);
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), out.candidates.len);
    for (out.candidates) |c| try std.testing.expectEqual(Path.emoji_reaction, c.path);
}

fn classifyEveryoneChainUnderFailingAllocator(gpa: std.mem.Allocator) !void {
    // 观察所有人 + 同一发送者约束下的链构建：A A B B B，两条链各自成立，
    // 练 buildChains 里"发送者变化时先 finalize 旧 run 再起新 run"这条
    // 新分支上的每一个分配点（ids/text 两次 ArrayList、chains 扩容、
    // Pass B 转移所有权时的 chain_members dupe）。
    const msgs = [_]onebot.Message{
        textMsg(1, OUTSIDER, "甲上"),
        textMsg(2, OUTSIDER, "甲下"),
        textMsg(3, THIRD, "乙上"),
        textMsg(4, THIRD, "乙中"),
        textMsg(5, THIRD, "乙下"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 2, 3, 4, 5 }, &.{ 1, 2, 3, 4, 5 }, everyone);
    out.deinit(gpa);
}

test "OOM 回归：同一发送者约束下的多条链构建，任意分配点失败都不泄漏也不重复释放" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, classifyEveryoneChainUnderFailingAllocator, .{});
}

// ---------------------------------------------------------------------------
// 路径3 的 `✨ @某人 内容` 语法（design.md §4.5 路径3）：作者是被 at 的人，
// 添加者（creator）仍然是敲指令的管理员。判定必须走**段列表**——renderText
// 把 at 段烧成 `@昵称` 就把 QQ 号丢了，而作者恰恰只能从那个 QQ 号来。

const NAMED: u64 = 50001;

/// `[text(prefix), at{qq,name}, text(suffix)]` 三段式，模拟 NapCat 对
/// `✨ @某人 内容` 的真实分段。
fn atMsg(
    comptime id: i64,
    comptime uid: u64,
    comptime prefix: []const u8,
    comptime qq: []const u8,
    comptime name: ?[]const u8,
    comptime suffix: []const u8,
) onebot.Message {
    return .{
        .message_id = id,
        .user_id = uid,
        .time = 0,
        .segments = &.{
            .{ .text = prefix },
            .{ .at = .{ .qq = qq, .name = name } },
            .{ .text = suffix },
        },
    };
}

fn replyAtMsg(
    comptime id: i64,
    comptime uid: u64,
    comptime target: i64,
    comptime qq: []const u8,
    comptime name: ?[]const u8,
) onebot.Message {
    return .{
        .message_id = id,
        .user_id = uid,
        .time = 0,
        .segments = &.{
            .{ .reply = target },
            .{ .text = "✨ " },
            .{ .at = .{ .qq = qq, .name = name } },
        },
    };
}

test "管理员引用归属：reply + ✨ @某人 收录引用目标，目标可为管理员自己的消息" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{
        textMsg(1, ADMIN, "管理员自己的原话"),
        replyAtMsg(2, ADMIN, 1, "50001", "小明"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    const candidate = out.candidates[0];
    try std.testing.expectEqual(Path.admin_quoted, candidate.path);
    try std.testing.expectEqual(@as(i64, 1), candidate.message_id);
    try std.testing.expectEqual(@as(?u64, NAMED), candidate.author_uid);
    try std.testing.expectEqual(@as(?u64, ADMIN), candidate.creator_uid);
    try std.testing.expectEqual(@as(?[]u8, null), candidate.text_override);
}

test "管理员引用归属：目标与被 at 作者都不要求属于 observed 集合" {
    const gpa = std.testing.allocator;
    const observed_subset: Params = .{ .observed_qqs = &.{OBSERVED}, .admin_qqs = &.{ADMIN} };
    const msgs = [_]onebot.Message{
        textMsg(1, OUTSIDER, "集合外原话"),
        replyAtMsg(2, ADMIN, 1, "50001", "小明"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, observed_subset);
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(Path.admin_quoted, out.candidates[0].path);
    try std.testing.expectEqual(@as(?u64, NAMED), out.candidates[0].author_uid);
}

test "管理员引用归属：非管理员、夹带正文或图片都不是控制命令" {
    const ordinary = replyAtMsg(2, OUTSIDER, 1, "50001", "小明");
    try std.testing.expectEqual(@as(?QuotedAuthor, null), quotedAuthorCommand(ordinary, params()));

    const with_body: onebot.Message = .{
        .message_id = 3,
        .user_id = ADMIN,
        .time = 0,
        .segments = &.{
            .{ .reply = 1 },
            .{ .text = "✨ " },
            .{ .at = .{ .qq = "50001", .name = "小明" } },
            .{ .text = " 多余正文" },
        },
    };
    try std.testing.expectEqual(@as(?QuotedAuthor, null), quotedAuthorCommand(with_body, params()));

    const with_image: onebot.Message = .{
        .message_id = 4,
        .user_id = ADMIN,
        .time = 0,
        .segments = &.{
            .{ .reply = 1 },
            .{ .text = "✨ " },
            .{ .at = .{ .qq = "50001", .name = "小明" } },
            .{ .image = .{ .file = "x.png", .url = null } },
        },
    };
    try std.testing.expectEqual(@as(?QuotedAuthor, null), quotedAuthorCommand(with_image, params()));
}

test "管理员手动收录：光杆 ✨ 仍无效，但同条带图片时形成空候选等待 OCR" {
    const gpa = std.testing.allocator;
    const image_command: onebot.Message = .{
        .message_id = 1,
        .user_id = ADMIN,
        .time = 0,
        .segments = &.{
            .{ .text = "✨" },
            .{ .image = .{ .file = "image-id", .url = null } },
        },
    };
    const msgs = [_]onebot.Message{image_command};
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(Path.admin_manual, out.candidates[0].path);
    try std.testing.expectEqual(@as(usize, 0), out.candidates[0].text_override.?.len);
}

test "路径3 · at 语法：✨ @某人 内容 → 作者是被 at 的人，正文不含 ✨ 也不含那个 at" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{atMsg(1, ADMIN, "✨ ", "50001", "小明", " 这句是他说的")};
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(Path.admin_manual, out.candidates[0].path);
    try std.testing.expectEqualStrings("这句是他说的", out.candidates[0].text_override.?);
    try std.testing.expectEqual(@as(?u64, NAMED), out.candidates[0].author_uid);
    // 主键仍然是管理员那条指令消息本身，不是被 at 的人的任何一条消息。
    try std.testing.expectEqual(@as(i64, 1), out.candidates[0].message_id);
}

test "路径3 · at 语法：✨ 与 at 之间没有空格也认（分段是 [✨, at, 内容]）" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{atMsg(1, ADMIN, "✨", "50001", "小明", "内容")};
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqualStrings("内容", out.candidates[0].text_override.?);
    try std.testing.expectEqual(@as(?u64, NAMED), out.candidates[0].author_uid);
}

test "路径3 · at 语法：✨ 内容（没有 at）行为逐字不变，author_uid 为 null" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{textMsg(1, ADMIN, "✨ 好一句话")};
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqualStrings("好一句话", out.candidates[0].text_override.?);
    try std.testing.expectEqual(@as(?u64, null), out.candidates[0].author_uid);
}

test "路径3 · at 语法：只有紧跟 ✨ 的 at 是作者标记，后面的 at 是普通正文（渲染成 @昵称）" {
    const gpa = std.testing.allocator;
    // `✨ 你好 @小明` —— at 前面已经有正文了，它不是作者标记。
    const msgs = [_]onebot.Message{.{
        .message_id = 1,
        .user_id = ADMIN,
        .time = 0,
        .segments = &.{
            .{ .text = "✨ 你好 " },
            .{ .at = .{ .qq = "50001", .name = "小明" } },
        },
    }};
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqualStrings("你好 @小明", out.candidates[0].text_override.?);
    try std.testing.expectEqual(@as(?u64, null), out.candidates[0].author_uid);
}

test "路径3 · at 语法：作者标记之后的 at 仍然渲染成 @昵称，只有第一个被吃掉" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{.{
        .message_id = 1,
        .user_id = ADMIN,
        .time = 0,
        .segments = &.{
            .{ .text = "✨ " },
            .{ .at = .{ .qq = "50001", .name = "小明" } },
            .{ .text = " 谢谢 " },
            .{ .at = .{ .qq = "60001", .name = "小红" } },
        },
    }};
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);

    try std.testing.expectEqualStrings("谢谢 @小红", out.candidates[0].text_override.?);
    try std.testing.expectEqual(@as(?u64, NAMED), out.candidates[0].author_uid);
}

test "路径3 · at 语法：✨ @某人 后面没有正文 → 空路径3候选，计 skipped 且不能跌落路径1" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{.{
        .message_id = 1,
        .user_id = ADMIN,
        .time = 0,
        .segments = &.{
            .{ .text = "✨ " },
            .{ .at = .{ .qq = "50001", .name = "小明" } },
            .{ .text = "   " },
        },
    }};
    // 即使这条消息本身还带了 ✨ reaction，也必须由更具体的路径3赢；旧实现
    // manualParse 返回 null 后会跌落路径1，把 `✨ @小明` 原样收进库。
    var out = try classify(gpa, &msgs, &msgs, &.{1}, &.{}, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(Path.admin_manual, out.candidates[0].path);
    try std.testing.expectEqual(@as(usize, 0), out.candidates[0].text_override.?.len);
    try std.testing.expectEqual(@as(?u64, NAMED), out.candidates[0].author_uid);
}

test "路径3 · at 语法：被 at 的人不在 OBSERVED_QQS 里也照样收录（管理员在显式断言作者）" {
    const gpa = std.testing.allocator;
    // 观察集合里只有 OBSERVED / OUTSIDER，被 at 的 NAMED 不在里面。
    const msgs = [_]onebot.Message{atMsg(1, ADMIN, "✨ ", "50001", "小明", " 集合外的人说的")};
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, subset);
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(@as(?u64, NAMED), out.candidates[0].author_uid);
}

test "路径3 · at 语法：@全体成员（qq 不是数字）不是作者标记，原样渲染进正文" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{atMsg(1, ADMIN, "✨ ", "all", "全体成员", " 大家好")};
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqualStrings("@全体成员 大家好", out.candidates[0].text_override.?);
    try std.testing.expectEqual(@as(?u64, null), out.candidates[0].author_uid);
}

test "路径3 · at 语法：at 缺 name 时正文里退化成 @QQ号，作者标记本身仍按 qq 解析" {
    const gpa = std.testing.allocator;
    // 第一个 at 是作者标记（被吃掉），第二个 at 缺 name → 渲染成 @60001。
    const msgs = [_]onebot.Message{.{
        .message_id = 1,
        .user_id = ADMIN,
        .time = 0,
        .segments = &.{
            .{ .text = "✨" },
            .{ .at = .{ .qq = "50001", .name = null } },
            .{ .text = "对 " },
            .{ .at = .{ .qq = "60001", .name = null } },
            .{ .text = " 说的" },
        },
    }};
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);

    try std.testing.expectEqualStrings("对 @60001 说的", out.candidates[0].text_override.?);
    try std.testing.expectEqual(@as(?u64, NAMED), out.candidates[0].author_uid);
}

test "路径3 · at 语法：消息以 at 开头（渲染出来是 @ 而不是 ✨）→ 不是路径3" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{.{
        .message_id = 1,
        .user_id = ADMIN,
        .time = 0,
        .segments = &.{
            .{ .at = .{ .qq = "50001", .name = "小明" } },
            .{ .text = " ✨ 内容" },
        },
    }};
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
}

test "路径3 · at 语法：前导的 image 段与空白 text 段不影响判定（跟 renderText 口径一致）" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{.{
        .message_id = 1,
        .user_id = ADMIN,
        .time = 0,
        .segments = &.{
            .other,
            .{ .text = "" },
            .{ .text = "  " },
            .{ .text = "✨ " },
            .{ .at = .{ .qq = "50001", .name = "小明" } },
            .{ .text = " 内容" },
        },
    }};
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqualStrings("内容", out.candidates[0].text_override.?);
    try std.testing.expectEqual(@as(?u64, NAMED), out.candidates[0].author_uid);
}

test "manualParse 单独可用：返回正文与作者" {
    const gpa = std.testing.allocator;
    const m = atMsg(1, ADMIN, "✨ ", "50001", "小明", " 内容");
    const parsed = (try manualParse(gpa, m, params())).?;
    defer gpa.free(parsed.body);
    try std.testing.expectEqualStrings("内容", parsed.body);
    try std.testing.expectEqual(@as(?u64, NAMED), parsed.author_uid);
}

fn manualAtUnderFailingAllocator(gpa: std.mem.Allocator) !void {
    // `✨ @某人 内容`（多分配：renderSegments 的 ArrayList 扩容 + 最终 dupe）
    // 与一条普通 `✨ 内容` 混在一起 → 让「剔除已作废候选 / kept.append /
    // toOwnedSlice」这几段在两个 text_override 都在场的情况下逐个分配点失败。
    const msgs = [_]onebot.Message{
        atMsg(1, ADMIN, "✨ ", "50001", "小明", " 被 at 的人说的这一句要足够长一点"),
        textMsg(2, ADMIN, "✨ 管理员自己补录的另一句"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    out.deinit(gpa);
}

test "OOM 回归：✨ @某人 内容 的多次分配（renderSegments + dupe + 候选转移）任意一处失败都不泄漏" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, manualAtUnderFailingAllocator, .{});
}

// ---------------------------------------------------------------------------
// 💨：引用一个最终成立的候选，把控制符后的正文无空格追加到语录末尾。

test "💨：多条回复按时间顺序无空格追加，控制回复自身即使带 ✨ 也不成为候选" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{
        .{ .message_id = 1, .user_id = OBSERVED, .time = 1, .segments = &.{.{ .text = "前半句" }} },
        .{ .message_id = 3, .user_id = OUTSIDER, .time = 3, .segments = &.{ .{ .reply = 1 }, .{ .text = "💨 丙" } } },
        .{ .message_id = 2, .user_id = OUTSIDER, .time = 2, .segments = &.{ .{ .reply = 1 }, .{ .text = "  💨 乙  " } } },
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 2, 3 }, &.{}, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(@as(i64, 1), out.candidates[0].message_id);
    try std.testing.expectEqualStrings("乙丙", out.candidates[0].text_suffix.?);
}

test "💨：回复链上任意内容成员都追加到整条 fire_chain 候选" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{
        .{ .message_id = 1, .user_id = OBSERVED, .time = 1, .segments = &.{.{ .text = "上" }} },
        .{ .message_id = 2, .user_id = OBSERVED, .time = 2, .segments = &.{.{ .text = "下" }} },
        .{ .message_id = 3, .user_id = OUTSIDER, .time = 3, .segments = &.{ .{ .reply = 2 }, .{ .text = "💨！" } } },
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 2 }, &.{ 1, 2 }, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(Path.fire_chain, out.candidates[0].path);
    try std.testing.expectEqualStrings("！", out.candidates[0].text_suffix.?);
}

test "💨：补充回复在同窗口被管理员撤掉后不再追加" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{
        .{ .message_id = 1, .user_id = OBSERVED, .time = 1, .segments = &.{.{ .text = "原文" }} },
        .{ .message_id = 2, .user_id = OBSERVED, .time = 2, .segments = &.{ .{ .reply = 1 }, .{ .text = "💨补充" } } },
        .{ .message_id = 3, .user_id = ADMIN, .time = 3, .segments = &.{ .{ .reply = 2 }, .{ .text = "💦" } } },
    };
    var out = try classify(gpa, &msgs, &msgs, &.{1}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(@as(?[]u8, null), out.candidates[0].text_suffix);
    try std.testing.expect(contains(out.revoked, 2));
}

test "💨：at 段移动到补丁最前面，多个 at 保持顺序" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "原文"),
        .{
            .message_id = 2,
            .user_id = OUTSIDER,
            .time = 2,
            .segments = &.{
                .{ .reply = 1 },
                .{ .text = "💨 内容" },
                .{ .at = .{ .qq = "9", .name = "甲" } },
                .{ .at = .{ .qq = "10", .name = "乙" } },
            },
        },
    };
    var out = try classify(gpa, &msgs, &msgs, &.{1}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    // 追加到原文时仍不额外插空格，最终正文是“原文@甲 @乙 内容”。
    try std.testing.expectEqualStrings("@甲 @乙 内容", out.candidates[0].text_suffix.?);
}

test "💨：没有正文、夹带 image、或目标不是候选时完全无效" {
    const gpa = std.testing.allocator;
    const no_body = replyMsg(2, OUTSIDER, 1, "💨  ");
    try std.testing.expectEqual(@as(?[]u8, null), try tailAppendBody(gpa, no_body));
    const dirty: onebot.Message = .{
        .message_id = 3,
        .user_id = OUTSIDER,
        .time = 0,
        .segments = &.{ .{ .reply = 1 }, .{ .text = "💨内容" }, .{ .image = .{ .file = "x", .url = null } } },
    };
    try std.testing.expectEqual(@as(?[]u8, null), try tailAppendBody(gpa, dirty));

    const msgs = [_]onebot.Message{ textMsg(1, OBSERVED, "未触发"), replyMsg(2, OUTSIDER, 1, "💨补充") };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
}

fn tailAppendUnderFailingAllocator(gpa: std.mem.Allocator) !void {
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "原文"),
        replyMsg(2, OUTSIDER, 1, "💨甲"),
        replyMsg(3, OUTSIDER, 1, "💨乙"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{1}, &.{}, params());
    out.deinit(gpa);
}

test "OOM 回归：多条 💨 反复扩容与候选所有权转移任意失败点都不泄漏" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, tailAppendUnderFailingAllocator, .{});
}

// ---------------------------------------------------------------------------
// 💦 的一跳（design.md §4.3）：💦 引用的是那条路径2的 `✨` 触发消息时，撤稿
// 目标解析成**那条 ✨ 引用的消息**，然后所有既有规则原样再跑一遍。

test "💦 一跳：引用路径2的 ✨ 触发消息 → 作废那条 ✨ 引用的原消息" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "金句"), // 原消息，路径2收录的就是它
        replyMsg(2, OUTSIDER, 1, "✨"), // 路径2触发消息
        replyMsg(3, ADMIN, 2, "💦"), // 管理员 💦 的是那条 ✨，不是原消息
    };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), out.revoked.len);
    try std.testing.expectEqual(@as(i64, 1), out.revoked[0]);
    // 同一个窗口里的路径2候选也因此被剔除（作废优先于收录）。
    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
}

test "💦 一跳：引用管理员的 ✨ @某人 引用归属命令 → 作废真正入库的原消息" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{
        textMsg(1, OUTSIDER, "不在 observed 的原话"),
        replyAtMsg(2, ADMIN, 1, "50001", "小明"),
        replyMsg(3, ADMIN, 2, "💦"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);

    try std.testing.expectEqualSlices(i64, &.{1}, out.revoked);
    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
}

test "💦 一跳：作者自己回自己的消息 ✨ 不构成路径2，只按旧规则作废触发消息本身" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "金句"),
        replyMsg(2, OBSERVED, 1, "✨"), // 自己认可自己，不是路径2触发
        replyMsg(3, ADMIN, 2, "💦"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);

    try std.testing.expectEqualSlices(i64, &.{2}, out.revoked);
}

test "💦 一跳：原消息不在观察集合时不构成路径2，不能借 💦 作废管理员手动语录" {
    const gpa = std.testing.allocator;
    const p: Params = .{ .observed_qqs = &.{OBSERVED}, .admin_qqs = &.{ADMIN} };
    const msgs = [_]onebot.Message{
        textMsg(1, ADMIN, "✨ 一条管理员手动语录"), // 路径3，但不是被观察原消息
        replyMsg(2, OUTSIDER, 1, "✨"),
        replyMsg(3, ADMIN, 2, "💦"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, p);
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), out.revoked.len);
    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(@as(i64, 1), out.candidates[0].message_id);
}

test "💦 一跳：跳到的消息是 🔥 链的内容成员 → 整条链全部成员都进 revoked" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "上半句"),
        textMsg(2, OBSERVED, "下半句"),
        replyMsg(3, OUTSIDER, 2, "✨"), // 对链上第二个成员回 ✨
        replyMsg(4, ADMIN, 3, "💦"), // 💦 那条 ✨ → 一跳到 2 → 展开成整条链
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 2 }, &.{ 1, 2 }, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), out.revoked.len);
    try std.testing.expect(contains(out.revoked, 1));
    try std.testing.expect(contains(out.revoked, 2));
    try std.testing.expectEqual(@as(usize, 0), out.candidates.len);
}

test "💦 一跳：只跳一次——被跳到的还是一条 ✨ 触发消息时不继续往下跳" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "金句"),
        replyMsg(2, OUTSIDER, 1, "✨"),
        replyMsg(3, OUTSIDER, 2, "✨"), // 又一条 ✨，引用的是上一条 ✨
        replyMsg(4, ADMIN, 3, "💦"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);

    // 一跳落在 id=2 那条 ✨ 触发消息上：它的发送者 OUTSIDER 不是被观察者、
    // 也不是路径3格式 → 不是可作废的目标 → 什么都不发生。
    try std.testing.expectEqual(@as(usize, 0), out.revoked.len);
}

test "💦 一跳：跳到的目标不在 pool 里 → 记 unresolved，什么都不作废" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{
        replyMsg(2, OUTSIDER, 999, "✨"), // 它引用的 999 不在窗口也不在 pool
        replyMsg(3, ADMIN, 2, "💦"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), out.revoked.len);
    try std.testing.expectEqual(@as(usize, 1), out.unresolved.len);
    try std.testing.expectEqual(@as(i64, 999), out.unresolved[0]);
}

test "💦 一跳只在目标确实是 ✨ 触发消息时发生：目标是普通引用消息 → 行为逐字不变" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "金句"),
        replyMsg(2, OBSERVED, 1, "我也这么想"), // 普通回复，不是 ✨ 触发
        replyMsg(3, ADMIN, 2, "💦"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);

    // 没有一跳：作废的是 id=2 自己（它的发送者是被观察者，本来就是合法目标）。
    try std.testing.expectEqual(@as(usize, 1), out.revoked.len);
    try std.testing.expectEqual(@as(i64, 2), out.revoked[0]);
}

fn dropHopUnderFailingAllocator(gpa: std.mem.Allocator) !void {
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "上半句"),
        textMsg(2, OBSERVED, "下半句"),
        replyMsg(3, OUTSIDER, 2, "✨"),
        replyMsg(4, ADMIN, 3, "💦"),
        textMsg(5, ADMIN, "✨ 同一轮里还有一条存活的手动收录"),
    };
    var out = try classify(gpa, &msgs, &msgs, &.{ 1, 2 }, &.{ 1, 2 }, params());
    out.deinit(gpa);
}

test "OOM 回归：💦 一跳 + 链展开 + 存活候选混在一起时任意分配点失败都不泄漏也不重复释放" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, dropHopUnderFailingAllocator, .{});
}

// ---------------------------------------------------------------------------
// 💤（design.md §4.5.2）：管理员发一条只有 💤 的消息，并由同一个管理员亲自
// 点一个 💤 表情回应 → 这个群这一轮不收录。文本或回应缺一不可。

test "💤：单独文本没有本人表情回应 → 完全无效，不会误触" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{textMsg(1, ADMIN, "💤")};
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, params());
    defer out.deinit(gpa);
    try std.testing.expect(!out.skip_collection);
}

test "💤：管理员单独文本 + 本人 💤 表情回应 → skip_collection 为真，候选照常算出来" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "金句"),
        textMsg(2, ADMIN, "💤"),
    };
    var p = params();
    p.sleep_reaction_ids = &.{2};
    var out = try classify(gpa, &msgs, &msgs, &.{1}, &.{}, p);
    defer out.deinit(gpa);

    try std.testing.expect(out.skip_collection);
    // 候选列表**不**被清空：runner.zig 要靠它的长度如实报 skipped。
    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
    try std.testing.expectEqual(@as(i64, 1), out.candidates[0].message_id);
}

test "💤：前后带空白仍然算数" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{textMsg(1, ADMIN, "  💤 \n")};
    var p = params();
    p.sleep_reaction_ids = &.{1};
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, p);
    defer out.deinit(gpa);
    try std.testing.expect(out.skip_collection);
}

test "💤：非管理员发的不算" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{textMsg(1, OUTSIDER, "💤")};
    var p = params();
    p.sleep_reaction_ids = &.{1};
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, p);
    defer out.deinit(gpa);
    try std.testing.expect(!out.skip_collection);
}

test "💤：夹带别的字一律不算——开关不能被闲聊误触" {
    const gpa = std.testing.allocator;
    inline for ([_][]const u8{ "💤💤", "睡了💤", "💤 明天见" }) |txt| {
        const msgs = [_]onebot.Message{textMsg(1, ADMIN, txt)};
        var p = params();
        p.sleep_reaction_ids = &.{1};
        var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, p);
        defer out.deinit(gpa);
        try std.testing.expect(!out.skip_collection);
    }
}

test "💤：夹带图片段（不是唯一的 text 段）不算" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{.{
        .message_id = 1,
        .user_id = ADMIN,
        .time = 0,
        .segments = &.{ .{ .text = "💤" }, .other },
    }};
    var p = params();
    p.sleep_reaction_ids = &.{1};
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, p);
    defer out.deinit(gpa);
    try std.testing.expect(!out.skip_collection);
}

test "💤：带 reply 段的 💤 不算——💤 是群级指令，带引用的语法归 ✨/💦" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "金句"),
        replyMsg(2, ADMIN, 1, "💤"),
    };
    var p = params();
    p.sleep_reaction_ids = &.{2};
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, p);
    defer out.deinit(gpa);
    try std.testing.expect(!out.skip_collection);
}

test "💤 不影响撤稿：同一窗口里的 💦 照常进 revoked" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "金句"),
        replyMsg(2, ADMIN, 1, "💦"),
        textMsg(3, ADMIN, "💤"),
    };
    var p = params();
    p.sleep_reaction_ids = &.{3};
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, p);
    defer out.deinit(gpa);

    try std.testing.expect(out.skip_collection);
    try std.testing.expectEqual(@as(usize, 1), out.revoked.len);
    try std.testing.expectEqual(@as(i64, 1), out.revoked[0]);
}

test "💤：管理员 💦 引用这条 💤 → 取消跳过，这一轮照常收录" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "金句"),
        textMsg(2, ADMIN, "💤"),
        replyMsg(3, ADMIN, 2, "💦"),
    };
    var p = params();
    p.sleep_reaction_ids = &.{2};
    var out = try classify(gpa, &msgs, &msgs, &.{1}, &.{}, p);
    defer out.deinit(gpa);

    try std.testing.expect(!out.skip_collection);
    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
}

test "💤：撤销走的是「💦 直接引用了这个 id」而不是 revoked——管理员不被观察时同样生效" {
    const gpa = std.testing.allocator;
    // subset 的观察集合是 {OBSERVED, OUTSIDER}，ADMIN 不在里面：这条 💤 消息
    // 按 4.3 节根本不是"可作废的目标"，永远进不了 revoked。取消跳过若拿
    // revoked 判就会在这种配置下静默失效。
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "金句"),
        textMsg(2, ADMIN, "💤"),
        replyMsg(3, ADMIN, 2, "💦"),
    };
    var p = subset;
    p.sleep_reaction_ids = &.{2};
    var out = try classify(gpa, &msgs, &msgs, &.{1}, &.{}, p);
    defer out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), out.revoked.len);
    try std.testing.expect(!out.skip_collection);
    try std.testing.expectEqual(@as(usize, 1), out.candidates.len);
}

test "💤：两条 💤 只撤掉一条 → 剩下那条仍然让这一轮跳过" {
    const gpa = std.testing.allocator;
    const msgs = [_]onebot.Message{
        textMsg(1, ADMIN, "💤"),
        textMsg(2, ADMIN, "💤"),
        replyMsg(3, ADMIN, 1, "💦"),
    };
    var p = params();
    p.sleep_reaction_ids = &.{ 1, 2 };
    var out = try classify(gpa, &msgs, &msgs, &.{}, &.{}, p);
    defer out.deinit(gpa);
    try std.testing.expect(out.skip_collection);
}

fn sleepUnderFailingAllocator(gpa: std.mem.Allocator) !void {
    const msgs = [_]onebot.Message{
        textMsg(1, OBSERVED, "金句"),
        textMsg(2, ADMIN, "💤"),
        textMsg(3, ADMIN, "💤"),
        replyMsg(4, ADMIN, 3, "💦"),
        textMsg(5, ADMIN, "✨ 一条存活的手动收录"),
    };
    var p = params();
    p.sleep_reaction_ids = &.{ 2, 3 };
    var out = try classify(gpa, &msgs, &msgs, &.{1}, &.{}, p);
    out.deinit(gpa);
}

test "OOM 回归：💤/💦 两份名单（sleep_ids / drop_targets）扩容在任意分配点失败都不泄漏" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, sleepUnderFailingAllocator, .{});
}
