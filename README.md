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

调度循环每一轮都会重新计算一次本地时区相对 UTC 的偏移（`scheduler.localOffsetSeconds`），而不是在循环
外算一次复用——夏令时切换会改变这个偏移，进程一次起来常常要跑几个月，缓存旧偏移会导致跨越 DST 边界之后
触发时刻整体偏移一小时。进程重启时会额外判断「今天该跑的时刻是否已经过去但还没跑」（`missedRun`），是
则立即补跑一次；首次启动没有基线（`hikari:lastrun` 不存在），补跑判断直接跳过，等下一个正常触发时刻。

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
| `hikari:lastrun` | STRING | 上次扫描窗口终点的 Unix 秒，用于重启补跑判断 |

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
   `Added/skipped` + 每群一份）且计数合理。
5. 用 curl 核对 HTTP 接口：
   ```bash
   curl 'http://127.0.0.1:8080/'
   curl 'http://127.0.0.1:8080/?encode=text'
   curl 'http://127.0.0.1:8080/?min_length=1&max_length=5'
   curl -i 'http://127.0.0.1:8080/?charset=gbk'   # 应为 400
   ```
6. 记录联调结果，尤其是第 4 点里 ✨ 的 `emoji_id` 是否真的是 `10024`。

### 四个仓库内验证不了、只能靠实跑核对的 NapCat 线上假设

1. **翻页用的是 `message_id` 还是独立序列。** 本项目把上一页最老一条的 `message_id` 作为下一页
   `get_group_msg_history` 的 `message_seq` 入参。如果 NapCat 把 `message_seq` 当成一个跟
   `message_id` 无关的独立序号，翻页会在第二页就跑偏。核对方法：观察日志里连续两页返回的消息是否
   时间连续、没有跳跃或重复大段。

2. **`message_seq` 边界是否是闭区间。** 如果是，每一页（除第一页外）都会把上一页最后一条消息重复
   收进来，`Will process N messages.` 会比实际值多报最多「页数 − 1」条。这不会污染数据（`message_id`
   去重会挡住重复），但看日志容易以为哪里错了。核对方法：把每页首尾消息的 `message_id` 记下来，看
   相邻两页有没有重叠。

3. **`get_msg` 是否返回顶层 `user_id`。** `onebot.parseMessage` 解析 `get_msg` 的返回时，如果找不到
   顶层 `user_id` 会直接返回 null，导致所有需要单独 `get_msg` 才能解析出发送者的引用目标（窗口外、
   走 LRU 反查那条路）都无法解析，日志会看到大量「unresolvable」警告。核对方法：手动引用一条窗口外
   的旧消息触发这条路径，看警告是否符合预期（应该是偶发，不应该是全部）。

4. **✨ 的 `emoji_id` 是否真的是 `"10024"`。** 定义在 `src/napcat.zig` 的 `star_emoji_id` 常量，全仓库
   只这一处。**如果这个值不对，扫描器会一条都收不到，而且现象跟"今天真的没人贴 ✨"完全一样，不会报任何
   错误。** 核对方法：找一条消息贴上 ✨，手动调用 `get_msg`（可以直接对 NapCat HTTP 接口发请求，也可以
   看 Hikari 进程处理这条消息时打的日志），读 `emoji_likes_list` 里实际的 `emoji_id` 字段值。如果跟
   `"10024"` 不一致，把 `src/napcat.zig` 里的 `star_emoji_id` 改成实际值——它同时驱动字符串和数值两种
   比较，改这一处即可。

## 本仓库中实际验证过的部分

- `zig build` 产出二进制、`zig build test` 146/146 通过。
- 不设任何环境变量运行，进程以非零状态退出并在日志里点名具体缺失哪个环境变量。
- 故意设置非法值（如 `SCAN_TIME=25:00`）运行，进程点名的是那个变量本身，不是别的。
- 有本地 Redis 可用时，用合法 Redis 配置 + 不存在的 NapCat 地址运行，HTTP 服务仍能正常启动；对空库
  发请求返回 404 JSON 错误体。

**没有验证过的部分**：需要真实 NapCat 实例、真实 QQ 账号与群权限的联调（上面 Runbook 的步骤 3、4、
以及四个 NapCat 线上假设）——这需要人工执行，见上面的 Runbook。
