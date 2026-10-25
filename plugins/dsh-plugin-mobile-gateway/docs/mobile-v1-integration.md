# `/mobile/v1`（原 ds-bot-mobile-bridge 协议）集成说明

本插件在原有移动网关协议（`/ws/mobile`，完整会话/工作区投影）之外，**同时**提供
ds-bot-mobile-bridge 的 `/mobile/v1` 协议（团队投影 / 配对 / 动作 / WS 订阅），
两条协议共用一个端口、一套进程与一条公网入口。

移植自 `MuQY1818/ds-bot-mobile-app` 的 `bridge/`（v0.0.6），协议形状与
`dsh-mobile` 设计文档 v1.2 §2 逐字节兼容：移动端 App 的 bridge 客户端无需改动。

### 挂载位置（手机到底走哪个口）

同一组路由**同时**注册到三处监听器，缺一即公网 404：

| 监听器 | 典型端口 | 谁用 |
| --- | --- | --- |
| 宿主 webServer | 127.0.0.1:<webPort> | 本机调试、diff 脚本、面板（loopback-only） |
| LAN 监听器（`lanPort`） | 3081 | 手机同一局域网直连 |
| 隧道回环监听器（`cloudflarePort`） | 3082 | cloudflared 后端 → 公网 Quick/Named Tunnel |

路由表在 apply 早期同步注册、监听器在请求期查表（`lib/extra-routes.mjs`，前缀 longest-prefix-wins）。
`/mgw/*` 管理面**只**在宿主 loopback 上，LAN/隧道一律 404，公网够不到。

### 普通会话行（`kind: "session"`，U4）

`/conversations` 与 `/state.sessions` 会带上**非团队的普通会话**，供 App 顶部「团队 / 会话」分段使用：

| 字段 | 说明 |
| --- | --- |
| `id` / `sessionId` | 会话 id（点入即用它开 chat） |
| `kind` | 固定 `"session"` |
| `name` | 会话标题；与 bot/room 行走同一套 redaction（缺失时为「未命名会话」） |
| `lastActiveAt` | 最近活跃时间（宿主 `updatedAt`），跨行排序用 |
| `workspace` | 工作区名（cwd 的末段，**不下发完整路径**，同样过 redaction） |
| `busy` | 会话正在运行（可选） |

规则：已作为 bot/room 出现的会话（含 `parts`）不重复出现；子代理会话（`origin: "subagent"`）不上主列表；
会话列表取不到时降级为空、绝不影响团队视图。能力面：`/info.capabilities.sessions === true` 才代表可用。
数据源是插件内已有的 `api.sessions.list()`（与旧网关会话列表同源），**手机端不因此多一套凭证**。

### 一次配对发两套凭证（U5）

面板批准那一刻，插件用网关同一个 devices registry 顺带签发一条**网关设备凭证**，
随 session 一起下发（可选字段，老客户端忽略即可）：

```json
{
  "accessToken": "…", "refreshToken": "…", "deviceId": "…", "serverId": "…", "expiresAt": 0,
  "gateway": { "deviceId": "…", "token": "…", "wsPath": "/ws/mobile" }
}
```

用途：App 用这一条凭证就能同时连 **bridge 协议（团队/Bot）** 与 **旧网关协议（原版会话列表 + 富聊天窗口）**，
不再需要第二次配对。约定：

- 只在**批准**时签发一次；重复 complete 走缓存，不会重复签发
- 签发失败时字段缺省（`null`/缺失），**不影响 bridge 配对本身**
- 安全面：批准 = 授予该设备访问桌面全部会话（面板已写明）。要收紧时再加「只授团队／授全部会话」的开关
- 与网关 WS 的鉴权共用：`Authorization: Bearer <token>`（或既有 query 参数策略）
- **对称**：反向也成立——走网关自己的配对流程（扫码/配对码）成功时，插件会顺带签发一条
  mobile-v1 session，放在升级后第一帧 `{"kind":"paired", …}` 的可选字段 `bridgeSession` 里。
  两条配对路径任选其一，都是一次配对拿两套凭证；签发失败只缺字段，不影响网关配对。
  注意：同名设备重复配对会**轮换**该设备的 token（旧 session 立即失效），与网关自身的设备轮换语义一致。

### 手机端配对入口（B3：只剩一条路）

