# Hikari 设计文档

日期：2026-08-15
语言：Zig 0.15.2

## 1. 目标

Hikari 是一个常驻进程，做两件事：

1. **每天定时扫描**指定 QQ 群的历史消息，把被观察者说过的、被群友用 ✨ 认可的话收录为语录，存进 Redis。管理员另有两项权限：用 `✨ 内容` 手动补录一条，用 💦 引用把某条语录作废。
2. **提供一个 HTTP 服务**，接口与 [Hitokoto 一言 API](https://developer.hitokoto.cn/sentence/) 兼容，每次请求从 Redis 随机返回一条语录。

上游依赖 [NapCatQQ](https://github.com/NapNeko/NapCatQQ) 的 HTTP 接口（OneBot 11 + NapCat 扩展）。

## 2. 配置（环境变量）

| Env | 必填 | 说明 | 示例 |
|---|---|---|---|
| `NAPCAT_HTTP_URL` | 是 | NapCat HTTP 接口 base URL | `http://127.0.0.1:3000` |
| `NAPCAT_TOKEN` | 是 | NapCat access token，以 `Authorization: Bearer <token>` 发送 | |
| `OBSERVED_QQ` | 是 | 被观察的 QQ 号 | `10001` |
| `QQ_GROUP_IDS` | 是 | 逗号分隔的目标群号，扫描与日志都作用于这些群 | `123456,789012` |
| `ADMIN_QQS` | 是 | 逗号分隔的管理员 QQ 号 | `20001,20002` |
| `SCAN_TIME` | 是 | 每日扫描时刻，24 小时制 `HH:MM`，本地时区 | `03:00` |
| `HTTP_HOST` | 是 | 一言服务监听地址 | `0.0.0.0` |
| `HTTP_PORT` | 是 | 一言服务监听端口 | `8080` |
| `REDIS_URL` | 是 | `redis://[:password@]host:port/db` | `redis://127.0.0.1:6379/0` |

任一必填项缺失或格式非法，进程启动即退出并打印具体是哪一项。

## 3. NapCat 接口用法

依据 NapCatQQ 主干源码（`packages/napcat-onebot/action/`）确认：

| 接口 | 用途 | 关键点 |
|---|---|---|
| `get_group_msg_history` | 翻页拉取群历史 | 入参 `group_id`, `message_seq`, `count`, `reverse_order`。**返回的消息不含 `emoji_likes_list`**。`message_seq` 吃的是 `message_id`（两者同一值域），`reverse_order` 是"从锚点朝哪个方向走"——`false` = 往新（更晚）走，`true` = 往旧（更早）走；不带 `message_seq` 时该字段被忽略（走 `getAioFirstViewLatestMsgs`）。`message_seq` 是闭区间：带锚点的一页会把锚点消息本身包含在内（`reverse_order: true` 时锚点是那一页里最新的一条）。2026-08-15 首次生产运行 + 针对真实 NapCat 的 `count=5` 手工探测已确认以上语义 |
| `get_msg` | 取单条消息详情 | 返回体含 `emoji_likes_list: [{emoji_id, emoji_type, likes_cnt}]`；顶层还含 `user_id`（与 `sender.user_id` 一致，`onebot.parseMessage` 依赖这个顶层字段解出发送者）。2026-08-15 针对生产 NapCat 直接探测 `get_msg` 已确认，顶层 key 为 `emoji_likes_list, font, group_id, group_name, message, message_format, message_id, message_seq, message_type, post_type, raw_message, real_id, real_seq, self_id, sender, sub_type, time, user_id` |
| `get_group_info` | 取群名 | 填充 hitokoto 的 `from` |
| `get_group_member_info` | 取被观察者群名片 | 填充 hitokoto 的 `from_who` |
| `get_login_info` | 取机器人自己的 QQ | 每次 `runOnce` 只问一次，供合并转发 node 的 `user_id` 复用；见 7 节 |
| `send_group_forward_msg` | 发送运行日志 | 每群一条合并转发消息，七行各占一个 node；见 7 节 |

### 3.1 表情回应的读取代价

`get_group_msg_history` 走的是 `parseMessage`，不会带出表情回应数据；只有 `get_msg` 会从 `msg.emojiLikesList` 手工填充 `emoji_likes_list`。因此**被观察者的每一条窗口内消息都需要额外一次 `get_msg`**。一天几百条消息就是几百次调用，这是接口限制，无法规避。

`get_emoji_likes` / `fetch_emoji_like` 不适用：它们要求调用方预先知道 `emoji_id`，返回的是"谁点了这个表情"，而我们需要的是"这条消息上有哪些表情"。

### 3.2 message_id 的性质与风险

读 `packages/napcat-common/src/message-unique.ts` 确认，OB11 的 `message_id`（短 ID）是：

```
shortId = MD5(msgId | chatType | peerUid) 的前 31 bit
```

两个推论直接影响本设计：

**好消息：短 ID 是确定性哈希，不是自增计数器**，NapCat 重启后同一条 QQ 消息仍然得到同一个短 ID。因此它可以安全地作为 Redis 主键，重启不会导致 tombstone 错杀或去重失效。

**坏消息一：31 bit 空间存在生日碰撞。** 存到 1 万条语录时，碰撞概率约 2%。碰撞的后果是一条新语录被误判为"已存在"而 skip。发生概率低且后果温和（少收一条语录，不会污染已有数据），本设计接受这个风险，不额外引入内容哈希。

**坏消息二：短 ID → 真实 msgId 的反查表是一个容量 5000 的内存 LRU。** 也就是说 `get_msg` 只能查到最近 5000 条被 NapCat 见过的消息。影响在于：

- 路径 1 与窗口内消息不受影响——`get_group_msg_history` 返回时会为每条消息注册映射，紧接着 `get_msg` 必定命中。
- Pass A / 路径 2 中，`reply` 指向的消息若在窗口之外且已被 LRU 淘汰，`get_msg` 会返回"消息不存在"。

处理方式：这类失败**不视为致命错误**，记入 skip 并打印一条警告日志（含 `reply.data.id`），扫描继续。同时，翻页拉取历史时在窗口起点之外**额外多拉一页**作为缓冲，让"引用昨天早些时候的消息"这一最常见情形能在窗口内直接解析，不必走 `get_msg`。

路径 2 反查依赖 `get_msg` 返回体顶层带 `user_id`（`onebot.parseMessage` 找不到顶层 `user_id` 时直接返回 null，效果等同于上面这条"消息不存在"的处理路径）。2026-08-15 针对生产 NapCat 直接探测 `get_msg` 已确认顶层 `user_id` 存在且与 `sender.user_id` 一致，这条假设成立：窗口外、走 LRU 反查这条路（只要没被 5000 条 LRU 淘汰）能正常解出发送者。

### 3.3 ✨ 与 🔥 的标识

QQ 表情回应有两类：`emoji_type=1` 是 QQ 系统表情（id 为两三位数字），`emoji_type=2` 是 Unicode emoji（id 为码点十进制）。

✨ = U+2728 = 十进制 **10024**，`emoji_type=2`。

🔥 = U+1F525 = 十进制 **128293**，`emoji_type=2`，同一套编码方案。2026-08-15 针对生产 NapCat 探测确认（见 4.5 节路径4 的验证记录）。

两个常量都定义在一处（`src/napcat.zig`，`star_emoji_id` / `fire_emoji_id`），且各自的数值形式（`*_num`）都由字符串形式在 comptime 推导，字符串与数值不可能漂移——这个模式此前真的漂移过一次。扫描时会把所有**未匹配**（既非 ✨ 也非 🔥）的 `emoji_id` 打进日志，便于首次实跑时核对真实值。`hasStarReaction` 与 `hasFireReaction` 读的是同一次 `get_msg` 响应体（3.1 节所述那次调用），不为 🔥 额外发起请求。

## 4. 扫描逻辑

每天 `SCAN_TIME` 触发一次，逐群执行。

### 4.1 时间窗口

窗口起点逐群独立，按这个群自己的 `hikari:lastrun:{group_id}`（`scheduler.windowStart`）算，
不是固定回看 24 小时：

- 这个群从未跑过（键不存在）→ 退化成 `[run_at - 24h, run_at)`，跟首次上线时行为一致。
- 这个群这一时刻已经跟上了（`last_run >= run_at`，比如补跑用最早的漏跑时刻重扫了全部群，
  其中有的群本来就没漏）→ 空窗口 `[run_at, run_at)`，什么都不扫。
- 否则 → `[last_run, run_at)`：把上次成功之后错过的整段都补上，不管它有多长。

这段回补有一个上限：跨度超过 `scheduler.max_lookback_seconds`（7 天）时窗口起点截断到
`run_at - 7d`，并打一条 warn 点名是哪个群、丢了哪一段——截断掉的那部分不会再被任何一次
扫描覆盖到，其中的 💦 撤稿指令因此永久不可恢复（💦 只会被看到一次）。7 天 ≈ 35 页
（`page_size = 200`），远在翻页的 200 次迭代护栏之内。

以 `last_run` 而不是固定 24h 为起点，顺带解决了两个问题：一是"已经跟上的群"不再需要
白白重扫一遍已处理过的窗口（第 5 节曾经描述过的那种无害但浪费的行为，现在窗口直接是空的）；
二是本地时区遇到夏令时"回拨"、当天实际长达 25 小时的那种日子，相邻两次触发本来就间隔
25 小时，现在窗口也会是 25 小时而不是被固定 24h 截掉最早的 1 小时。

消息以 OB11 的 `time` 字段（Unix 秒）判定归属。

### 4.2 拉取

1. 首次调用 `get_group_msg_history`（不带 `message_seq`，`reverse_order: false`——该字段被忽略）取最新一批，`count = 200`。
2. 取批内最老一条的 `message_id` 作为下一次的 `message_seq`，**并把 `reverse_order` 设为 `true`**（往更早的方向走）继续往前翻；`reverse_order: false` 会让 NapCat 原样返回同一页，永远翻不动（首次生产运行踩到过这个坑，见 3 节表格与 README 的线上假设记录）。
3. `message_seq` 是闭区间，锚点消息本身会重复出现在下一页里（作为那一页最新的一条），所以每一页（除第一页外）都会把上一页最老的一条重复拉一遍；`Will process N messages.` 据此会比实际值多报最多「页数 − 1」条，不影响落库（按 `message_id` 去重）。
4. 终止条件：本批最老消息的 `time` 早于窗口起点**且已额外多拉一页**（3.2 节的解析缓冲），或返回空列表，或 `message_seq` 不再前进（防死循环——含合法情形：本页只剩锚点自己一条，说明已经翻到群历史的最开头）。
5. 结果按 `time` 升序排列。落在窗口内的部分是**判定集**；窗口之外的缓冲页只用于解析 `reply` 目标，自身不参与 Pass A / Pass B 的判定。

### 4.3 Pass A —— 收集作废指令

对窗口内每条消息 `m`，同时满足以下全部条件时，把它引用的消息 `R` 记入作废集：

- `m.user_id ∈ ADMIN_QQS`
- `m` 含 `reply` 段，其 `data.id` 为 `R`
- `m` 除 `reply` 外含 `text` 段，文本 trim 后等于 `💦`
- `R` 是一条**可作废的目标**，即满足以下任一：
  - `R` 的发送者是 `OBSERVED_QQ`（对应路径 1、路径 2 收录的语录）
  - `R` 的发送者 ∈ `ADMIN_QQS` 且 `R` 符合 4.5 节路径 3 的手动收录格式（对应路径 3 收录的语录）

第二个分支是必要的：路径 3 收录的语录，其主键是**管理员那条指令消息**的 `message_id`，发送者不是被观察者。若不放宽，手动收录的条目将永远无法作废。判定只依赖 `R` 自身的内容与发送者，`rules.zig` 仍然是纯函数。

`R` 优先在窗口内（含 3.2 节所述的缓冲页）查找；找不到则用 `get_msg` 拉取。`get_msg` 也失败时按 3.2 节处理：记 skip、打警告、继续扫描。

**`R` 是路径4（🔥 链，见 4.5 节）成员时的展开**：`R` 的发送者恒为 `OBSERVED_QQ`，所以第一个分支必定成立，`R` 本身总是可作废的目标。但若 `R` 落在某条已并链（≥2 个成员）的链上，作废集里记入的不是 `R` 自己，而是**这条链的全部成员**——不管 💦 引用的是链的第一个成员（主键）还是后面任意一个。这是必须的：这条链存的语录只有一份、主键是第一个成员的 `message_id`；💦 引用非第一个成员时，若只把那个成员记入作废集，4.4 节的删库操作会去删一个从未被索引过的 id，真正被索引的那份语录反而不会被删除。判定"`R` 属不属于某条链"依赖窗口内的 ✨/🔥 表情回应数据（4.5 节路径4 同一份输入），因此链的划分必须先于 Pass A 算好——`rules.classify` 在函数最前面先把窗口内的全部链一次性建好，Pass A 与 Pass B 共用这份结果，判定仍然是纯函数、不发起任何调用。

**这条展开只覆盖 `R` 落在当次窗口能重建出的链上的情形，是一条"窗口内快路径"，不是撤稿正确性的唯一保障。** `R` 完全可能来自 3.2 节所述的缓冲池、或者 `get_msg` 回补——也就是落在**窗口外**：一条链语录一旦入库，往后任何一次扫描既可能重新看到它、也可能完全翻不到它；💦 引用的是几天前已经入库的一条链语录时，这是**常态**而不是边界情形——一条链语录只有在收录它的那次扫描**之后**才会出现在 `GET /` 里，管理员看到它、回去 💦 它，天然就是在一个后续的、无法重建出这条链的窗口里操作。`chainOf(chains, rid)` 在这种情况下必然返回 `null`，`rules.classify` 只能把裸的 `rid` 记入作废集，展开不出"这条链的全部成员"。若这就是撤稿正确性的全部依据，非第一个成员时 4.4 节的删库操作会去删一个从未被索引过的 id，真正被索引的那份语录不会被删除——这正是本设计要在 Store 层堵住的缺口，见 4.4 节与第 5 节 `hikari:chainmember:{message_id}` / `hikari:chain:{message_id}` 的说明：链的成员→主键映射在**收录当时**就持久化进 Redis，`Store.revoke` 据此在任何一次未来的扫描里、不依赖窗口重建就能查到"这个 id 属于哪条链"，把这条展开从"只在窗口内可靠"变成"任何时候都可靠"。两条路径都保留：`rules.zig` 这里的窗口内展开仍然照常运行（它不需要额外的 Redis 往返，`outcome.revoked` 已经带全了链的全部成员），`Store.revoke` 的持久化映射再兜底一遍——`runner.zig` 对 `outcome.revoked` 里的每个 id 各自单独调用一次 `Store.revoke`，两条路径都命中同一条链时，第二次以及之后的调用落在已经清理过的成员上，退化成一串幂等的空操作（tombstone 已经在、索引本来就没有、hash 本来就没有），不会出错，也不会重复计费出任何看得见的副作用。

### 4.4 作废落盘

Pass A 结束后立即执行，先于 Pass B。`runner.zig` 对 `outcome.revoked` 里的每一个 `message_id` 各自调用一次 `Store.revoke(id)`，落到 Redis 的实际命令序列见第 5 节；概念上每次调用做的事是：

- 从 Redis 删除对应的语录记录（若已入库）
- 把这个 id（以及，若它是链成员，链上其余全部成员）写入 `hikari:tomb`

tombstone 是永久的：以后任何一次扫描再次看到这条消息，无论有没有 ✨，都不会入库。这满足"跨扫描窗口的 💦 也能作废前几天已入库的语录"——但这句话对**链语录**成立，靠的不是 tombstone 本身（tombstone 只解释了"这个 id 以后不会再入库"，不解释"💦 引用非主键成员时，怎么找到那份真正存在 `hikari:quote:{主键}` 里的语录并删掉它"），而是第 5 节 `hikari:chainmember:{message_id}` 这份收录时就写好的持久映射：`Store.revoke` 拿它在任何窗口之外都能查到"这个 id 属于哪条链、主键是谁"，见 4.3 节新增的那段说明。

**路径4（🔥 链）的作废对象是整条链的每一个成员**，不只是链的主键。第一个成员（主键）那一步会真正命中 `hikari:quote:{主键}` 并删掉；其余成员从未被单独索引进 `hikari:index`/`hikari:bylen`，对它们的删索引/删 hash 是无害的空操作，但 `hikari:tomb` 里确实多了它们的 `message_id`，`hikari:chainmember:{它们自己}` 与 `hikari:chain:{主键}` 也会被一并清理（第 5 节）。这一步不能省：往后某次扫描如果这条链的 🔥 被撤掉、链散架成单条消息，幸存成员会退回路径1的单独候选资格——若它没有被单独 tombstone 过，已经被撤掉的内容就会绕过撤稿重新入库。撤稿是这个系统里唯一不允许静默失效的方向，所以宁可在 `hikari:tomb` 里多存几个从未真正用得上的 id，也不能少存。

`rules.zig` 的窗口内展开（4.3 节）与 `Store.revoke` 的持久映射解析是**两条独立、都保留的路径**，不是互相替代的关系：前者在当次窗口能重建出链时不需要额外的 Redis 往返就把 `outcome.revoked` 填满，是常见情形下的快路径；后者是撤稿正确性的最终保障，覆盖前者天然覆盖不到的跨窗口情形（4.3 节新增段落）。两者同时命中同一条链时（`outcome.revoked` 已经带着全部成员，`runner.zig` 逐个调用 `Store.revoke`），第一次调用完成整条链的清理，后续几次调用会各自落在已经不属于任何链（映射已清理）的 id 上，退化成一串幂等的单条撤稿操作（tombstone 已经在、索引本来就没有、hash 本来就没有），不产生错误，也不产生额外可见的副作用——只是多花几次无害的 Redis 往返。

### 4.5 Pass B —— 收集候选

四条独立路径，命中任意一条即成为候选：

**路径 1（直接表情回应）**

- `m.user_id == OBSERVED_QQ`
- `get_msg(m.message_id)` 的 `emoji_likes_list` 中存在 `emoji_id == "10024"`
- → 候选是 `m` 自身

**路径 2（引用 ✨）**

- `m.user_id != OBSERVED_QQ`
- `m` 含 `reply` 段，其 `data.id` 为 `R`
- `m` 除 `reply` 段外**只有一个** `text` 段，文本 trim 后等于 `✨`
- `R` 的发送者是 `OBSERVED_QQ`
- → 候选是 `R`（不是 `m`）

**路径 3（管理员手动收录）**

- `m.user_id ∈ ADMIN_QQS`
- `m` **不含** `reply` 段（含 `reply` 段的一律走路径 2 判定，避免两套语法打架）
- `m` 的渲染文本（按 4.6 节规则处理后）trim 后以 `✨` 开头
- 去掉开头的 `✨` 及紧随其后的空白（可有可无）后，剩余部分非空
- → 候选是 `m` 自身，**正文为剩余部分**（不含 `✨` 前缀）

路径 3 是唯一一条（在路径4之前）正文不等于目标消息全文的路径。因此 `rules.zig` 输出的候选结构体带一个 `text_override` 字段：路径 3、4 填拼接/去掉前缀后的正文，路径 1、2 留空表示"按 4.6 节从目标消息提取"。

**路径 4（🔥 链式收录）**

被观察者把一句话拆成好几条发，群里除了 ✨ 还额外贴 🔥 标记"这些应该拼成一条"。2026-08-15 生产验证（真实 msg_id 2015349404「你们有钱」+ 283613043「你们潇洒」，均带 `emoji_id ∈ {10024, 128293}`）确认应合并为一条「你们有钱 你们潇洒」，并据此确认 🔥 = U+1F525 = 十进制 128293（见 3.3 节）。

- **成员资格**：`m.user_id == OBSERVED_QQ` 且同时带 ✨（10024）与 🔥（128293）两种表情回应。只有 🔥 没有 ✨ 不算数。
- **相邻判定**：两条合格消息之间，窗口内**任意**消息（不论发送者、不论有没有表情回应）最多隔 3 条，就算相邻可并。计数按窗口内**按 `message_id` 去重后**的序列算下标差（去重后下标差 ≤ 4 ⇔ 中间最多夹 3 条），不能按 window 数组的原始下标算——3.2 节 `message_seq` 闭区间分页会让锚点消息在相邻两页里各出现一次，同一条消息可能在 window 里重复；若按原始下标计算，一次页边界重叠就会让间距虚高，两条本该相连的消息在页边界附近静默连不上，且这种情况几乎不可复现（只有页边界恰好落在两条消息之间才会触发）。
- **链不设上限**：A、B、C 只要相邻两两都在间距内，即便有更多消息也会依次并成一条，不是只并前两条。
- **正文**：按成员的时间升序，把每个成员各自的渲染文本（4.6 节规则，逐条 trim 后）用**一个空格**连接。
- **主键与时间**：整条链存一份语录，主键是**第一个成员**的 `message_id`；`created_at` 取第一个成员的 `time`。
- **候选归属**：一条链一旦成立（≥2 个成员），它的全部成员都从路径1候选资格里排除——不这样做的话，「你们有钱」「你们潇洒」「你们有钱 你们潇洒」会同时入库，链变得没有意义。落单（没有相邻伙伴）的合格消息不受影响，仍按路径1单独收录。
- **撤稿**：见 4.3／4.4 节——💦 引用链上任意一个成员都作废整条链，链的全部成员都会被 tombstone，不只是主键。

### 4.5.1 路径冲突与优先级

**完整优先级：路径 4 > 路径 3 > 路径 1。** 路径 2 与路径 3 互斥，不参与这个顺序；同一条消息被多条路径命中时按 `message_id` 去重，只入库一次。

- **链成员（不论是不是主键）的个体收录资格对全部路径一律让路给路径4。** 一条链一旦成立（≥2 个成员），它的每一个成员——包括第一个成员（主键）——都不再单独产生路径1、路径2、路径3的候选，不管它自己是否也满足这些路径各自的格式。这不是"路径3优先于路径1"那种同一条消息内部的格式优先级问题，而是"这条消息该不该被单独收录"这个更前置的问题：链是比路径1/2/3都更具体的信号——群里明确把这几条消息标成一句话，而这件事没有别的路径能表达；路径1/2/3各自只是"这条消息本身也值得收录"的独立信号。两者同时生效，语录库里会同时存在被拆开的碎句和拼好的整句（例如"你们潇洒"与"你们有钱 你们潇洒"同时入库），`GET /` 随机吐出来的观感比二选一更差，所以链赢。
  - 具体到路径2：有人对链上某个成员单独回复 `✨`，视为在重复"这句话说得好"，链已经替它收录了，不再额外产生路径2候选。
  - 具体到路径3：链的成员自己碰巧也满足路径3的手动收录格式（这要求被观察者本人也在 `ADMIN_QQS` 里），不再额外产生路径3候选。**这一条特意翻转了"路径3优先于路径1"的既有逻辑**：路径3优先于路径1，是因为它是更具体的**作者本人手动指定**信号；路径4优先于路径3（以及路径1），是因为它是更具体的**分组**信号，而分组这件事同样没有别的路径能替代表达——两条"优先于"背后是不同维度的"更具体"，不矛盾，只是路径4的维度盖过路径3的维度。
- **拼接进 joined 正文时会剥掉成员自己的 `✨` 前缀。** 若某个成员的渲染文本本身满足路径3格式（`✨ 内容`），链在拼接这个成员时取的是路径3判定剥掉前缀后的正文，不是带着 `✨` 的原始渲染文本——`✨` 在这个系统里到处都是控制符，不是语录正文的一部分；不剥的话，joined 正文会带着控制符残留（"你们有钱 ✨ 你们潇洒"）。不满足路径3格式的成员（多数情况）原样按 4.6 节渲染，不受影响。

副作用提示：被观察者若被列入 `ADMIN_QQS`，他自己发的、不是任何链成员的 `✨ ...` 仍然会被路径3自动收录。这是规则的自然推论，不作特殊处理。

### 4.6 过滤与入库

候选依次通过下列关卡，任一关卡拦下则计入 skip：

1. 在 `hikari:tomb` 中 → 拒绝
2. 已存在于 `hikari:index` → 拒绝（幂等，重复运行不会产生重复语录）
3. 文本提取后为空 → 拒绝

**文本提取规则**：

- `text` 段：原样取 `data.text`
- `at` 段：渲染为 `@` + `data.name`；`data.name` 缺失时退化为 `@` + `data.qq`
- 其余所有段类型（image / face / mface / record / video / file / json / forward 等）：直接丢弃，不产生占位符

按段顺序拼接，首尾 trim。结果为空字符串则跳过。

路径 3、路径 4 的候选带 `text_override`，正文直接取该字段（路径3是渲染并剥掉 `✨` 前缀后的结果；路径4是链上各成员依次取——若某个成员自己也满足路径3格式，取它剥掉 `✨` 前缀后的正文，否则取它的原始渲染文本——再用单个空格拼接后的结果，见 4.5.1 节），不再重复提取。

### 4.7 字段映射

| Hitokoto 字段 | 来源 |
|---|---|
| `id` | `INCR hikari:seq` |
| `uuid` | 本地生成的 UUIDv4 |
| `hitokoto` | 4.6 提取出的文本（路径 3 为剥掉 `✨` 前缀后的正文，路径 4 为链上各成员拼接后的正文） |
| `type` | 固定 `"g"`（其他） |
| `from` | 群名，来自 `get_group_info` |
| `from_who` | 被观察者群名片，来自 `get_group_member_info` |
| `creator` | 固定 `"Hikari"` |
| `creator_uid` | 固定 `0` |
| `reviewer` | 固定 `0` |
| `commit_from` | 固定 `"hikari"` |
| `created_at` | 候选消息的 `time`，字符串形式的 Unix 秒。路径 3 取管理员那条指令消息的时间；路径 4 取链的**第一个成员**的时间 |
| `length` | `hitokoto` 的 **UTF-8 码点数**（不是字节数） |

路径 4 的候选 `message_id`（即存入 `hikari:quote:{message_id}` 的主键）是链的第一个成员的 `message_id`，运行器（`scan/runner.zig`）按这个 id 去 `pool` 里找到那条真实消息取其 `time` / `user_id`，字段映射不需要为路径4单独改运行器的取值逻辑——链的第一个成员本身就是一条真实的、被观察者发送的消息。

`from` / `from_who` 每次扫描每个群各拉取一次后缓存，不逐条调用。

## 5. Redis 结构

| 键 | 类型 | 内容 |
|---|---|---|
| `hikari:quote:{message_id}` | HASH | 第 4.7 节全部字段，外加 `message_id` / `group_id` / `user_id` |
| `hikari:index` | SET | 全部已入库的 `message_id`（🔥 链只有第一个成员的 `message_id` 在这里） |
| `hikari:bylen` | ZSET | score = `length`（码点数），member = `message_id`（同上，只有链主键） |
| `hikari:tomb` | SET | 被作废的 `message_id`（🔥 链的全部成员都在这里，不只是主键） |
| `hikari:seq` | STRING | 自增计数器，供 `INCR` |
| `hikari:lastrun:{group_id}` | STRING | 这个群上次扫描窗口终点的 Unix 秒，逐群独立 |
| `hikari:chainmember:{message_id}` | STRING | 仅 🔥 链使用：value 是这条链**主键**（第一个成员）的 `message_id`。链的每一个成员——包括主键自己——都写一份，value 都是同一个主键 |
| `hikari:chain:{message_id}` | SET | 仅 🔥 链使用，key 里的 `{message_id}` 是链**主键**：成员是这条链的全部 `message_id`（含主键自己） |

**写入（普通语录，路径1/2/3）**（按此顺序逐条发送）：`HSET hikari:quote:{id} ...` → `ZADD hikari:bylen {length} {id}` → `SADD hikari:index {id}`

顺序即事务语义。`exists()` 查的是 `hikari:index`，所以 `SADD` 是提交点、必须最后发：任何一次部分失败留下的状态都满足 `exists() == false`，下一次扫描原样重做一遍就修好了（三条命令都幂等）。反过来若 `SADD` 先于 `ZADD`，"`HSET`+`SADD` 成功、`ZADD` 失败" 会让这条语录 `exists() == true` 却永远不在 `hikari:bylen` 里——`GET /` 能随机到，任何带 `min_length`/`max_length` 的查询都永远看不见，且不会自愈。

**写入（🔥 链语录，路径4，`Store.addChain`）**（按此顺序逐条发送）：对链的每个成员 `m`（含主键）依次发 `SET hikari:chainmember:{m} {主键}` → `SADD hikari:chain:{主键} {member1} {member2} ...`（一条命令带全部成员）→ 接下来跟普通语录写入完全一样的三步：`HSET hikari:quote:{主键} ...` → `ZADD hikari:bylen {length} {主键}` → `SADD hikari:index {主键}`。

映射（`chainmember`/`chain`）先于 `hikari:index` 的提交点落盘，方向刻意跟"`SADD` 必须最后发"这条原则保持一致但理由不同：若映射写在提交点**之后**，"`hikari:index` 提交成功、映射写失败"会让 `exists(主键) == true`（今后重扫时被跳过、永不重试），但非主键成员逃过了下面 `isChainMember` 那道关卡——往后一次窗口若把它单独判定成候选，会被当成一条全新的独立语录再收一遍，制造碎句与整句同时入库的重复。映射写在提交点之前，任何一步失败都仍然满足 `exists(主键) == false`，下一次扫描原样重做（`SET`/`SADD`/`HSET`/`ZADD` 全部幂等）。

**入库前的第三道关卡**：候选按 4.6 节过了 `hikari:tomb`（tombstone）、`hikari:index`（`exists`）两道关之后，还要再查一次 `EXISTS hikari:chainmember:{message_id}`（`Store.isChainMember`）——一条 🔥 链的非主键成员永远不会出现在 `hikari:index` 里，单靠 `exists()` 拦不住它们被后续某次扫描（比如因为其它候选写入失败导致这个群这一轮判失败、`lastrun` 没有前移，下一次触发时窗口原样重扫，而中间群里的 🔥 被增减，链的组成算出来跟第一次不一样）当成独立消息、或者另一条不同的链重新收录。这份映射一旦写下就是这条消息最终的归属：它不会因为后续扫描把它算进另一种链的组合而改变，除非这条链先被 💦 撤稿（下面段落）。

**删除（普通语录）**（同样按此顺序）：`SADD hikari:tomb {id}` → `SREM hikari:index {id}` → `ZREM hikari:bylen {id}` → `DEL hikari:quote:{id}`

tombstone 先落盘：它是这次作废唯一持久的事实，删索引与删 hash 都只是它的后果。这样最坏留下一个孤儿 hash（没人索引得到，只占空间），而不是 `hikari:index` 里一个没有 hash 的悬空 id——后者会被 `SRANDMEMBER` 抽中、`HGETALL` 回空，让一个非空的库对外返回 404，且永远不会自愈。

**删除（`Store.revoke` 的完整逻辑，覆盖普通语录与 🔥 链）**：先 `GET hikari:chainmember:{id}`。

- 查不到（nil，最常见：路径1/2/3 的语录，或压根没被这份映射记录过的任意 id）→ 走上面"删除（普通语录）"那四步，原样不变。
- 查到（value 是链主键 `p`）→ 说明 `id` 是某条 🔥 链的成员（不论是不是主键自己）：`SMEMBERS hikari:chain:{p}` 拿到全部成员 → `SADD hikari:tomb {member1} {member2} ...`（一条命令，全部成员一起 tombstone，tombstone 仍然先落盘）→ `SREM hikari:index {member1} ...` / `ZREM hikari:bylen {member1} ...`（对非主键成员是无害空操作）→ `DEL hikari:quote:{p}`（只有主键有 hash）→ 最后 `DEL hikari:chainmember:{member1} hikari:chainmember:{member2} ... hikari:chain:{p}`，把这条链的映射连同 chain 成员集本身一并清理——不清理的话，一条已经撤稿的链会在 Redis 里永久留下一份不再对应任何真实语录的映射。

`rules.zig` 的窗口内展开（4.3 节）与这里靠 `hikari:chainmember` 解析的路径是两条独立、都保留的路径：前者是当次窗口能重建出链时的快路径（`outcome.revoked` 已经带全了链的全部成员，不需要额外 Redis 往返）；后者是撤稿正确性的最终保障，覆盖前者天然覆盖不到的跨窗口情形。`runner.zig` 对 `outcome.revoked` 里的每个 id 各自单独调用一次 `Store.revoke`，两条路径同时命中同一条链时，第一次调用完成整条链的清理，之后几次调用落在已经不属于任何链（映射已清理）的 id 上，退化成一串幂等的空操作，不产生错误。

**随机取一条**：

- 无长度过滤 → `SRANDMEMBER hikari:index` 后 `HGETALL`
- 有 `min_length` / `max_length` → `ZRANGEBYSCORE hikari:bylen {min} {max}` 拿到候选 id 列表，本地随机选一个后 `HGETALL`

`hikari:lastrun:{group_id}` 有两个用途，都是逐群独立的：进程重启后判断是否漏跑（对每个群
分别检查，如果当前时间已越过今天的 `SCAN_TIME` 而这个群自己的 `lastrun` 早于它，就判定这个
群漏跑；只要有任意一个群漏跑，立即用其中最早的漏跑时刻补跑一次，之后回归正常日程），以及
4.1 节所述的扫描窗口起点。这两者结合起来，"已经跟上的群"在补跑时拿到的是空窗口而不是重扫，
不需要、也不做逐群跳过。一个群失败不会因为同一轮里另一个群成功而被掩盖——两个群各自的键
互不影响；失败的群甚至不需要重启就能自愈：它这一轮没写 `lastrun`，下一次正常触发时窗口
起点仍然是上一次成功的位置，会自动把漏掉的这段（含其中的 💦 撤稿）重新覆盖到，直到 7 天
回看上限。

## 6. HTTP 服务

`GET /`，返回随机一条语录。参数遵循 Hitokoto 规范：

| 参数 | 支持情况 |
|---|---|
| `encode` | `json`（默认）/ `text` / `js` |
| `min_length` | 支持，走 `hikari:bylen` |
| `max_length` | 支持，走 `hikari:bylen` |
| `callback` | 支持，存在时输出 JSONP：`{callback}({json})`，Content-Type 为 `application/javascript` |
| `select` | 支持，`encode=js` 时的 DOM 选择器，默认 `.hitokoto` |
| `c` | 接受但忽略——全库只有一个类型，`type` 恒为 `g` |
| `charset` | **仅支持 `utf-8`**。传其他值返回 400 |

`charset=gbk` 不实现：GBK 转码需要内嵌一张完整码表，为一个自用接口引入这个体积不划算。这是一个明确的、有意的规范偏离。

**响应形态**

- `encode=json`：`Content-Type: application/json; charset=utf-8`，返回第 4.7 节的完整字段对象
- `encode=text`：`Content-Type: text/plain; charset=utf-8`，只返回 `hitokoto` 正文
- `encode=js`：`Content-Type: application/javascript; charset=utf-8`，返回一段把正文写入 `select` 选中元素的自执行脚本

**错误**

- 库空 / 长度过滤后无结果 → 404，JSON 错误体
- `charset` 非 `utf-8`、`min_length` > `max_length`、参数非数字 → 400，JSON 错误体
- 路径非 `/`、`/extra/all`、`/extra/batch/:count` 之一 → 404

### 6.1 `/extra/all` 与 `/extra/batch/:count`：两个自定义扩展端点

Hitokoto 协议本身没有"一次要多条语录"的形态。这两个端点落在 `/extra/` 前缀下就是在承认这一点——
它们是本项目对协议的扩展，不是协议本身的一部分，因此**不认** `/` 的那套查询参数：`encode` /
`min_length` / `max_length` / `callback` / `select` 全部被忽略，query string 整体不解析。响应固定
`Content-Type: application/json; charset=utf-8`，body 是一个 JSON 数组，元素跟 `GET /?encode=json`
产出的对象逐字段同构（第 4.7 节的完整字段集）。方法非 `GET` → 405，Redis I/O 失败 → 500 + JSON
错误体，均与 `GET /` 一致。

**`GET /extra/all`**：返回全部语录，`SMEMBERS hikari:index` 拿到全部 id 后逐个 `HGETALL`，**不设
上限**——这条端点的响应规模由语录库大小决定，不是由请求本身决定，不是需要防的那类暴露面。库空时
返回 `[]` + **200**，不是 404：数组端点返回空数组本身就是一个成功的答案（"这就是全部，全部是零
条"），跟 `GET /` 那种"没有可服务的单条语录"是不同的语义——`GET /` 的 404 表达的是"没有东西可以
给你"，`/extra/all` 的 `[]` 表达的是"我把全部都给你了，全部是零条"，两者不能共用一个状态码。

**`GET /extra/batch/:count`**：随机返回 `count` 条语录，**允许重复**——这是运营方明确选择的语义。
实现上依赖 `SRANDMEMBER hikari:index -count`（**负数**形式）：Redis 的 `SRANDMEMBER key <n>` 在
`n` 为正数时只返回互不相同的成员，`n` 为负数时允许重复且恰好返回 `|n|` 个结果。正数形式对这条端点
是错的：一是它会静默去重，"允许重复"这个承诺不成立；二是 `count` 超过库大小时它会静默把结果截断到
库大小，调用方拿到的条数会少于请求的 `count` 却拿不到任何提示。`count` 必须是 1–1000 之间的整数，
否则 400——上限卡在 1000 不是保守起见：`count` 直接来自 URL，是任何人都能触碰到的输入，不设上限的
话 `/extra/batch/999999999` 是一次谁都能发起的分配 / Redis 命令规模耗尽攻击，这条护栏是这条端点
独有的暴露面。`/extra/all` 没有对应的上限，因为它的响应规模由库大小决定，不受用户输入控制，攻击面
不存在。库空时同样返回 `[]` + 200，理由同上。

路由上，`/extra/batch/:count` 是"前缀 + 单一路径段"的匹配：`/extra/batch/` 后面必须恰好一段、不能
再带 `/`。`/extra/batch`（缺 count，没有尾随斜杠）、`/extra/batch/1/2`（count 之后还有多余路径段）
落进跟 `/nope` 相同的通用 404——这两种情况在路径结构上就不是这条路由能表达的形状，是"这个资源压根
不存在"，不是"资源存在但参数有误"。`/extra/batch/`（尾随斜杠、count 段为空）仍然命中这条路由，只是
校验 `count` 时把空串当非法数字处理，产出 400——空字符串结构上确实是"这条路由 + 一个空的 count 段"，
跟 `/extra/batch/abc` 走的是同一条错误路径，不是路由层面的缺失。

## 7. 运行日志

每次定时运行，`QQ_GROUP_IDS` 中的每一个群各收到**一条**合并转发（合并转发／聊天记录）消息，
用 `send_group_forward_msg` 发送。前六行文案与原先逐条发送时逐字相同，只是不再各自单独一条
`send_group_msg`，而是各占一个 `node`，合并转发的消息顺序即节点顺序（第七行后来加了耗时，
见下文）：

```
Hikari!
Made with ❤️ by CuzTeam, AmethystDevs-Lab
Thanks to collaborators: 恩恩hhh, apanzinc, Lonely, 小晴同学, Sylphy
Processing...
Will process 1234 messages.
Added 12 messages, skipped 34 messages.
Successfully in 87s.
```

`N` 是窗口内消息总数，`X` 是本次新入库条数，`Y` 是被各关卡拦下的候选数，`Successfully in
{d}s.` 里的秒数是这个群从 `scanGroup` 开始处理、到这一行成文为止的耗时，向下取整到整秒
（负值/时钟跳变时钳制到 0）——只测这个群自己这一轮的处理时长，不是整个运行的总时长，也不
包含 `resolveWindowStart` 那次 Redis 读。

运行中抛出异常时，最后一行替换为 `Failed: <原因>`。

### 7.1 为什么不再逐条发送

七条独立消息每天刷一遍群是骚扰；改成一条合并转发后，群里只看到一条折叠起来的聊天记录，
点开才展开七行。代价是显式接受的：原来的"渐进反馈"（扫描还没跑完就先看到横幅、
`Processing...`）没有了——现在这个群这一轮的全部输出在扫描彻底跑完（或彻底失败）之前
不会出现在群里。一次扫描历史上跑了 1–2 分钟，这段时间里群里不会有任何提示，直到合并转发
一次性发出。

### 7.2 node 结构与 `user_id`

每个 node 是：

```json
{"type":"node","data":{"user_id":"<bot_qq>","nickname":"Hikari","content":[{"type":"text","data":{"text":"<这一行文案>"}}]}}
```

`user_id` 是**机器人自己的 QQ**（不是被观察者、也不是发这条日志的哪个人），控制的是合并转发里
这一行显示的头像；`nickname` 固定 `"Hikari"`。机器人 QQ 不在配置项里，`runOnce` 每轮只调用一次
`get_login_info` 取到后逐群逐行复用，取失败（网络、响应格式不对、字段缺失）时退回
`OBSERVED_QQ` 并打警告——这个值只影响头像显示，选错是观感问题，不值得为它中断整轮扫描。

### 7.3 崩溃与"发不出去"

七行文案的产生时机跟原来一样：前四行（横幅三行 + `Processing...`）在扫描开始前就已确定；
`Will process N messages.` 要等翻页拉完历史才知道；`Added X, skipped Y` 与最后一行（
`Successfully in {d}s.` 或 `Failed: <原因>`）要等落库结束才知道。`Failed:` 那一行故意不带
耗时——一次失败跑的耗时不提供任何信息。这些行在产生的当下被追加进这个群
待发的队列里，**扫描全程结束（不论成功还是中途出错）时才一次性打包发出**。

一个群在扫描中途真的崩溃（不是"落库遇到几条失败"那种软失败，而是分页/判定阶段的硬错误）
时，已经产生的那些行——至少是横幅四行——仍然连同一行 `Failed: <原因>` 一起，作为这个群的
合并转发发出去，而不是这个群这一轮彻底没有任何输出。这行队列因此不总是恰好七行：中途崩溃时
`Will process` / `Added, skipped` 这两行可能根本没来得及产生，实际发出的可能只有五行；这是
刻意接受的诚实行为，不假装凑出一份完整的七行。

## 8. 模块划分

```
build.zig
build.zig.zon
src/
  main.zig            入口：无参数时读 env、起 HTTP 线程、跑调度循环；`import`/`run` 子命令
  config.zig          env 解析与校验
  redis/resp.zig      RESP2 编解码                        [纯函数]
  redis/client.zig    TCP 连接、命令发送、重连
  store.zig           语录存储层 add/has/remove/randomAny/randomByLength/allQuotes/randomMany/nextId
  napcat.zig          NapCat HTTP 客户端 callAction(action, params)
  onebot.zig          OB11 消息模型：段解析、replyTarget、renderText   [纯函数]
  scan/rules.zig      判定逻辑 classify(msgs, cfg) → {revoked, candidates}  [纯函数]
  scan/runner.zig     编排：翻页、补 get_msg、写库、发日志
  scheduler.zig       HH:MM 循环 + 窗口计算
  http/server.zig     std.http.Server + 路由
  http/hitokoto.zig   查询参数解析 + json/text/js 编码
  uuid.zig            UUIDv4 生成
```

### 8.1 边界与可测性

设计的核心是把全部业务判定压进三个纯函数模块，它们不碰网络也不碰 Redis：

- **`onebot.zig`** —— 输入一条 OB11 消息的 JSON，输出结构化的段列表、`reply` 目标 id、渲染后的文本。
- **`scan/rules.zig`** —— 输入窗口内的消息数组 + 配置（被观察者、管理员集合），输出 `{revoked: []id, candidates: []id}`。表情回应数据（✨ 的 `star_ids`、🔥 的 `fire_ids`）以参数形式注入，不在此模块内发起调用。
- **`redis/resp.zig`** —— 纯字节层面的协议编解码。

这样下列边界情况全部可以离线单测，不需要真实 QQ 群：

- 引用目标不在窗口内，但落在缓冲页里 → 正常解析
- 引用目标彻底无法解析 → skip + 警告，扫描不中断
- 💦 来自非管理员 → 不作废
- 💦 引用的不是被观察者的消息 → 不作废
- ✨ 引用消息夹带了图片段或多个文本段 → 不入库
- ✨ 文本带前后空白 → 应当入库
- 路径 3：管理员发 `✨ 内容` / `✨内容`（无空格）→ 均收录，正文不含前缀
- 路径 3：管理员只发一个 `✨` 且不带 reply → 剥前缀后为空 → skip
- 路径 3：非管理员发 `✨ 内容` → 不收录
- 路径 3：管理员发 `✨ 内容` 但带 reply 段 → 走路径 2 判定（文本不等于 `✨`）→ 不收录
- 路径 3 与路径 1 同时命中（被观察者兼任管理员）→ 按路径 3 处理，正文去前缀
- 💦 引用一条路径 3 收录的管理员指令消息 → 应当作废
- 💦 引用一条管理员发的普通消息（非 `✨` 格式）→ 不作废
- 同一条消息被多条路径同时命中 → 只入库一次
- 消息纯图片、纯表情 → 文本为空 → skip
- `at` 段有 / 无 `name` 字段
- 中文长度按码点计算
- 路径 4：两条 / 三条相邻合格消息合并为一条，正文空格拼接，成员不再各自单独入选路径1
- 路径 4：间距恰好 3 条消息仍相连，4 条则不相连、各自退回路径1
- 路径 4：只有 ✨ 没有 🔥（或反过来）→ 不参与链
- 路径 4：窗口内出现分页重叠导致的重复 `message_id` → 间距按去重后的序列算，不受影响
- 💦 引用链上任意一个成员（不论是不是主键）→ 作废整条链，全部成员都被 tombstone
- 路径 2 引用链上某个成员 → 该候选被抑制，只留 fire_chain 一条
- 链的主键 / 非主键成员自身满足路径3格式 → 路径3候选被抑制，链仍然赢，且 joined 正文剥掉该成员自己的 `✨` 前缀

`scan/runner.zig`、`napcat.zig`、`store.zig` 通过接口注入，测试时替换为 fake 实现，覆盖翻页终止、`get_msg` 补拉、日志时序。

### 8.2 线程模型

两条线程：

- **HTTP 线程** —— `std.http.Server` 阻塞 accept 循环
- **调度线程** —— 睡到下一个 `SCAN_TIME` 再执行扫描

各持有一条独立的 Redis 连接。`store` 层加 mutex 保护共享状态。两者之间没有其他共享可变状态。

## 9. 明确不做的事

- 不实现 `charset=gbk`
- 不实现 hitokoto 的类型分类（`c` 参数），全库单一类型
- 不做语录的编辑接口，入库后只能被 💦 作废
- 不做私聊场景（`get_friend_msg_history`），只扫群
- 不监听 NapCat 的 WebSocket 事件流，只做定时批量扫描
