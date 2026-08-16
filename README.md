# Hikari

Hikari 是一个用 Zig 写的常驻进程：每天定时扫描指定 QQ 群的历史消息，把群友认可的话收录成语录存进
Redis，再通过一个与 [Hitokoto 一言 API](https://developer.hitokoto.cn/sentence/) 兼容的 HTTP
接口随机吐出来。上游依赖 [NapCatQQ](https://github.com/NapNeko/NapCatQQ) 的 HTTP 接口（OneBot 11 +
NapCat 扩展）。

完整设计（NapCat 接口细节、message_id 的哈希性质与 LRU 反查限制、扫描窗口与翻页算法、字段映射等）见
[`docs/superpowers/specs/2026-08-15-hikari-design.md`](docs/superpowers/specs/2026-08-15-hikari-design.md)。
本文档只覆盖运行一个实例所需的信息。

## 三条收录路径与 💦 作废规则

每天 `SCAN_TIME` 触发一次，扫描窗口 `[上次这个群成功扫描的时刻, 这次触发时刻)`——窗口起点逐群
独立、按各自的 `hikari:lastrun:{group_id}` 算，不是固定回看 24 小时；首次运行（没有基线）时
退化成 `[触发时刻 - 24h, 触发时刻)`。跨度超过 7 天会截断并打警告，详见「构建与运行」一节。
命中以下任一路径即成为候选：

1. **直接表情回应**：被观察者（`OBSERVED_QQ`）发的消息被贴了 ✨ 表情回应 → 候选是那条消息本身。
2. **引用 ✨**：别人引用被观察者的一条消息，除引用外只回一个 `✨` → 候选是被引用的那条消息。
3. **管理员手动收录**：管理员（`ADMIN_QQS` 之一）发一条不含引用、以 `✨` 开头的消息 → 候选是这条消息，
   正文取 `✨` 之后的部分。

三条路径互不冲突时按 `message_id` 去重；被观察者本人若同时是管理员，路径 3 优先于路径 1（详见设计文档
§4.5.1）。

**💦 作废**：管理员引用一条消息、除引用外只回 `💦`（trim 后恰为 `💦`），且被引用的消息是「被观察者发的」
或「符合路径 3 格式的管理员消息」，就把该消息对应的语录从 Redis 删除并写入 tombstone 集合
（`hikari:tomb`）。tombstone 永久生效——之后任何一次扫描再次看到这条消息都不会重新入库，
这样跨扫描窗口的 💦 也能作废前几天已经收录的语录。作废判定（Pass A）先于收录判定（Pass B）执行，且落盘
先于收录：同一次扫描里先处理完所有作废，再处理收录。

## 环境变量

复制 [`.env.example`](.env.example) 为 `.env` 并填入真实值。任一必填项缺失或格式非法，进程启动即打印
具体是哪一个变量并以非零状态退出——不会带着半残配置起来。

| Env | 必填 | 说明 | 示例 |
|---|---|---|---|
| `NAPCAT_HTTP_URL` | 是 | NapCat HTTP 接口 base URL | `http://127.0.0.1:3000` |
| `NAPCAT_TOKEN` | 是 | NapCat access token，以 `Authorization: Bearer <token>` 发送 | |
| `OBSERVED_QQ` | 否（留空=全部） | 被观察的 QQ 号，多个用逗号分隔 | `10001,10002` |
| `QQ_GROUP_IDS` | 是 | 逗号分隔的目标群号，扫描与日志都作用于这些群 | `123456,789012` |
| `ADMIN_QQS` | 是 | 逗号分隔的管理员 QQ 号 | `20001,20002` |
| `SCAN_TIME` | 是 | 每日扫描时刻，24 小时制 `HH:MM`，本地时区 | `03:00` |
| `HTTP_HOST` | 是 | 一言服务监听地址 | `0.0.0.0` |
| `HTTP_PORT` | 是 | 一言服务监听端口 | `8080` |
| `REDIS_URL` | 是 | `redis://[:password@]host:port/db` | `redis://127.0.0.1:6379/0` |

## 构建与运行

Zig 版本固定 0.15.2。

```bash
# 构建（生产用 ReleaseSafe：保留边界检查，去掉调试断言）
zig build -Doptimize=ReleaseSafe

# 跑测试
zig build test

# 运行
set -a && source .env && set +a
./zig-out/bin/hikari
```

进程内部开两条独立的 Redis 连接：一条给 HTTP 服务用，一条给每日扫描用。两者各自持有自己的连接，不跨
线程共享——`redis.Client` 内部的 reader/writer 持有指向自身的指针，`Store` 的锁只保护单个 `Store`
对自己那条连接的访问，并不能让一条连接被多个线程安全共享。HTTP 服务跑在一个 detached 线程上；主线程
跑每日调度循环，持有进程生命周期。

每条连接都能自愈：遇到传输层失败（socket 断开、读写失败、协议错乱、接收超时）会自动重连并把这条命令
**重试一次**，第二次仍失败才把错误交出去。所以 Redis 重启、空闲超时、NAT 连接跟踪过期都不需要重启
Hikari。扫描线程一天里有约 23.99 小时是闲着的，这条路径实际上每天都会被走到。重连时会重新执行
`AUTH` / `SELECT`，并整个丢弃读缓冲——半条没读完的回复留在缓冲里会让之后每一条回复都错位一格，那是
静默的数据错误。代价是一条已经被服务端执行过的命令可能被重放一次；本仓库里唯一非幂等的命令是
`INCR hikari:seq`，重放只是白烧一个 id（`id` 允许有空洞）。

每条连接的 socket 上还带了 `SO_RCVTIMEO`（`redis.Client.recv_timeout_s`，默认 30 秒）：一个接受了
TCP 连接却从不回复的 Valkey，不会让上面这套重连逻辑帮上忙——它只在内核报传输层错误时才触发，卡住
的连接内核什么错都不会报。有了这个超时，卡住的读最多阻塞 30 秒就会失败，走上面同一条自愈路径。

调度循环每一轮都会重新计算一次本地时区相对 UTC 的偏移（`scheduler.localOffsetSeconds`），而不是在循环
外算一次复用——夏令时切换会改变这个偏移，进程一次起来常常要跑几个月，缓存旧偏移会导致跨越 DST 边界之后
触发时刻整体偏移一小时。

扫描窗口起点逐群独立、按各自的 `hikari:lastrun:{group_id}` 算（见「三条收录路径与 💦 作废规则」一节），
不是固定回看 24 小时，所以夏令时「回拨」那种本地一天长达 25 小时的日子，窗口也会自然覆盖到完整的
25 小时，不会像固定 24h 窗口那样把最早的 1 小时截掉。跨度超过 7 天（`scheduler.max_lookback_seconds`）
会截断到 7 天并打警告，点名是哪个群、丢了哪一段——截断掉的那部分不会再被任何一次扫描覆盖到，其中的
💦 撤稿指令因此永久不可恢复。

进程重启时会额外判断「今天该跑的时刻是否已经过去但还没跑」（`missedRun`），逐群判断（每个群各自的
`hikari:lastrun:{group_id}`，见下方键结构）：只要有一个群漏跑，就立即用最早的那个漏跑时刻补跑一次；
已经跟上的群这时候拿到的是空窗口（`last_run >= run_at`），不会再做任何多余的重扫。某个群首次启动
没有基线（它自己的 `hikari:lastrun:{group_id}` 不存在），这个群的补跑判断直接跳过，等下一个正常
触发时刻——这个群自己那次会退化成固定 24h 窗口。

一个群这一轮里出岔子（作废没落盘、语录没入库、归属信息问不出来）不会写它自己的 `hikari:lastrun:{group_id}`，
所以它不需要等到进程重启：下一次正常触发时，窗口起点仍然停在上一次成功的位置，会自动把漏掉的这段（含
其中的 💦 撤稿）重新覆盖到，直到 7 天回看上限。

## HTTP 接口

`GET /`，返回随机一条语录，参数遵循 Hitokoto 规范：

| 参数 | 支持情况 |
|---|---|
| `encode` | `json`（默认）/ `text` / `js` |
| `min_length` | 支持，走 `hikari:bylen` 有序集合 |
| `max_length` | 支持，走 `hikari:bylen` 有序集合 |
| `callback` | 支持，存在时输出 JSONP：`{callback}({json})`，Content-Type 为 `application/javascript`。回调名只接受 `[A-Za-z0-9_$.]`，拒绝其他字符以防 JSONP 注入 |
| `select` | 支持，`encode=js` 时的 DOM 选择器，默认 `.hitokoto` |
| `c` | **接受但忽略**——全库只有一个类型，`type` 恒为 `"g"` |
| `charset` | **仅支持 `utf-8`**（大小写不敏感，`utf8` / `utf-8` 均可）。传其他值返回 400。这是一处明确、有意的规范偏离：GBK 转码需要内嵌一张完整码表，为一个自用接口引入这个体积不划算 |

**响应形态**

- `encode=json`：`Content-Type: application/json; charset=utf-8`，返回完整字段对象
- `encode=text`：`Content-Type: text/plain; charset=utf-8`，只返回 `hitokoto` 正文
- `encode=js`：`Content-Type: application/javascript; charset=utf-8`，返回把正文写入 `select` 选中
  元素的自执行脚本

**错误**：库空 / 长度过滤后无结果 → 404；`charset` 非 `utf-8`、`min_length` > `max_length`、参数非
数字、`callback` 非法 → 400；路径非 `/` → 404；方法非 `GET` → 405；Redis 不可用 → 500。均为 JSON
错误体。

## Redis 键结构

| 键 | 类型 | 内容 |
|---|---|---|
| `hikari:quote:{message_id}` | HASH | 语录全部字段 |
| `hikari:index` | SET | 全部已入库的 `message_id` |
| `hikari:bylen` | ZSET | score = 语录长度（UTF-8 码点数），member = `message_id` |
| `hikari:tomb` | SET | 被作废的 `message_id`（永久） |
| `hikari:seq` | STRING | 自增计数器，供 `INCR` 生成 `id` 字段 |
| `hikari:lastrun:{group_id}` | STRING | 这个群上次成功扫描的窗口终点（Unix 秒），逐群独立；既用于重启补跑判断，也是下一次扫描窗口的起点 |

## 联调 Runbook

首次针对真实 NapCat + Redis 联调时按这个顺序走。这里原本有四处 NapCat 线上行为仓库内验证不了，
2026-08-15 首次生产运行 + 两次针对真实 NapCat 的手工探测（一次对 `get_group_msg_history` 用
`count=5` 分别探测不带锚点 / `reverse_order=false` / `reverse_order=true` 三种调用，一次直接对
`get_msg` 探测）已经把全部四条坐实，详见下面小节；仍按下面的方法核对，出问题时照着改代码。

### 步骤

1. 复制 `.env.example` 为 `.env`，填真实值，把 `SCAN_TIME` 设成两三分钟后的时刻。
2. `set -a && source .env && set +a && ./zig-out/bin/hikari`
3. 在目标群里造数据：
   - 被观察者发一句话，给它贴 ✨ 表情回应（路径 1）；
   - 另一个人引用被观察者的另一句话，只回 `✨`（路径 2）；
   - 管理员发 `✨ 手动补录测试`（路径 3）；
   - 管理员引用其中一条候选，只回 `💦`（作废）。
4. 等定时触发，确认每个群收到**一条**合并转发（聊天记录）消息，点开后是七行（横幅三行 +
   `Processing...` + `Will process N messages.` + `Added X messages, skipped Y messages.` +
   `Successfully in {d}s.`，秒数是这个群自己这一轮扫描花的时长，不是整个运行的总时长）且计数
   合理；这七行不再是七条独立消息，是 `send_group_forward_msg` 打包发的一条消息里的七个 node，
   发送时机是这个群扫描全部跑完之后，不是边扫边发——扫描本身仍然要跑 1–2 分钟，这段时间群里
   不会有任何提示。
   这一轮出过岔子时最后一行不是 `Successfully in {d}s.` 而是 `Failed: ...`（不带耗时——一次
   失败跑的耗时不提供任何信息），原因串里会分别列出作废失败、入库失败、群归属信息拿不到各多少
   条——三者任一发生都会压掉 `Successfully in {d}s.`，也会跳过**这个群自己**的
   `hikari:lastrun:{group_id}` 更新，好让它下一次扫描（不管是下一个
   正常触发时刻还是重启补跑）的窗口起点仍然停在上一次成功的位置、自动把这一轮漏掉的都补上；
   `hikari:lastrun:{group_id}` 是逐群独立的键，不受同一轮里其他群成不成功影响——一个群
   失败不会被跑成功的兄弟群掩盖。扫描中途真的崩溃（不是"落库遇到几条失败"那种软失败）时，
   这个群仍然会收到一条合并转发，只是行数可能少于七行（`Will process` / `Added, skipped`
   这两行要等对应阶段跑到才会有）、最后一行是 `Failed: <原因>`——不会因为崩溃就什么都不发。
   合并转发里每个 node 的头像是机器人自己的 QQ（`runOnce` 每轮调一次 `get_login_info` 取到，
   取不到时退回 `OBSERVED_QQ` 并打警告，纯观感问题，不影响这一轮判定成不成功）。
5. 用 curl 核对 HTTP 接口：
   ```bash
   curl 'http://127.0.0.1:8080/'
   curl 'http://127.0.0.1:8080/?encode=text'
   curl 'http://127.0.0.1:8080/?min_length=1&max_length=5'
   curl -i 'http://127.0.0.1:8080/?charset=gbk'   # 应为 400
   ```
6. 记录联调结果备查。

### 五个 NapCat 线上假设：全部已被坐实

核对全靠进程自己的 stderr 日志。**按上面推荐的 `-Doptimize=ReleaseSafe` 构建时 `std.log` 的默认
级别恰好是 `info`**，下面用到的 `info` 行开箱即可见；用 `ReleaseFast` / `ReleaseSmall` 构建则只剩
`err`，这些行会全部消失，联调期间不要用那两档。

1. **翻页锚点吃的确实是 `message_id`，但方向必须是 `reverse_order: true`——已确认，且已修复。**
   本项目把上一页最老一条的 `message_id` 作为下一页 `get_group_msg_history` 的 `message_seq`
   入参，这部分假设成立：手工探测证实 `get_msg` 返回的 `id`/`seq` 是同一个值。但首次生产运行的
   日志暴露了另一个问题——第 1 页和第 2 页完全相同：

   ```
   info: group ...: history page 0: 194 message(s); oldest message_id=1809600761 time=1786785467; newest message_id=1344602200 time=1786790521
   info: group ...: history page 1: 194 message(s); oldest message_id=1809600761 time=1786785467; newest message_id=1344602200 time=1786790521
   warning: group ...: history window NOT fully covered — stopped after 2 page(s) ... reason: pagination anchor stopped advancing (NapCat returned the same page again).
   ```

   针对真实 NapCat 用 `count=5` 手工探测（不带锚点 / 带锚点 `reverse_order=false` / 带锚点
   `reverse_order=true`）确认了原因：`reverse_order` 的语义是"从锚点朝哪个方向走"，不是"结果要不要
   倒序"——`reverse_order: false` 是"从锚点往新（更晚）的方向走"，拿上一页最老一条的 `message_id`
   当锚点配 `false` 传给 NapCat，等于让 NapCat 把上一页原样再吐一遍，翻页永远卡在窗口最新的那一段。
   往回（更早）翻必须传 `reverse_order: true`。`src/scan/runner.zig` 的 `fetchPage` 已经改过来：
   带锚点的分支现在传 `reverse_order: true`；没有锚点的首页调用仍是 `reverse_order: false`——NapCat
   对不带 `message_seq` 的请求走的是 `getAioFirstViewLatestMsgs`，不看这个字段，不受这次修复影响。
   `grep 'history page'` 仍然是核对相邻两页有没有正常往更早的方向推进的办法：现在应看到相邻两页
   `time` 依次变旧、首尾相接，不应再出现两页完全相同。

2. **`message_seq` 边界是闭区间——已确认。** 手工探测证实：带锚点、`reverse_order: true` 时，
   返回的一页里锚点消息本身会作为**最新**的一条出现（其余是比它更早的消息）。后果：每一页（除第
   一页外）都会把上一页最老的一条重复收进 `pool`，`Will process N messages.` 会比实际值多报最多
   「页数 − 1」条。这不会污染数据——`rules.appendCandidate` 按 `message_id` 去重会挡住重复——是
   刻意接受的行为，**不需要**在 `fetchPage` / 翻页循环里另外去重，看日志时知道这个数会偏高即可。

3. **`get_msg` 是否返回顶层 `user_id`——已确认，针对生产 NapCat 手工探测坐实。** `onebot.parseMessage`
   解析 `get_msg` 的返回时，如果找不到顶层 `user_id` 会直接返回 null，导致所有需要单独 `get_msg`
   才能解析出发送者的引用目标（窗口外、走 LRU 反查那条路，即路径 2 的跨窗口情形）都无法解析，日志
   会看到大量「unresolvable」警告，且与正常的 LRU 淘汰情形从日志上无法区分。首次生产运行没有触发
   这条路径（窗口内的引用都能直接从池子里解出发送者），因此另外对真实 NapCat 的 `get_msg` 做了一次
   直接探测：对一条真实群消息调用 `get_msg`，返回的顶层 key 为

   ```
   ['emoji_likes_list', 'font', 'group_id', 'group_name', 'message', 'message_format',
    'message_id', 'message_seq', 'message_type', 'post_type', 'raw_message', 'real_id',
    'real_seq', 'self_id', 'sender', 'sub_type', 'time', 'user_id']
   ```

   顶层 `user_id`（本次探测中为 `3303289608`）与 `sender.user_id` 一致，`message_id` / `time` /
   `message_type` / `emoji_likes_list` 也均在顶层出现。假设成立：跨窗口的路径 2 反查可以正常工作。

4. **✨ 的 `emoji_id` 是 `"10024"`——已确认，由生产数据坐实。** 定义在 `src/napcat.zig` 的
   `star_emoji_id` 常量，全仓库只这一处。首次生产运行通过 ✨ 收到了 6 条真实语录（`10024` 匹配
   成功），同一轮里另有一条消息被贴了 😰，日志打出

   ```
   none matched star_emoji_id=10024: 128560x1
   ```

   128560 = 0x1F630（😰 的 Unicode 码点），证实 NapCat 把 emoji 表情回应上报为十进制码点，
   `star_emoji_id = "10024"`（✨ = U+2728 的十进制形式）是对的，不需要改。核对方法（供以后接入
   新群/新环境时复查）：找一条被观察者发的消息贴上 ✨，等这一轮扫描跑过去，确认没有打出
   `none matched star_emoji_id=10024: ...` 这一行；若打出了，冒号后面是这条消息上实际出现过的
   全部 `emoji_id`（`id×次数`），✨ 的真实 id 会在那串里。

5. **`send_group_forward_msg` 的请求体结构——已确认，针对生产 NapCat 手工探测坐实。** 运行日志
   从逐条 `send_group_msg` 改成合并转发（见 7 节）之前，针对真实 NapCat 手工发过一次
   `send_group_forward_msg`：

   ```json
   {"group_id": 1039716984, "messages": [
     {"type":"node","data":{"user_id":"2131597992","nickname":"Hikari","content":[{"type":"text","data":{"text":"Hikari!"}}]}},
     {"type":"node","data":{"user_id":"2131597992","nickname":"Hikari","content":[{"type":"text","data":{"text":"Successfully."}}]}}
   ]}
   ```

   NapCat 回了 `{"status":"ok","retcode":0,"data":{"message_id":242408478,"res_id":"...","forward_id":"..."}}`，
   确认 `user_id` 要传字符串、`node → data → content[]` 的三层嵌套、以及每个 node 会在合并转发里
   独立成一行。（这次探测比第七行加上耗时那次改动更早，探测记录里的 `"Successfully."` 是当时
   的原文，不代表现在这一行的实际文案——现在是 `"Successfully in {d}s."`；这里保留原始探测
   记录不做事后改写，验证的是请求体结构，不是文案本身。）`get_login_info` 取机器人自己 QQ 的
   返回形状（`data.user_id` 是数字）沿用 OneBot 11
   标准接口，未单独针对这次改动重新探测。

## 本仓库中实际验证过的部分

- `zig build` 产出二进制、`zig build test` 201/201 通过。
- 不设任何环境变量运行，进程以非零状态退出并在日志里点名具体缺失哪个环境变量。
- 故意设置非法值（如 `SCAN_TIME=25:00`）运行，进程点名的是那个变量本身，不是别的。
- 有本地 Redis 可用时，用合法 Redis 配置 + 不存在的 NapCat 地址运行，HTTP 服务仍能正常启动；对空库
  发请求返回 404 JSON 错误体。

**没有验证过的部分**：需要真实 NapCat 实例、真实 QQ 账号与群权限的联调（上面 Runbook 的步骤 3、4，
即在真实群里造数据、亲眼确认发出的合并转发消息与计数）——这需要人工执行，见上面的 Runbook。「五个
NapCat 线上假设」小节列出的五条均已被坐实，不再属于这里的未验证部分。合并转发这条改动本身只做到了单元测试
级别（起假 HTTP server 验证 `send_group_forward_msg`/`get_login_info` 请求体与 runOnce 的调用
时序，见 `src/scan/runner.zig`），还没有对着真实群跑过一轮、亲眼确认收到的是一条折叠起来的合并
转发消息而不是七条独立消息。