App 侧把「粘贴配对资料 JSON」这条路**删掉**了（面板出 JSON → 手机粘贴那套退役）。现在的配对入口只有：

| 入口 | 内容 | 说明 |
| --- | --- | --- |
| 扫码（主） | 面板「生成二维码」出的 **v2 Base64URL** 配对串 | `BASE64URL({"v":2,"url":…,"code":…,"serverId":…,"expiresAt":…})`，格式未变，老 App 也能读 |
| 手动输入（辅） | 服务器地址 `https://…` + 配对码 | 地址可以整段粘贴（含路径会被归一化到根 origin），码 5 分钟有效 |

为什么能只留一条：一次配对就把**网关设备凭证**（`gateway` 字段，给旧网关 WS / 原版会话与聊天）
和 **bridge 会话**（`bridgeSession` 字段，给 Bot 团队）一起发下去，App 不需要第二条路径拿第二套凭证。
配对串、二维码、面板展示、校验口径因此都不再分叉——这也是「两次改错都在配对那一段」之后收的口。

> 兼容性：`bridgeSession` 仍是**可选**字段；不带的旧宿主上，App 的 Bot 页会显示未就绪并提供
> 「扫码/手动重新配对」，不会再退回到粘贴 JSON。

## 端点（前缀 `/mobile/v1`）

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/mobile/v1/info` | 免认证：protocolVersion/serverId/name/capabilities/compatibility |
| POST | `/mobile/v1/pairings` | `{code, deviceName}` → `{claimToken, requestId, status}` |
| POST | `/mobile/v1/pairings/complete` | `{claimToken}` → pending 或 Session（含可选的 `gateway:{deviceId,token,wsPath}`，见下） |
| POST | `/mobile/v1/auth/refresh` | `{refreshToken}` → 新 Session |
| GET | `/mobile/v1/state` | TeamState（bots/rooms/models/mainBotIds/work…） |
| GET | `/mobile/v1/conversations` | 会话列表（bots+群聊） |
| GET | `/mobile/v1/conversations/{id}/messages?limit&cursor` | 历史分页 |
| GET | `/mobile/v1/conversations/{id}/target` | 会话目标与 revision |
| POST | `/mobile/v1/conversations/{id}/cancel` | 停止生成（能力允许时） |
| POST | `/mobile/v1/submissions` | `{conversationId, sessionId, requestId, text}` 幂等发送 |
| GET | `/mobile/v1/submissions/{requestId}` | 回执恢复 |
| POST | `/mobile/v1/actions` | `{endpoint, payload}` 动作白名单 |
| GET | `/mobile/v1/devices` | 设备列表 + currentDeviceId |
| DELETE | `/mobile/v1/devices/{id}` | 撤销设备 |
| POST | `/mobile/v1/read-markers` | `{conversationId, seq}` 按设备已读 |
| GET | `/mobile/v1/team` | 团队投影**快照**帧（与 `/mobile/v1/team` WS 同源，见下节） |
| GET | `/mobile/v1/cards` | 卡片**快照**帧（同上） |
| WS | `/mobile/v1/events` | 首帧 `{"type":"auth",token,conversationId,after?,capabilities?}`，事件 reset/delta/message/status/error/ready |
| WS | `/mobile/v1/team` | 首帧 `{"type":"auth",token,capabilities?}`（**不需要** conversationId）；`ready` → 团队快照 + 卡片快照 → 增量 |

错误信封、限流、WS 关闭码与 bridge 0.0.6 一致（见设计文档 §2.1/§2.7/§2.9）。

## 团队投影帧与卡片帧（B1/B2）

两条**新增**的只读流，专门服务手机团队页。与按会话的 `/events` 分开：后者必须带
`conversationId` 且受 redacted transcript 能力门控，而团队名册在没有会话正文能力时也得能用。

### 数据来源（ds-bot 侧）

- 团队：`dsBotTeam`（契约 [`ds-bot/docs/roster-publish-v1.md`](https://github.com/Fei2411/DeepSeek-Bot)，v2 冻结）
- 卡片：`dsBotCards`（同契约 §8，形状：`{ v, instanceId, seq(), snapshot(): {seq, at, cards[]}, subscribe(fn) }`）

网关用 `ctx.get('dsBotTeam')` / `ctx.get('dsBotCards')`（免 inject 的反射读取，apply 时可能还没就绪，
因此**延后解析**、不固化 null）。两个服务都**可选**：

| 服务 | 缺席时的行为 |
| --- | --- |
| `dsBotTeam` | 降级：用 `/state` 投影出名册（名字/角色/成员/置顶/**会话 updatedAt**），帧上 `degraded: true`。**`activity` 直接省略**（契约枚举里没有 unknown，写 `idle` 就等于谎报「全部 Bot 空闲」，联调时最难分辨）；`instructions`/`createdAt`/`notice` 等拿不到的静态值同样省略，不填占位值 |
| `dsBotCards` | 降级：用团队帧的 `pending`（只有类型与时间，没有正文）造**占位卡**，`placeholder: true`；正文仍需走网关既有的 `question-requested` 通道 |

端点、能力位：`GET /info` 的 `capabilities` 增加：

| 字段 | 含义 |
|---|---|
| `team` / `cards` | 该流是否存在（路由已挂） |
| `teamDegraded` / `cardsDegraded` | **源服务是否缺席**（`dsBotTeam` / `dsBotCards` 活探，**与有无订阅者无关**）→ 健康判读看这个 |
| `teamServing` / `cardsServing` | 此刻是否真的在供实时帧（无订阅者时为 false，属正常态） |
| `maxFrameBytes` | 单帧（或单块）上限，字节；当前 **512 KiB** |
| `maxReassembledBytes` | 单条分块流重组后的上限，字节；当前 **4 MiB** |
| `maxStreamsPerConnection` | 同一连接允许同时存在的分块流数；当前 **2** |
| `heartbeatIntervalSeconds` | 客户端发应用层 ping 的间隔（秒）；当前 **25** |
| `heartbeatTimeoutSeconds` | 超过这么久没收到任何帧（含 pong）就判死重连（秒）；当前 **75** |
| `syncResume` | 是否支持断线补增量（`sync-resume-v1`） |

### 心跳与断线补增量（`sync-resume-v1`）

**心跳**：客户端按 `heartbeatIntervalSeconds` 发 `{type:'ping'}`，网关回 `{type:'pong', at}`（`at` 是网关时间戳，可顺带校时）。
超过 `heartbeatTimeoutSeconds` 没收到任何帧 → 客户端判死、断开重连（不做原地切路径）。心跳是控制面帧：**不占 seq、不改变状态、不触发快照**。
网关侧另有 WS 层 15s ping/pong 清理僵死连接，两者互补（一个发现 TCP 半开，一个清服务端僵尸）。
认证后客户端发来的 `pong` 会被**静默忽略**（无副作用、不占 seq、不回帧）：`pong` 只由网关发、客户端收；服务端不依赖客户端的 pong 判活，靠的是 WS 层 ping 的 pong 应答。

**补增量**：团队流常驻订阅 + 环形留窗，**10,000 帧 / 15 分钟 / 8MB，先到者为准**（无手机连着时也保持上游订阅，
否则断线期间的事件没人记录，补增量必缺口）。留窗只记已脱敏的 `delta`；快照、`avatar` 旁路帧、`order` 帧不参与回放。

两种请求方式：

1. **零往返（推荐）**：auth 首帧带 `resume`——
   `{type:'auth', token, resume:{instanceId:'…', afterSeq:8271, maxDeltas?:200}}`。
   命中留窗 → 直接回 delta 序列（不整帧快照）；命中不了 → 回错误帧 + 新快照（同一连接自愈）。
2. **连接中重试**：`{type:'sync.from', instanceId, afterSeq, maxDeltas?}`，语义同上；5s 内重复请求回 `SYNC_RATE_LIMITED`。

回放结束必发 `{type:'sync.done', instanceId, seq, reason}`（`reason`：`resume`/`sync.from`/`caught-up`/`gap`/`unknown-instance`/`snapshot`）。
错误码：`SYNC_GAP`（窗口够不到）、`SYNC_UNKNOWN_INSTANCE`（instanceId 变了）、`SYNC_RATE_LIMITED`、`SYNC_BAD_REQUEST`、`SYNC_UNAVAILABLE`。

**缺口按 base 链判，不按整数 seq 连续**：网关 400ms 合并窗口会把多条 delta 压成一帧（`7 → 9` 跳号是常态）。
规则：回放首帧 `base === afterSeq`，其后每帧 `base === 上一帧.seq`；任何一环不成立 = 缺口 → 回快照。**禁止**用「seq 是否 +1」判缺口。

**seq 的持久化边界**：`seq`/`instanceId` 属于 ds-bot（生产者），网关不拥有、不重置。
- 网关重启：instanceId 不变；留窗在内存里随之清空 → 只能回快照（客户端不会看到假缺口，因为 `afterSeq < head` 且窗口为空）。
- ds-bot 重启：`instanceId` 变 → `SYNC_UNKNOWN_INSTANCE` → 快照。
- 卡片流不参与补增量：重连照旧重取 `card-snapshot`（帧小，不值得单开回放通道）。


> ⚠️ 真机踩过的坑：早先 `teamDegraded` 直接取「当前是否绑定服务」，最后一条订阅断开后网关会解绑，
> 于是 `/info` 又显示 `teamDegraded:true`，巡检时被误判成「服务掉了」。现在语义拆开：
> **`*Degraded` 只看源服务在不在位，`*Serving` 才看此刻有没有在供数**。老客户端忽略新字段即可。

### 帧形状

```json
{ "v": 1, "kind": "snapshot", "instanceId": "…", "seq": 42, "at": 1761264000000,
  "mainBotId": "b1", "mainBotIds": ["b1"],
  "bots": [{ "id": "b1", "kind": "bot", "name": "Chief", "role": "Main", "sessionId": "s-1",
             "activity": "working", "work": { "roomId": "r1", "tool": "bash", "note": "npm test", "since": 1761264000123 },
             "approvals": [], "pending": [], "waiting": { "bots": [], "rooms": [], "for": [] } }],
  "rooms": [{ "id": "r1", "kind": "room", "name": "开发组", "members": ["b1"], "admin": "b1", "mode": "admin",
              "work": [], "preview": "…" }],
  "pending": [] }
