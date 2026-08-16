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
| 4. 🔥 链式收录 | 被观察者连续几条消息（相邻不超过 3 条消息间隔）同时带 ✨ 和 🔥 | 按时间顺序拼成一条，用空格连接 |

优先级：**路径 4 > 路径 3 > 路径 1**。路径 3 优先于路径 1，因为它是更具体的「作者本人手动指定」
信号；路径 4 优先于路径 3 和路径 1，因为它是一个分组信号——「这几条消息是同一句话」这件事，没有
别的路径能表达。

**💦 作废**：管理员引用一条消息、除引用外只回 `💦`，且被引用的消息符合路径 1 或路径 3，就把对应
语录从 Redis 删除并永久 tombstone——之后任何一次扫描再次看到这条消息都不会重新入库。💦 引用到
🔥 链上任意一个成员都会作废整条链，链的全部成员都会被 tombstone，不只是被引用的那一条。

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

```bash
./zig-out/bin/hikari run
./zig-out/bin/hikari import seed.txt
```

## HTTP 接口

**`GET /`** —— 返回随机一条语录，参数遵循 Hitokoto 规范：

| 参数 | 支持情况 |
|---|---|
| `encode` | `json`（默认）/ `text` / `js` |
| `min_length` / `max_length` | 支持，按语录长度（UTF-8 码点数）过滤 |
| `callback` | 支持，存在时输出 JSONP：`{callback}({json})`，回调名只接受 `[A-Za-z0-9_$.]` |
| `select` | 支持，`encode=js` 时的 DOM 选择器，默认 `.hitokoto` |
| `charset` | 仅支持 `utf-8`（大小写不敏感），其他值返回 400——本库没有内嵌 GBK 码表 |
| `c` | 接受但忽略——全库只有一个类型，`type` 恒为 `"g"` |

错误：库空 / 长度过滤后无结果 → 404；参数非法（`charset` 非 utf-8、`min_length` > `max_length`、
数字解析失败、`callback` 非法）→ 400；方法非 `GET` → 405；Redis 不可用 → 500。均为 JSON 错误体。

**`GET /extra/all`** 与 **`GET /extra/batch/:count`** 是超出 Hitokoto 协议范围的自定义扩展，落在
`/extra/` 前缀下，不认 `/` 的那套查询参数，响应固定是 JSON 数组：

| 端点 | 行为 |
|---|---|
| `GET /extra/all` | 返回全部语录，无上限 |
| `GET /extra/batch/:count` | 随机返回 `count` 条语录，允许重复；`count` 须为 1–1000 的整数，否则 400 |

库空时这两个端点返回 `[]` + 200，不是 404——空数组本身就是一个成功的答案，跟 `/` 那种「没有可服务
的单条语录」是不同的语义。

```bash
curl 'http://127.0.0.1:8080/'
curl 'http://127.0.0.1:8080/?encode=text'
curl 'http://127.0.0.1:8080/extra/all'
curl 'http://127.0.0.1:8080/extra/batch/5'
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
zig build test          # 单元测试，287 个
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
