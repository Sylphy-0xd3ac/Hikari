# Hikari

Hikari 是一个用 Zig 写的常驻进程：每天定时扫描指定 QQ 群的历史消息，把群友认可的话收录成语录存进
Redis，再通过一个与 [Hitokoto 一言 API](https://developer.hitokoto.cn/sentence/) 兼容的 HTTP
接口随机吐出来。上游依赖 [NapCatQQ](https://github.com/NapNeko/NapCatQQ) 的 HTTP 接口（OneBot 11 +
NapCat 扩展）。

完整设计（NapCat 接口细节、message_id 的哈希性质与 LRU 反查限制、扫描窗口与翻页算法、字段映射等）见
[`docs/superpowers/specs/2026-08-15-hikari-design.md`](docs/superpowers/specs/2026-08-15-hikari-design.md)。
本文档只覆盖运行一个实例所需的信息。

## 三条收录路径与 💦 作废规则

每天 `SCAN_TIME` 触发一次，扫描 `[今天 SCAN_TIME - 24h, 今天 SCAN_TIME)` 窗口内的消息。命中以下任一
路径即成为候选：

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
| `OBSERVED_QQ` | 是 | 被观察的 QQ 号 | `10001` |
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

每条连接都能自愈：遇到传输层失败（socket 断开、读写失败、协议错乱）会自动重连并把这条命令**重试一次**，
第二次仍失败才把错误交出去。所以 Redis 重启、空闲超时、NAT 连接跟踪过期都不需要重启 Hikari。
扫描线程一天里有约 23.99 小时是闲着的，这条路径实际上每天都会被走到。重连时会重新执行 `AUTH` / `SELECT`，
并整个丢弃读缓冲——半条没读完的回复留在缓冲里会让之后每一条回复都错位一格，那是静默的数据错误。
代价是一条已经被服务端执行过的命令可能被重放一次；本仓库里唯一非幂等的命令是 `INCR hikari:seq`，
重放只是白烧一个 id（`id` 允许有空洞）。

调度循环每一轮都会重新计算一次本地时区相对 UTC 的偏移（`scheduler.localOffsetSeconds`），而不是在循环
外算一次复用——夏令时切换会改变这个偏移，进程一次起来常常要跑几个月，缓存旧偏移会导致跨越 DST 边界之后
触发时刻整体偏移一小时。进程重启时会额外判断「今天该跑的时刻是否已经过去但还没跑」（`missedRun`），
逐群判断（每个群各自的 `hikari:lastrun:{group_id}`，见下方键结构）：只要有一个群漏跑，就立即用最早的
那个漏跑时刻补跑一次（补跑会重新扫全部群，已经跟上的群只是幂等地重扫一遍已处理过的窗口，无害）；
某个群首次启动没有基线（它自己的 `hikari:lastrun:{group_id}` 不存在），这个群的补跑判断直接跳过，
等下一个正常触发时刻。

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
| `hikari:lastrun:{group_id}` | STRING | 这个群上次成功扫描的窗口终点（Unix 秒），逐群独立，用于重启补跑判断 |

## 联调 Runbook

首次针对真实 NapCat + Redis 联调时按这个顺序走。这里有四处 NapCat 线上行为，仓库内没有真实环境验证
不了，第一次实跑正是检验它们的时机——按下面的方法逐一核对，出问题时照着改代码。

### 步骤

1. 复制 `.env.example` 为 `.env`，填真实值，把 `SCAN_TIME` 设成两三分钟后的时刻。
2. `set -a && source .env && set +a && ./zig-out/bin/hikari`
3. 在目标群里造数据：
   - 被观察者发一句话，给它贴 ✨ 表情回应（路径 1）；
   - 另一个人引用被观察者的另一句话，只回 `✨`（路径 2）；
   - 管理员发 `✨ 手动补录测试`（路径 3）；
   - 管理员引用其中一条候选，只回 `💦`（作废）。
4. 等定时触发，确认群里收到七行运行日志（横幅三行 + `Processing...` + `Will process N messages.` +
   `Added X messages, skipped Y messages.` + `Successfully.`，每群一份）且计数合理。
   这一轮出过岔子时最后一行不是 `Successfully.` 而是 `Failed: ...`，原因串里会分别列出
   作废失败、入库失败、群归属信息拿不到各多少条——三者任一发生都会压掉 `Successfully.`，
   也会跳过**这个群自己**的 `hikari:lastrun:{group_id}` 更新，好让下一次启动补跑这一个群；
   `hikari:lastrun:{group_id}` 是逐群独立的键，不受同一轮里其他群成不成功影响——一个群
   失败不会被跑成功的兄弟群掩盖。
5. 用 curl 核对 HTTP 接口：
   ```bash
   curl 'http://127.0.0.1:8080/'
   curl 'http://127.0.0.1:8080/?encode=text'
   curl 'http://127.0.0.1:8080/?min_length=1&max_length=5'
   curl -i 'http://127.0.0.1:8080/?charset=gbk'   # 应为 400
   ```
6. 记录联调结果，尤其是第 4 点里 ✨ 的 `emoji_id` 是否真的是 `10024`。

### 四个仓库内验证不了、只能靠实跑核对的 NapCat 线上假设

核对全靠进程自己的 stderr 日志。**按上面推荐的 `-Doptimize=ReleaseSafe` 构建时 `std.log` 的默认
级别恰好是 `info`**，下面用到的 `info` 行开箱即可见；用 `ReleaseFast` / `ReleaseSmall` 构建则只剩
`err`，这些行会全部消失，联调期间不要用那两档。

1. **翻页用的是 `message_id` 还是独立序列。** 本项目把上一页最老一条的 `message_id` 作为下一页
   `get_group_msg_history` 的 `message_seq` 入参。如果 NapCat 把 `message_seq` 当成一个跟
   `message_id` 无关的独立序号，翻页会在第二页就跑偏。核对方法：扫描时每翻一页都会打一行

   ```
   group 123456: history page 0: 200 message(s); oldest message_id=... time=...; newest message_id=... time=...
   ```

   `grep 'history page'` 拿到全部页，看相邻两页的 `time` 是否首尾相接、没有跳跃或重复大段。
   另外，如果翻页没能一直翻到窗口起点就停了，会额外打一行 `history window NOT fully covered`
   的**警告**，里面带着翻了几页、共多少条、以及停下来的具体原因（翻到群历史开头 / 响应不是对象 /
   一条都没解析出来 / 翻页锚点不再前进 / 200 页保护耗尽）。看到这行就说明这一轮只覆盖了窗口的
   一部分，且漏掉的那一段不会被重扫——**包括漏掉的 💦 作废指令**，它只会被看到一次。

2. **`message_seq` 边界是否是闭区间。** 如果是，每一页（除第一页外）都会把上一页最后一条消息重复
   收进来，`Will process N messages.` 会比实际值多报最多「页数 − 1」条。这不会污染数据（`message_id`
   去重会挡住重复），但看日志容易以为哪里错了。核对方法：同样看上面那些 `history page` 行，
   相邻两页的 `oldest message_id` 与 `newest message_id` 有没有重叠。

3. **`get_msg` 是否返回顶层 `user_id`。** `onebot.parseMessage` 解析 `get_msg` 的返回时，如果找不到
   顶层 `user_id` 会直接返回 null，导致所有需要单独 `get_msg` 才能解析出发送者的引用目标（窗口外、
   走 LRU 反查那条路）都无法解析，日志会看到大量「unresolvable」警告。核对方法：手动引用一条窗口外
   的旧消息触发这条路径，看警告是否符合预期（应该是偶发，不应该是全部）。

4. **✨ 的 `emoji_id` 是否真的是 `"10024"`。** 定义在 `src/napcat.zig` 的 `star_emoji_id` 常量，全仓库
   只这一处。**如果这个值不对，扫描器会一条都收不到，而且现象跟"今天真的没人贴 ✨"完全一样，不会报任何
   错误。** 核对方法：找一条被观察者发的消息贴上 ✨，等这一轮扫描跑过去。只要这条消息上有表情回应而
   一个都没匹配上 `star_emoji_id`，进程就会打一行

   ```
   group 123456: message 78901 carries emoji reactions but none matched star_emoji_id=10024: 128x2, 9999x1
   ```

   冒号后面是这条消息上**实际出现过的全部** `emoji_id`（`id×次数`）。贴了 ✨ 却看到这行，说明 ✨ 的真实
   id 就在那串里；把 `src/napcat.zig` 的 `star_emoji_id` 改成它即可——该常量同时驱动字符串和数值两种
   比较，改这一处就够。反过来，贴了 ✨ 而这行**没出现**，说明 `10024` 匹配上了，假设成立。
   （也可以直接对 NapCat HTTP 接口手工发一次 `get_msg` 读 `emoji_likes_list` 交叉验证。）

## 本仓库中实际验证过的部分

- `zig build` 产出二进制、`zig build test` 167/167 通过。
- 不设任何环境变量运行，进程以非零状态退出并在日志里点名具体缺失哪个环境变量。
- 故意设置非法值（如 `SCAN_TIME=25:00`）运行，进程点名的是那个变量本身，不是别的。
- 有本地 Redis 可用时，用合法 Redis 配置 + 不存在的 NapCat 地址运行，HTTP 服务仍能正常启动；对空库
  发请求返回 404 JSON 错误体。

**没有验证过的部分**：需要真实 NapCat 实例、真实 QQ 账号与群权限的联调（上面 Runbook 的步骤 3、4、
以及四个 NapCat 线上假设）——这需要人工执行，见上面的 Runbook。