```

```json
{ "v": 1, "kind": "delta", "instanceId": "…", "seq": 43, "base": 42, "at": 1761264000400,
  "ops": [{ "op": "bot.patch", "id": "b1", "set": { "activity": "waiting" } }] }
```

```json
{ "v": 1, "kind": "order", "instanceId": "…", "seq": 42, "orderSeq": 7, "at": 1761264000000,
  "sessions": { "s-1": 1761264000000, "room-1": 1761263999000 } }
```

```json
{ "v": 1, "kind": "card-snapshot", "instanceId": "c…", "seq": 3, "at": 1761264000000,
  "cards": [{ "id": "q1", "kind": "question", "at": 1761264000000, "botId": "b1", "sessionId": "s-1",
              "roomId": "r1", "group": true,
              "questions": [{ "id": "x", "question": "继续吗？", "multiple": false, "custom": true,
                              "options": [{ "label": "继续", "description": "按原计划" }, { "label": "停" }] }] }] }
```

```json
{ "v": 1, "kind": "card", "instanceId": "c…", "seq": 4, "base": 3, "at": 1761264000500,
  "ops": [{ "op": "card.shown", "id": "q1", "card": { "...": "同上" } },
          { "op": "card.answered", "id": "q1" },
          { "op": "card.cleared", "id": "q1" }] }
