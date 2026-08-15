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
| `get_group_msg_history` | 翻页拉取群历史 | 入参 `group_id`, `message_seq`, `count`, `reverse_order`。**返回的消息不含 `emoji_likes_list`** |
| `get_msg` | 取单条消息详情 | 返回体含 `emoji_likes_list: [{emoji_id, emoji_type, likes_cnt}]` |
| `get_group_info` | 取群名 | 填充 hitokoto 的 `from` |
| `get_group_member_info` | 取被观察者群名片 | 填充 hitokoto 的 `from_who` |
| `send_group_msg` | 发送运行日志 | 每行一条 |

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

### 3.3 ✨ 的标识

QQ 表情回应有两类：`emoji_type=1` 是 QQ 系统表情（id 为两三位数字），`emoji_type=2` 是 Unicode emoji（id 为码点十进制）。

✨ = U+2728 = 十进制 **10024**，`emoji_type=2`。

该常量定义在一处（`src/napcat.zig`），且扫描时会把所有**未匹配**的 `emoji_id` 打进日志，便于首次实跑时核对真实值。

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

1. 首次调用 `get_group_msg_history`（不带 `message_seq`）取最新一批，`count = 200`。
2. 取批内最老一条的 `message_id` 作为下一次的 `message_seq`，继续往前翻。
3. 终止条件：本批最老消息的 `time` 早于窗口起点**且已额外多拉一页**（3.2 节的解析缓冲），或返回空列表，或 `message_seq` 不再前进（防死循环）。
4. 结果按 `time` 升序排列。落在窗口内的部分是**判定集**；窗口之外的缓冲页只用于解析 `reply` 目标，自身不参与 Pass A / Pass B 的判定。

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

### 4.4 作废落盘

Pass A 结束后立即执行，先于 Pass B：

- 从 Redis 删除 `R` 对应的语录记录（若已入库）
- 把 `R` 写入 `hikari:tomb`

tombstone 是永久的：以后任何一次扫描再次看到这条消息，无论有没有 ✨，都不会入库。这满足"跨扫描窗口的 💦 也能作废前几天已入库的语录"。

### 4.5 Pass B —— 收集候选

三条独立路径，命中任意一条即成为候选：

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

路径 3 是唯一一条正文不等于目标消息全文的路径。因此 `rules.zig` 输出的候选结构体带一个 `text_override` 字段：路径 3 填去掉前缀后的正文，路径 1、2 留空表示"按 4.6 节从目标消息提取"。

### 4.5.1 路径冲突与优先级

- **路径 3 优先于路径 1。** 当被观察者本人同时也是管理员时，他发的 `✨ 某句话` 若又被别人贴了 ✨ 表情回应，两条路径会命中同一个 `message_id`。此时按路径 3 处理，正文去掉 `✨` 前缀。
- 路径 2 与路径 3 互斥（前者要求含 `reply` 且文本恰为 `✨`，后者要求不含 `reply` 且 `✨` 后有内容），不会同时命中。
- 除上述情形外，同一条消息被多条路径命中时按 `message_id` 去重，只入库一次。

副作用提示：被观察者若被列入 `ADMIN_QQS`，他自己发的 `✨ ...` 会被自动收录。这是规则的自然推论，不作特殊处理。

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

路径 3 的候选带 `text_override`，正文直接取该字段（它已经是渲染并剥掉 `✨` 前缀后的结果），不再重复提取。

### 4.7 字段映射

| Hitokoto 字段 | 来源 |
|---|---|
| `id` | `INCR hikari:seq` |
| `uuid` | 本地生成的 UUIDv4 |
| `hitokoto` | 4.6 提取出的文本（路径 3 为剥掉 `✨` 前缀后的正文） |
| `type` | 固定 `"g"`（其他） |
| `from` | 群名，来自 `get_group_info` |
| `from_who` | 被观察者群名片，来自 `get_group_member_info` |
| `creator` | 固定 `"Hikari"` |
| `creator_uid` | 固定 `0` |
| `reviewer` | 固定 `0` |
| `commit_from` | 固定 `"hikari"` |
| `created_at` | 候选消息的 `time`，字符串形式的 Unix 秒。路径 3 取管理员那条指令消息的时间 |
| `length` | `hitokoto` 的 **UTF-8 码点数**（不是字节数） |

