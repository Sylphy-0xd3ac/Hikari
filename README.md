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
set -a && source .env && set +a
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
| 3. 管理员手动收录 | 管理员（`ADMIN_QQS` 之一）发一条不含引用、以 `✨` 开头的消息 | `✨` 之后的正文 |
| 4. 🔥 链式收录 | 一段**不间断**带 🔥 的消息里，被观察者同时带 ✨ 和 🔥 的那几条（≥2 条、同一个人）| 那几条按时间顺序拼成一条，用空格连接 |

优先级：**路径 4 > 路径 3 > 路径 1**。路径 3 优先于路径 1，因为它是更具体的「作者本人手动指定」
信号；路径 4 优先于路径 3 和路径 1，因为它是一个分组信号——「这几条消息是同一句话」这件事，没有
别的路径能表达。

**🔥 链的两种角色**：🔥 的含义是"这条消息和下一条属于同一句话"，🔥 必须构成一段**不间断**的连续
标记——走到第一条没有 🔥 的消息，这一段就结束（没有"最多隔几条"这种间距上限，那是旧规则）。段里
的消息分两种：**内容**（✨ + 🔥 + 作者是被观察者）的正文进语录；**桥**（带 🔥 但不是内容）的正文
**不**进语录，它只表示"这句话还没说完"，而且**可以是任何人发的**——桥的全部意义就是让一条链跨过
别人的插话。一条链的内容消息必须同属一个人（作者由第一条内容消息确定；中途冒出另一个被观察者的
内容消息就在那里断开、由它另起一条链），且至少两条，否则不成链、退回路径 1。

**💦 作废**：管理员引用一条消息、除引用外只回 `💦`，且被引用的消息符合路径 1 或路径 3，就把对应
语录从 Redis 删除并永久 tombstone——之后任何一次扫描再次看到这条消息都不会重新入库。💦 引用到
🔥 链上任意一个**内容成员**都会作废整条链，全部内容成员都会被 tombstone，不只是被引用的那一条；
💦 引用一座**桥不**作废这条链（桥的正文一个字都没进这条语录，而且它可以是任何人发的——把"恰好被
贴了 🔥"变成"可以撤掉别人的语录"是一条谁都能踩到的越权路径），退化成对桥自己的一次普通撤稿。

**归属（`from` / `from_who`）**：`from` 是群名，`from_who` 是**语录作者自己**的群名片
（不是固定的某一个人）——`OBSERVED_QQS` 允许留空表示"观察所有人"，一个群不再有唯一的"那个
被观察者"可以整群问一次名片，改成按候选各自的作者查、每次扫描内按作者缓存（同一个人一天说好
几句只问一次）。这两者都是**渲染时解析**的：语录入库时把当时问到的名字写进 hash 当快照，同时
把最新值刷新进 `hikari:username:{user_id}` / `hikari:groupname:{group_id}`；下次有人改名或群改
名，只要这个人 / 这个群后续还被扫描到，`GET /` 之类的接口会优先用这两个键的实时值覆盖 hash 里
的旧快照，一次改名就能反映到这个人说过的全部历史语录，不需要逐条改写。这两个键缺失时（导入的
语录、从未被扫描到过的作者、已经离群且从未刷新成功过）落回 hash 里存的快照。管理员手动收录
（路径 3）额外把 `creator`/`creator_uid` 覆盖成那位管理员自己的信息，而不是其余三条路径固定的
`"Hikari"`/`0`。

## 环境变量

复制 `.env.example` 为 `.env` 并填入真实值。

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
| `hikari import <file>` | 从一个换行分隔的文本文件批量导入语录，用于给空库播种 |
| `hikari reindex` | 把 `hikari:index` 里已有的语录逐条补进作者维度的索引 `hikari:byuser:{user_id}`，然后退出。幂等、可重复跑；只读语录 hash，绝不创造或改动语录。只有显式敲这条命令才会跑——启动、定时扫描、HTTP 读路径都不碰它 |

```bash
./zig-out/bin/hikari run
./zig-out/bin/hikari import seed.txt
./zig-out/bin/hikari reindex
```

## HTTP 接口

**`GET /`** —— 返回随机一条语录，参数遵循 Hitokoto 规范：

| 参数 | 支持情况 |
|---|---|
| `encode` | `json`（默认）/ `text` / `js` |
| `min_length` / `max_length` | 支持，按语录长度（UTF-8 码点数）过滤 |
| `user_id` | 支持，按作者（QQ 号）过滤，可与 `min_length`/`max_length` 组合；非法值（非数字/负数/溢出）→ 400 |
| `callback` | 支持，存在时输出 JSONP：`{callback}({json})`，回调名只接受 `[A-Za-z0-9_$.]` |
| `select` | 支持，`encode=js` 时的 DOM 选择器，默认 `.hitokoto` |
| `charset` | 仅支持 `utf-8`（大小写不敏感），其他值返回 400——本库没有内嵌 GBK 码表 |
| `c` | 接受但忽略——全库只有一个类型，`type` 恒为 `"g"` |

错误：库空 / 过滤（长度和/或 `user_id`）后无结果 → 404；参数非法（`charset` 非 utf-8、
`min_length` > `max_length`、数字解析失败、`callback` 非法、`user_id` 非法）→ 400；方法非 `GET`
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
curl 'http://127.0.0.1:8080/extra/all'
curl 'http://127.0.0.1:8080/extra/all?user_id=10001&encode=text'
curl 'http://127.0.0.1:8080/extra/batch/5'
curl 'http://127.0.0.1:8080/extra/batch/5?user_id=10001'
```

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
EnvironmentFile=/opt/hikari/.env
ExecStart=/opt/hikari/hikari
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

日志走 journal：

```bash
journalctl -u hikari -f
```

## 开发

```bash
zig build test          # 单元测试，333 个
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