```

### 大响应分块（`chunked-frames-v1`）

单帧过大（快照/头像/大增量）会撞客户端内存或连接缓冲阈值，被踢下线后重连、再踢。
抬阈值治标不治本：**把一条大帧的序列化 JSON 切块发，客户端按序号拼回原文再走原处理链**。

- **协商**：客户端在 WS 首帧（`auth`）里带 `capabilities: ["chunked-frames-v1"]`（也接受
  `features` / `caps`，数组、只认字符串项）。**没声明的老客户端永远收整帧**，协议版本不变。
- **上限**：见 `/info` 的 `maxFrameBytes` / `maxReassembledBytes` / `maxStreamsPerConnection`。

```json
{ "kind": "chunk", "streamId": "9f0c…", "index": 0, "total": 3,
  "finalKind": "snapshot", "part": "{\"v\":1,\"kind\":\"snapshot\",…", "at": 1761264000000 }
```

- `part` 是被切开**原始 JSON 字符串**片段，**按 UTF-8 字符边界**切（中文/emoji 不会被劈成两半；
  按字节硬切拼回来是乱码，`JSON.parse` 必挂）。客户端 `parts.join("")` 后得到原帧全文。
- `finalKind` 是原帧的 `kind`（`snapshot`/`delta`/`card-snapshot`/`card`/`order`…）；
  `index` 从 0 连续到 `total-1`；`streamId` 每条流唯一。
- **顺序**：网关**串行**发送流（一条流的块发完才发下一条），同一连接实际并发恒为 1 ≤ 公布上限；
  帧与帧的先后不会被分块打乱。客户端仍应按 `streamId` 归位、容忍乱序与重复（幂等）。
- **超重组上限**（> 4 MiB）：**不切、不发**，只记一行日志（`… not sent (too-large …)`）。
  宁可让客户端保持上一份状态，也不发一条必然被拒的流；连接不受影响，后续帧照常。
- **兜底不变**：> 1 MB 的团队快照仍先走 `avatarDeferred` 分帧（主帧 + 头像旁路帧）；
  分块是在**单帧出口**上的通用兜底，两者互补、不冲突。

### 网关这一层做了什么（以及刻意不做什么）

1. **合并节流 400 ms**：`bot.patch` / `room.patch` 在窗口内按实体合并（绝对值语义，last-write-wins），
   结构变更（`add/update/remove/main.set`）**立即发**，且**先冲刷待发 patch**，不会出现「先 patch 后 add」。
2. **快照不消耗 seq**（契约 §2.4）：两台手机先后取快照拿到同一个 head；`delta.base` 不等于本地 seq 就重取。
   网关自己作为消费者也守同一条（契约 §6）：**入方向** `base !== 已消费水位` 就丢弃这条增量并重取 ds-bot 快照，
   不把错位的增量继续转给手机（水位用 `lastServiceSeq`，不是转发出去的 `head`——合并窗口会让 head 暂时落后）。
3. **静态字段本地缓存**：头像 data URL 只在快照里出现一次，新订阅者拿快照、增量帧不带静态字段。
4. **排序权威 = 网关自己的会话 `updatedAt`**（与桌面 sidebar 同源），通过 `order` 帧下发，
   **不占契约 seq**，也不进 roster 帧；`roster.lastActivityAt` 只是 best-effort，不能当排序依据。
5. **未读由手机本地推导**（已读水位在手机侧），网关不提供。
6. **Redaction 本地做**：名字/角色/instructions/preview/work.note/审批原因/卡片正文在转发前
   过一遍网关自己的密钥替换器（与 ds-bot 共用 `~/.dsh/bot/secrets.json`），不依赖 ds-bot RPC。
7. **不做**：不排序、不造数据、不复用 roster 帧传卡片正文、不做跨 `instanceId` 的事件回放
   （host 重启 → `instanceId` 变 → 订阅端重取快照，包括重传头像）。

### 头像（`avatar`）的体积与格式预算

契约把 `avatar` 定为静态字段（`{ shape, image }`，`image` 是 data URL），手机端**图片优先、没有图片才回落同色块 + 形状符号**。网关对长字符串的处理：

| 项 | 现状 |
|---|---|
| 透传 | 原样透传，**不做转码/截断**（实测 300KB 单头像逐字节一致） |
| 上限 | 单个 `avatar.image` > **32KB**（产品红线）时只裁掉 `image`、保留 `shape`/`color`，并记一行日志（20 个 Bot 满配约 0.84MB，远离出向缓冲阈值） |
| patch 帧 | 静态字段一律裁掉（`avatar`/`color`/…），不进每秒变化的高频路径 |
| 团队流背压 | 团队 WS 的缓冲上限单独放宽到 **8MB**（快照是一次性大帧；按会话的 `/events` 仍是 2MB）；声明分块能力的客户端由 chunk 流兜底，不再靠单帧硬扛 |
| 大快照分帧 | 快照 > **1MB** 时先发**去掉 image 的主帧**（带 `avatarDeferred: true`），再按 ≤256KB 分批发 `{kind:"avatar"}` 旁路帧补头像；小快照不分帧 |

**发布端注意（重要）**：
- `image` 必须是 **iOS 能解码的位图**（PNG/JPEG）。`data:image/svg+xml;…` 在 iOS 上 `UIImage` **解不了**，手机端会静默回落成形状块——看起来像"头像没生效"。
- 建议尺寸 128×128 PNG（每个 ≈10–50KB）；20 个 Bot 的快照约 0.2–1MB，远低于 8MB 背压线。
- 若确实需要矢量一致性，应在发布端栅格化后发位图，而不是发 SVG。

### 客户端接入要点（手机端迁移时照这个来）

1. `GET /mobile/v1/team` 或连 WS `/mobile/v1/team`（`{"type":"auth","token"}`）拿快照；
   WS 会先回 `{"type":"ready","kind":"team",instanceId,seq,cards,degraded}`，再发快照帧。
2. 收 `delta`：`instanceId` 相同且 `base === 本地 seq` 才应用，否则重取快照；
   `ops` 按数组顺序应用（同一帧内不带重复 id）。
3. 收 `order`：用 `sessions[sessionId]` 作为排序键（置顶优先、再按它倒序），不看 `lastActivityAt`。
4. 收 `card` / `card-snapshot`：`placeholder: true` 的卡只显示「有卡在等」，不要渲染成可答复卡片。
5. 断线重连 = 重取快照，不做增量补齐；`degraded: true` 时团队页要显示「实时状态暂不可用」而不是「全部空闲」。

## 数据源

团队状态经 `connection.createSharedFetchHandler('/api')` 调用 ds-bot RPC
（`bridge.describe` / `state` / `bridge.submit` / `bridge.redact`），与独立 bridge 插件相同。
数据源封装在 `lib/mobile-v1/adapter.mjs`，未来宿主直读可用时只需替换该文件。

**原版 ds-bot（无桥接补丁）回退**：`lib/mobile-v1/host-service.mjs` 提供等价实现——
`bridge.describe` 为静态契约、`bridge.redact` 复刻 ds-bot secrets 替换器
（密钥唯一来源：`~/.dsh/bot/secrets.json`，可用 `mobileV1SecretsFile` 覆盖，**不要另建密钥库**）、
`bridge.submit` 走 `sessionController.prompt({requestId, sessionId, mode:'queue', content})`
并按 state 做 TARGET_CHANGED/READ_ONLY 校验。adapter 检测到 RPC 缺 `bridge.*`（501）时自动切换。

**启动语义**：`/mobile-v1*` 路由在插件 apply 阶段**同步注册**；适配器初始化在后台进行，
未就绪期间返回 503（`STARTING` / `CONNECTION_UNAVAILABLE`），不会出现「路由不存在」的 404。
启动过程有分阶段日志（initializing adapter / adapter ready / creating server / ready / failed），
adapter 初始化带 20s 看门狗。

**共存模式**：`mobileV1Prefix: /mobile-v1-test` 可与独立 bridge 插件并行服务，
逐端点 diff 一致后再切回 `/mobile/v1` 并卸载三件套。

**队列动作**：`queue` / `queue-remove` 在原版与补丁版 ds-bot 均未实现，按裁决**不再宣告**（App 无 queue UI）。

### 原版扫码配对的地址陷阱

面板的「原版扫码配对」用的是网关自己的 `POST /mgw/pair`，它**默认取请求来源**作为 `publicUrl`。
面板跑在 `127.0.0.1` 上，所以不显式指定就会把 `ws://127.0.0.1:…` 写进二维码——手机扫码必连不上。