`from` / `from_who` 每次扫描每个群各拉取一次后缓存，不逐条调用。

## 5. Redis 结构

| 键 | 类型 | 内容 |
|---|---|---|
| `hikari:quote:{message_id}` | HASH | 第 4.7 节全部字段，外加 `message_id` / `group_id` / `user_id` |
| `hikari:index` | SET | 全部已入库的 `message_id` |
| `hikari:bylen` | ZSET | score = `length`（码点数），member = `message_id` |
| `hikari:tomb` | SET | 被作废的 `message_id` |
| `hikari:seq` | STRING | 自增计数器，供 `INCR` |
| `hikari:lastrun:{group_id}` | STRING | 这个群上次扫描窗口终点的 Unix 秒，逐群独立 |

**写入**（单条语录，按此顺序逐条发送）：`HSET hikari:quote:{id} ...` → `ZADD hikari:bylen {length} {id}` → `SADD hikari:index {id}`

顺序即事务语义。`exists()` 查的是 `hikari:index`，所以 `SADD` 是提交点、必须最后发：任何一次部分失败留下的状态都满足 `exists() == false`，下一次扫描原样重做一遍就修好了（三条命令都幂等）。反过来若 `SADD` 先于 `ZADD`，"`HSET`+`SADD` 成功、`ZADD` 失败" 会让这条语录 `exists() == true` 却永远不在 `hikari:bylen` 里——`GET /` 能随机到，任何带 `min_length`/`max_length` 的查询都永远看不见，且不会自愈。

**删除**（同样按此顺序）：`SADD hikari:tomb {id}` → `SREM hikari:index {id}` → `ZREM hikari:bylen {id}` → `DEL hikari:quote:{id}`

tombstone 先落盘：它是这次作废唯一持久的事实，删索引与删 hash 都只是它的后果。这样最坏留下一个孤儿 hash（没人索引得到，只占空间），而不是 `hikari:index` 里一个没有 hash 的悬空 id——后者会被 `SRANDMEMBER` 抽中、`HGETALL` 回空，让一个非空的库对外返回 404，且永远不会自愈。

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
- 路径非 `/` → 404

## 7. 运行日志

每次定时运行，逐行发送到 `QQ_GROUP_IDS` 中的每一个群，每行一条 `send_group_msg`：

```
Hikari!
Made with ❤️ by CuzTeam, AmethystDevs-Lab
Thanks to collaborators: 恩恩hhh, apanzinc, Lonely, 小晴同学, Sylphy
Processing...
Will process 1234 messages.
Added 12 messages, skipped 34 messages.
Successfully.
```

时序：前 4 行在扫描开始前发出；`Will process N messages.` 在历史翻页完成、窗口内消息数确定后发出；`Added X messages, skipped Y messages.` 与 `Successfully.` 在入库完成后发出。

`N` 是窗口内消息总数，`X` 是本次新入库条数，`Y` 是被各关卡拦下的候选数。

运行中抛出异常时，最后一行替换为 `Failed: <原因>`，其余已发出的行不回滚。

## 8. 模块划分

```
build.zig
build.zig.zon
src/
  main.zig            入口：读 env、起 HTTP 线程、跑调度循环
  config.zig          env 解析与校验
  redis/resp.zig      RESP2 编解码                        [纯函数]
  redis/client.zig    TCP 连接、命令发送、重连
  store.zig           语录存储层 add/has/remove/randomAny/randomByLength/nextId
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
- **`scan/rules.zig`** —— 输入窗口内的消息数组 + 配置（被观察者、管理员集合），输出 `{revoked: []id, candidates: []id}`。表情回应数据以参数形式注入，不在此模块内发起调用。
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
