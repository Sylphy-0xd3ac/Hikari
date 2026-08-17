# Hikari

Hikari 是一个用 Zig 写的常驻进程，零第三方依赖。每天定时扫描指定 QQ 群的历史消息，把群友用 ✨ 认可
（或管理员手动补录）的话收进 Redis，再通过一个与 [Hitokoto 一言 API](https://developer.hitokoto.cn/sentence/)
兼容的 HTTP 接口随机吐出来。扫描结果会以一条合并转发消息发回群里当运行日志。上游依赖
[NapCatQQ](https://github.com/NapNeko/NapCatQQ) 的 HTTP 接口（OneBot 11 + NapCat 扩展）。

## 快速开始

需要 Zig 0.15.2、一个可用的 Redis、一个已经登录好目标账号的 NapCat 实例。

```bash
# 构建（生产用 ReleaseSafe：见下方「构建」一节）
zig build -Doptimize=ReleaseSafe

# 配置
cp .env.example .env
# 编辑 .env，填入 NapCat/Redis 的真实地址与目标群号

# 起 daemon：HTTP 服务 + 每日定时扫描
./zig-out/bin/hikari

# 另开一个终端验证
curl 'http://127.0.0.1:8080/'
```

任一必填环境变量缺失或格式非法，进程启动即打印具体是哪一个变量并以非零状态退出，不会带着半残
配置起来。

## 收录规则

每天 `SCAN_TIME`（本地时区）触发一次扫描，窗口起点是这个群上次成功扫描的时刻，不是固定回看
24 小时；首次运行没有基线时退化为 `[触发时刻 − 24h, 触发时刻)`。命中以下任一路径即成为候选：

| 路径 | 触发条件 | 收录内容 |
|---|---|---|
| 1. 直接表情回应 | 被观察者（`OBSERVED_QQS`；留空表示观察所有人）发的消息被贴了 ✨ 表情回应 | 那条消息本身 |
| 2. 引用 ✨ | 别人引用被观察者的一条消息，除引用外只回一个 `✨` | 被引用的那条消息 |
| 3. 管理员手动收录 | 管理员（`ADMIN_QQS` 之一）发一条不含引用、以 `✨` 开头的消息 | `✨` 之后的正文；写成 `✨ @某人 内容` 时作者记在被 at 的那个人名下 |
| 3b. 管理员引用归属 | 管理员引用任意一条消息，除引用外只有 `✨ @某人` | 被引用的那条消息，作者记在被 at 的人名下；引用自己的消息也可以 |
| 4. 🔥 链式收录 | 一段**不间断**带 🔥 的消息里，被观察者同时带 ✨ 和 🔥 的那几条（≥2 条、同一个人）| 那几条按时间顺序拼成一条，用空格连接 |

优先级：**已确认的 💤 > 路径 3b > 路径 4 > 路径 3 > 路径 1**。路径 3 优先于路径 1，因为它是更具体的「作者本人手动指定」
信号；路径 4 优先于路径 3 和路径 1，因为它是一个分组信号——「这几条消息是同一句话」这件事，没有
别的路径能表达。已确认的 💤（见下）不是「又一条路径」，它是一道更前置的闸门：全部候选路径回答「这条消息该不该
被收录」，💤 回答「这个群这一轮要不要落库」。路径 3b 再压过路径 4，是因为管理员明确指定了单条原文
和作者，不能让自动分组把这条显式命令静默吞掉。

**`✨ @某人 内容`：管理员补录别人说过的话**。路径 3 的可选语法，向后兼容：

```
✨ @某人 内容   → 作者（from_who / ?user_id=）= 被 at 的那个人，正文 = 内容
✨ 内容         → 不变：作者 = 敲这条指令的管理员
```

管理员补录的本来就多半是**别人**说过的话，而改动之前作者被记成了管理员自己，`/?user_id=` 因此永远
查不到手动补录的语录归在真正说这句话的人名下。两条规则：**只有紧跟 `✨` 的那个 at 是作者标记**
（`✨ 你好 @某人` 里的 at 是普通正文，照常渲染成 `@昵称`；作者标记之后再出现的 at 同样是普通正文）；
**`creator`/`creator_uid` 仍然是那位管理员**——Hitokoto 语义下 creator 是「把这条语录加进来的人」，
跟「说这句话的人」是两回事。被 at 的人不要求在 `OBSERVED_QQS` 里（管理员是在显式断言作者）；
`✨ @某人` 后面没有正文时仍形成一条路径 3 候选：作者标记会被剥掉，候选在「正文为空」关卡计入
`skipped`；它不会跌回路径 1。光杆 `✨` 保持旧行为，不形成候选。这保证路径优先级与日志计数都诚实。

**`reply + ✨ @某人`：给引用原文指定作者**。管理员回复一条现成消息，除唯一的 reply 段外只发
`✨ @某人`（允许额外的空白 text 段）时，收录的是**被引用原文**，不是控制回复；原文可以由任何人
发送，也可以是管理员自己的消息，被 at 的作者同样不要求在 `OBSERVED_QQS`。`from_who` /
`user_id` 记给被 at 的人，`creator` / `creator_uid` 仍记给敲命令的管理员。夹带正文、图片、第二个 at
或其它段都不算这条语法。它是比自动 🔥 分组更明确的单条收录指令：目标不会再作为链内容被吞掉。

**图片与个人表情 OCR**：候选通过 tombstone / existing / chain-member 关卡后，如果正常渲染正文为空但目标含
图片或 QQ 个人/商城表情，Hikari 会把它们逐张交给 NapCat 原生增强 action **`.ocr_image`**。NapCat 当前通常把
收到的 `mface` 转成带 `emoji_id`/`url` 的 `image`，Hikari 也兼容直接上报的原生 `mface`：普通图片优先把
`file` 交还给同一个 NapCat、缺失时用 `url`；个人表情优先用真实 `url`（部分版本的 `file` 只是固定字符串
`marketface`），缺 URL 时按 `emoji_id` 补出 NapCat 同源图地址。一张图里的 `texts[].text` 和多张图之间都按返回顺序用换行连接。
这里的「个人表情」不是普通图片的同义词：它按 `emoji_id` 等字段单独识别，只是 NapCat 在**接收端**通常把
`mface` 改写成了 `image` 段。QQ 内置小表情则是只有数字 ID、没有可 OCR 图源的 `face` 段，仍不会拿去 OCR。
已有文字正文永远优先，不额外混入 OCR；OCR 是 best-effort，失败会告警，全部没有可用文本时仍按
`empty` 跳过。管理员发 `✨` 并在同一条消息里附图也属于有效候选——光杆 `✨` 本身仍无效。

**🔥 链的两种角色**：🔥 的含义是"这条消息和下一条属于同一句话"，🔥 必须构成一段**不间断**的连续
标记——走到第一条没有 🔥 的消息，这一段就结束（没有"最多隔几条"这种间距上限，那是旧规则）。段里
的消息分两种：**内容**（✨ + 🔥 + 作者是被观察者）的正文进语录；**桥**（带 🔥 但不是内容）的正文
**不**进语录，它只表示"这句话还没说完"，而且**可以是任何人发的**——桥的全部意义就是让一条链跨过
别人的插话。一条链的内容消息必须同属一个人（作者由第一条内容消息确定；中途冒出另一个被观察者的
内容消息就在那里断开、由它另起一条链），且至少两条，否则不成链、退回路径 1。

**💨 追加正文**：任意人引用一条本轮最终成立的候选，除引用外发 `💨 内容`，可同时带任意数量的 at 段。
Hikari 会剥掉 `💨` 与两侧语法空白，把所有 at 按原顺序移到补丁最前（如 `💨 内容 @甲 @乙` →
`@甲 @乙 内容`），再把整个补丁**不插空格**地追加到原正文末尾。除 reply/text/at 外夹带图片等其它段
则语法无效。多条补充按时间、再按 message_id 排序
依次追加；引用 🔥 链任意内容成员时追加到整条链。💨 回复自身是控制消息，即使又被贴 ✨ 也不会单独
入库；它在同窗口被 💦 撤掉时不参与追加。这个语法只影响本轮尚未入库的候选：原消息因 `existing`、
`tombstoned`、`chain member` 等关卡跳过时不会改写数据库里的旧语录，空原文也不会被补充内容“救活”。

**💦 作废**：管理员引用一条消息、除引用外只回 `💦`，且被引用的消息符合路径 1 或路径 3，就把对应
语录从 Redis 删除并永久 tombstone——之后任何一次扫描再次看到这条消息都不会重新入库。💦 引用到
🔥 链上任意一个**内容成员**都会作废整条链，全部内容成员都会被 tombstone，不只是被引用的那一条；
💦 引用一座**桥不**作废这条链（桥的正文一个字都没进这条语录，而且它可以是任何人发的——把"恰好被
贴了 🔥"变成"可以撤掉别人的语录"是一条谁都能踩到的越权路径），退化成对桥自己的一次普通撤稿。

**💦 引用那条 `✨` 也算**：路径 2 收录的语录，主键是**被引用的原消息**，但管理员在群里翻记录时看得见
的是第三方发的那条 `✨`——它就贴在原消息下面，是「这条被收录了」唯一的可见痕迹。所以 💦 的目标若
本身是一条路径 2 的 `✨` 触发消息（含引用、除引用外只有一个 `✨`，且发送者不是原消息作者），或管理员的
`reply + ✨ @某人` 引用归属命令，就**多解析一跳**，撤掉那条控制消息
引用的消息，然后所有既有规则（含 🔥 链展开）原样适用。只跳一次；跳到的东西解析不出来、或本身不是
一个可作废的目标时，跟改动之前一样什么都不发生。

**💤 今天先不收**：管理员先发一条**只有 💤** 的消息（不含引用、没有别的段、trim 之后逐字节等于 `💤`，
`💤💤` / `睡了💤` / `💤 明天见` 都不算）作为锚点，再由**发锚点的同一个管理员本人**给这条消息点一个
💤 QQ 表情回应，才算确认：**这个群**这一轮一条都不收录。单独发出锚点没有任何效果，别人代点 💤 也
不算；`get_msg` / `get_emoji_likes` 暂时核验失败也按未确认处理，不能让一句随手 💤 卡住扫描。其它群不受影响；这个群照样扫、照样发它那条七行合并转发，结果行会明确说明因已确认的 💤 命令
暂停，并把全部候选如实计进 `skipped`（`Added 0 messages, skipped N messages. Collection paused by confirmed 💤 reaction.`）——一个安静发不出东西
的群，跟一个死掉的服务，在群里必须长得不一样。**💦 撤稿照常执行**（💤 的意思是「今天别加东西」，
不是「忽略撤稿」），**`lastrun` 照常前移**（不前移的话下一次触发会重扫同一个窗口、看到同一条已确认的
💤、再跳过一次，是个自我持续的永久停摆）。反悔了就用 💦 引用那条锚点消息，本轮照常收录。

正常扫描的结果行会直接拆出每一种跳过原因，例如
`Added 6 messages, skipped 2 messages (existing 2, tombstoned 0, chain member 0, target missing 0, empty 0).`：
`existing` 是数据库里已经有这条消息，`tombstoned` 是它曾被 💦 永久作废，`chain member` 是正文已经
并入一条 🔥 链，`target missing` 是候选指向的原消息不在本轮消息池里、无法取得正文，`empty` 是剥掉
控制语法后正文为空。各项之和始终等于前面的 `skipped`，所以重扫时看到 skip 不再需要猜是哪一道去重
关卡命中。

**归属（`from` / `from_who`）**：`from` 是群名，`from_who` 是**语录作者自己**的群名片
（不是固定的某一个人）——`OBSERVED_QQS` 允许留空表示"观察所有人"，一个群不再有唯一的"那个
被观察者"可以整群问一次名片，改成按候选各自的作者查、每次扫描内按作者缓存（同一个人一天说好
几句只问一次）。这两者都是**渲染时解析**的：语录入库时把当时问到的名字写进 hash 当快照，同时
把最新值刷新进 `hikari:username:{user_id}` / `hikari:groupname:{group_id}`；下次有人改名或群改
名，只要这个人 / 这个群后续还被扫描到，`GET /` 之类的接口会优先用这两个键的实时值覆盖 hash 里
的旧快照，一次改名就能反映到这个人说过的全部历史语录，不需要逐条改写。这两个键缺失时（导入的
语录、从未被扫描到过的作者、已经离群且从未刷新成功过）落回 hash 里存的快照。管理员显式收录
（路径 3 / 3b）额外把 `creator`/`creator_uid` 覆盖成那位管理员自己的信息，而不是自动路径固定的
`"Hikari"`/`0`；用了 `✨ @某人 内容` 语法时 `from_who` 是被 at 的作者、`creator` 仍是管理员，两个人
的 `hikari:username:{qq}` 都会在这一轮刷新。

## 环境变量

复制 `.env.example` 为 `.env` 并填入真实值。Hikari 会自动读取**当前工作目录**下的 `.env`，无需先
`source`；文件不存在也不报错，只要真正的进程环境已经给齐配置。优先级固定为
**进程环境变量 > `.env`**，因此容器注入或命令行临时覆盖仍能压过文件值。生产环境统一把持久配置放在
`/opt/hikari/.env`；systemd unit 不再写 `Environment=` / `EnvironmentFile=`，避免同时维护两份配置。

`.env` 支持空行、`#` 注释、可选的 `export` 前缀，以及单双引号包住的值。值里含空白、`#` 或 shell
元字符时应加引号；外层引号会被剥掉，反斜杠保持字面量。它不是 shell，**不会展开** `$VAR` 或
`${VAR}`，避免同一份配置随启动进程的其它变量悄悄改变含义。文件语法错误时配置项会报为 `.env`。

| Env | 必填 | 说明 | 示例 |
|---|---|---|---|
| `NAPCAT_HTTP_URL` | 是 | NapCat HTTP 接口 base URL | `http://127.0.0.1:3000` |
| `NAPCAT_TOKEN` | 是 | NapCat access token，以 `Authorization: Bearer <token>` 发送 | |
| `OBSERVED_QQS` | 否 | 被观察的 QQ 号，逗号分隔；留空 = 观察所有人 | `10001,10002` |
| `QQ_GROUP_IDS` | 是 | 逗号分隔的目标群号，扫描与日志都作用于这些群 | `123456,789012` |
| `ADMIN_QQS` | 是 | 逗号分隔的管理员 QQ 号 | `20001,20002` |
| `SCAN_TIME` | 是 | 每日扫描时刻，24 小时制 `HH:MM`，本地时区 | `03:00` |
| `HTTP_HOST` | 是 | 一言服务监听地址 | `0.0.0.0` |
| `HTTP_PORT` | 是 | 一言服务监听端口 | `8080` |
| `REDIS_URL` | 是 | `redis://[:password@]host:port/db` | `redis://127.0.0.1:6379/0` |

## CLI

| 命令 | 行为 |
|---|---|
| `hikari` | 常驻：起 HTTP 服务 + 每日定时扫描 |
| `hikari run` | 立刻执行一次扫描后退出，不起 HTTP 服务；窗口计算、`lastrun` 写回都跟定时路径完全一致 |
| `hikari run --last <时长>` | 忽略本次窗口起点的 `lastrun`，强制重扫最近一段时间；支持正整数 `m`/`h`/`d`，最大 `7d` |
| `hikari import --user <qq> <file>` | 从换行分隔的文本文件批量导入语录；`--user` 必填，全部导入内容明确归到这个 QQ 名下 |
| `hikari reindex` | 把 `hikari:index` 里已有的语录逐条补进作者维度的索引 `hikari:byuser:{user_id}`，然后退出。幂等、可重复跑；只读语录 hash，绝不创造或改动语录。只有显式敲这条命令才会跑——启动、定时扫描、HTTP 读路径都不碰它 |

```bash
./zig-out/bin/hikari run
./zig-out/bin/hikari run --last 24h
./zig-out/bin/hikari import --user 10001 seed.txt
./zig-out/bin/hikari reindex
```

`run --last` 是补漏/重扫入口。例如 `--last 1h`、`--last 3h`、`--last 24h` 分别强制使用
`[现在−1h, 现在)`、`[现在−3h, 现在)`、`[现在−24h, 现在)`，但不删除 Redis 里的进度。
已有语录会被 `hikari:index` 去重，已作废消息会被 `hikari:tomb` 拦住，已经属于 🔥 链的成员也不会
被拆开重复收录；因此它只补进窗口内尚未入库的候选。成功后仍把 `lastrun` 前移到本次的 `now`，
下一轮定时扫描继续正常衔接。

`import --user` 不再从 `OBSERVED_QQS` 猜作者：观察多人时不存在唯一答案，观察所有人时更没有可猜的
值。命令使用 `QQ_GROUP_IDS` 的第一个群取得群名和该 QQ 的群名片；任一归属信息取不到就整次失败、
一条也不写。重复导入同一正文仍然幂等，已存在或已 tombstone 的行会如实计入摘要。

## HTTP 接口

**`GET /`** —— 返回随机一条语录，参数遵循 Hitokoto 规范：

| 参数 | 支持情况 |
|---|---|
| `encode` | `json`（默认）/ `text` / `js` |
| `min_length` / `max_length` | 支持，按语录长度（UTF-8 码点数）过滤 |
| `user_id` | 支持，按作者（QQ 号）过滤，可与 `min_length`/`max_length` 组合；非法值（非数字/负数/溢出）→ 400 |
| `from_who` | 支持，按当前渲染出的群名片/昵称精确匹配，可与 `user_id` 和长度组合；值需 URL 编码且必须是非空 UTF-8 |
| `callback` | 支持，存在时输出 JSONP：`{callback}({json})`，回调名只接受 `[A-Za-z0-9_$.]` |
| `select` | 支持，`encode=js` 时的 DOM 选择器，默认 `.hitokoto` |
| `charset` | 仅支持 `utf-8`（大小写不敏感），其他值返回 400——本库没有内嵌 GBK 码表 |
| `c` | 接受但忽略——全库只有一个类型，`type` 恒为 `"g"` |

错误：库空 / 过滤（长度、`user_id` 和/或 `from_who`）后无结果 → 404；参数非法（`charset` 非 utf-8、
`min_length` > `max_length`、数字解析失败、`callback` 非法、`user_id` 非法、`from_who` 为空或非 UTF-8）→ 400；方法非 `GET`
→ 405；Redis 不可用 → 500。均为 JSON 错误体。

**`hikari reindex` 跑之前，`/?user_id=` 对整个存量语录库都是空的**：136 条历史语录早于按作者
过滤的索引（`hikari:byuser`，见下）存在，从未被补进这份索引；而它们**同属一个作者**，所以这不是
"部分作者查不到"，是这个参数对上线前的**全部**语录一律返回"这个人没有语录"（404）——即使
`GET /`（不带 `user_id`）明明能随机到它们。跑一次 `hikari reindex` 即可修复，详见 Redis 键结构
一节 `hikari:byuser` 的说明。

**`GET /extra/all`** 与 **`GET /extra/batch/:count`** 是超出 Hitokoto 协议范围的自定义扩展，落在
`/extra/` 前缀下，响应是一个 JSON 数组。除 `select`（被接受但忽略，`encode=js` 在这两个端点上不
支持，`select` 没有对应的用武之地）外，其余参数都跟 `/` 同构：

| 参数 | 支持情况 |
|---|---|
| `user_id` | 按作者过滤，同 `/` |
| `from_who` | 按当前群名片/昵称精确匹配，同 `/` |
| `min_length` / `max_length` | 按语录长度过滤，同 `/` |
| `encode=json`（默认）| `[{完整对象}, ...]` |
| `encode=text` | `["正文1", "正文2", ...]`——只有 `hitokoto` 正文的字符串数组 |
| `encode=js` | **400**，不是静默降级成 `json`——`js` 编码是"把正文写进一个 DOM 元素"的脚本，这个概念要求恰好一条语录对应一个 DOM 目标，对一个数组没有自然的定义；宁可让客户端明确看到"这个形状不支持"，也不要在它以为拿到 `js` 时悄悄换一种完全不同的响应形态，这跟 `charset=gbk` 被拒绝而不是悄悄当 `utf-8` 处理是同一个原则 |
| `callback` | 支持，把**整个数组**包进 `{callback}(...)` 这层 JSONP 壳；跟 `/` 不同的是，这里 `callback` 不会覆盖 `encode` 的选择——两者正交，`callback` 只决定要不要包一层函数调用 |
| `charset` | 仅支持 `utf-8`，同 `/` |
| `c` | 接受但忽略，同 `/` |
| `select` | 接受但忽略 |

`Content-Type`：`encode=json`/`encode=text` 都是 `application/json; charset=utf-8`；带 `callback`
时是 `application/javascript; charset=utf-8`。

| 端点 | 行为 |
|---|---|
| `GET /extra/all` | 返回全部（或过滤后）的语录，无上限 |
| `GET /extra/batch/:count` | 随机返回 `count` 条语录，允许重复；`count` 须为 1–1000 的整数，否则 400——这条上限不受 `user_id` 过滤影响，`count` 是"要抽多少次"，跟候选集合大小是两回事 |

库空、或者过滤后无结果，这两个端点返回 `[]` + 200，不是 404——空数组本身就是一个成功的答案，跟
`/` 那种「没有可服务的单条语录」是不同的语义。

```bash
curl 'http://127.0.0.1:8080/'
curl 'http://127.0.0.1:8080/?encode=text'
curl 'http://127.0.0.1:8080/?user_id=10001'
curl 'http://127.0.0.1:8080/?from_who=%E5%B0%8F%E6%98%8E'
curl 'http://127.0.0.1:8080/extra/all'
curl 'http://127.0.0.1:8080/extra/all?user_id=10001&encode=text'
curl 'http://127.0.0.1:8080/extra/all?from_who=%E5%B0%8F%E6%98%8E'
curl 'http://127.0.0.1:8080/extra/batch/5'
curl 'http://127.0.0.1:8080/extra/batch/5?user_id=10001&from_who=%E5%B0%8F%E6%98%8E'
```

`from_who` 不建立持久昵称索引：昵称会变化且允许重名。只有显式传这个参数时，Hikari 才在 QQ/长度
筛出的候选上读取当前 `hikari:username:{user_id}` 并精确匹配；因此改名立即生效，重名作者都会参与
随机/数组结果。`user_id` 始终只表示稳定的纯数字 QQ 号，不能把昵称塞进该参数。

## Redis 键结构

| 键 | 类型 | 内容 |
|---|---|---|
| `hikari:quote:{message_id}` | HASH | 语录全部字段 |
| `hikari:index` | SET | 全部已入库的 `message_id` |
| `hikari:bylen` | ZSET | score = 语录长度（UTF-8 码点数），member = `message_id` |
| `hikari:tomb` | SET | 被作废的 `message_id`（永久） |
| `hikari:seq` | STRING | 自增计数器，供 `INCR` 生成 `id` 字段 |
| `hikari:lastrun:{group_id}` | STRING | 这个群上次成功扫描的窗口终点（Unix 秒），逐群独立 |
| `hikari:username:{user_id}` | STRING | 这个人当前的群名片（或昵称），每次扫描按遇到的候选作者刷新；渲染时覆盖语录 hash 里冻结的 `from_who` 快照 |
| `hikari:groupname:{group_id}` | STRING | 这个群当前的群名，每次扫描刷新；渲染时覆盖语录 hash 里冻结的 `from` 快照 |
| `hikari:byuser:{user_id}` | ZSET | score = 语录长度（UTF-8 码点数），member = `message_id`——作者维度的索引，`/?user_id=` 在全部三个 HTTP 端点上都靠它 |

**`hikari:byuser` 是后加的键，136 条此前收录的生产语录不在里面；修复手段是 `hikari reindex`**：
这份索引在它们收录时还不存在。后果是整体性的而不是局部的——这 136 条同属一个作者，所以在 reindex
跑之前 `/?user_id=` 对**整个存量语录库**都是空的；`GET /`（不带 `user_id`）等所有其它读路径不受
影响，新语录从收录那一刻起也会正确地进入这份索引。

"重新收录一遍就好"行不通（文档里一度这么写过，是错的）：扫描器与 `hikari import` 都在
`Store.exists()` 那道关卡上就返回了，`add()`/`addChain()` 根本走不到，重放多少次都补不上索引。
`hikari reindex` 就是那条只回填索引、不改动语录本身的路径：`SMEMBERS hikari:index` → 逐 id
`HMGET hikari:quote:{id} user_id length` → `ZADD hikari:byuser:{user_id} {length} {id}`，跑完打
一行摘要。它幂等、可重复跑，且只在运营方显式敲它时才运行。

## 构建

Zig 版本固定 0.15.2。生产构建：

```bash
zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe
```

用 `ReleaseSafe` 而不是 `ReleaseFast` / `ReleaseSmall`：后两者会把 `std.log` 的默认级别从 `info`
降到 `err`，扫描过程、重连、DST 偏移这些诊断信息会全部消失，出问题时排查不了。

## 部署

以非 root 用户运行，交给 systemd 管理：

```ini
[Unit]
Description=Hikari
After=network-online.target redis.service
Wants=network-online.target

[Service]
Type=simple
User=hikari
WorkingDirectory=/opt/hikari
ExecStart=/opt/hikari/hikari
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

上例由 Hikari 自己读取 `/opt/hikari/.env`，所以 `WorkingDirectory` 不能省。`/opt/hikari/.env` 是生产
环境唯一的持久配置来源；不要再给 unit 添加 `Environment=` 或 `EnvironmentFile=`，也不要保留一份会
与它漂移的 `hikari.env`。配置文件应只允许服务用户读取（例如 mode `0600`）。

日志走 journal：

```bash
journalctl -u hikari -f
```

## 开发

```bash
zig build test          # 完整测试套件
```

跑一次真实扫描不需要等到定时触发，也不需要临时改 `SCAN_TIME` 再改回去：`hikari run` 用跟常驻路径
完全同一套装配（同一个 config、同一种独立 Redis 连接）立刻跑一次并退出。

部署目标是 `x86_64-linux-gnu`，本仓库零第三方依赖，`-Dtarget` 交叉编译到其他平台同样适用，只是
目前只有这一个目标经过实际部署验证。

涉及所有权转移的代码（谁在错误路径上该释放哪块内存）容易在 OOM 分支上出岔子，本仓库的约定是这类
代码都配一条 `std.testing.checkAllAllocationFailures` 测试，逐次让分配失败、确认每条路径都不泄漏
也不重复释放。

## 设计文档

NapCat 接口细节、message_id 的哈希性质、扫描窗口与翻页算法、字段映射等完整设计见
[`docs/superpowers/specs/2026-08-15-hikari-design.md`](docs/superpowers/specs/2026-08-15-hikari-design.md)。