- 面板已改为先读 `/mgw/status` 的 `publicUrl`（wss 形态）再显式传给 `/mgw/pair`；拿不到公网地址时直接提示，不出码
- 服务端兜底：未显式传 `publicUrl` 且解析结果为回环地址时，响应里带 `warning` 字段并记日志（不阻断本地调试）

### 外部命名隧道（固定域名）

想让公网域名永久固定时，用外部常驻隧道（launchd 等）指向插件的**固定回环入口**
`http://127.0.0.1:3082`，并关掉插件自管的 quick 隧道：

```yaml
cloudflare:
  enabled: false            # 自管隧道关闭，不再随重启换域名
  port: 3082                # 回环入口端口（外部隧道指向这里）
  serveLoopback: true       # 关闭自管隧道后仍保持回环入口监听（默认 true）
mobileV1PublicUrl: https://ydgg.dpdns.org
```

注意：`cloudflareServeLoopback` 默认 `true`——旧版本关闭自管隧道会连 3082 监听一起停掉，
外部隧道就会 502。现在两者解耦：只要网关插件在跑，回环入口就在。

## 配置（插件 config）

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `mobileV1Enabled` | `false` | 是否启用 `/mobile/v1`；**开关权在部署侧**，包内默认关闭 |
| `mobileV1Home` | `''` | 设备/回执存储目录，空则用 `~/.dsh/mobile-v1` |
| `publicUrl` | `''` | 网关自己的公网 WS 地址（`wss://host/ws/mobile`）；**优先级高于 `publicUrlFile`**，原版配对载荷的 `publicUrl` 就取它 |
| `mobileV1PublicUrl` | `''` | 配对资料里的公网地址；空则取隧道/`publicUrl`。`wss://`/`ws://` 或带路径的地址会被归一化为 **https 根 origin**（App 的 `validateServerUrl` 只接受这个形态，路径只能是 `/` 或 `/mobile/v1`） |
| `mobileV1Prefix` | `/mobile/v1` | 挂载前缀；共存测试可设 `/mobile-v1-<name>`（只允许这两类） |
| `mobileV1SecretsFile` | `''` | 脱敏密钥文件；空则 `~/.dsh/bot/secrets.json`（与 ds-bot 同一份） |

## 桌面配对管理（loopback-only）

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/mgw/mobile-v1/panel` | **单文件配对面板**（生成配对资料 / 批准 / 拒绝 / 撤销，2s 轮询，零依赖） |
| GET | `/mgw/mobile-v1/status` | 服务状态（含 pending 配对、设备列表） |
| POST | `/mgw/mobile-v1/pairing` | 生成配对资料 `{url, code, serverId, expiresAt}` |
| POST | `/mgw/mobile-v1/pairing/approve` | `{requestId}` 批准 |
| POST | `/mgw/mobile-v1/pairing/deny` | `{requestId}` 拒绝 |
| POST | `/mgw/mobile-v1/devices/revoke` | `{id}` 撤销设备 |

配对码 120 秒有效；claim 300 秒；完整流程见设计文档 §2.8。

面板地址：`http://127.0.0.1:<webPort>/mgw/mobile-v1/panel`（仅本机可访问）。
卸载 companion 后，手机配对流程 = 面板「生成配对资料」→ 复制 JSON → App 粘贴 → 面板「批准」。

## 测试

```bash
node --test test/mobile-v1-public-url.test.mjs
node --test test/mobile-v1-projection.test.mjs
node --test test/mobile-v1-server.test.mjs
node --test test/mobile-v1-wiring.test.mjs
node --test test/mobile-v1-team-feed.test.mjs
```

- public-url：配对地址归一化（`wss://host/ws/mobile` → `https://host`，非法值回退）
- projection：bots/rooms 投影、parts 隐藏过滤、redaction 生效、describe 缺失时的 fail-closed 降级
- server：`/info` 免认证、配对三态（申请→批准→complete）、`/state` 鉴权、设备列表与撤销、错误码
- wiring：apply 级（路由同步注册、装配失败不连累旧协议）；夹具模拟 cordis 语义（未 inject 的服务属性访问即抛）
- team-feed：patch 合并窗口（400 ms 且多帧只发一帧）、结构帧先冲刷 patch 且 seq 不撞车、快照不消耗 seq、
  超帧改发快照、实例变更重锚 base、order 帧不占 seq、降级名册（含会话 updatedAt 与名册增量）、
  卡片帧（群归属 roomId、选项 label 逐字保留、密钥值不下发、pending 占位卡）、
  `GET /team` `/cards` 与 `/team` WS（ready→快照→增量、无 token 回 4401）

> 本机 `npm test` 在 Node 20 上会先挂在 `test/session-preset.test.mjs`（用了 `Promise.withResolvers`，
> 需要 Node 22+，非本批改动）。该文件之后用
> `for f in …; do node --test test/$f.test.mjs; done` 逐个跑，其余 22 个文件全绿。

## 与 bridge 的已知细微差异

- `/state` 的 bot 行会带 `color`：bridge 侧被 redaction 抹掉，本插件按原始字段下发。
  App 侧该字段可空、不影响渲染；若要对齐文档口径，可在 projection 里按需剔除。

