# 网关上游合并前置评估：0.10.4 → 0.11.1

> 只读评估。产出日期 2026-10-31。
> 仓库 `/Users/yidagege/Documents/deepseek-harness/default-workspace/dsh-plugin-mobile-gateway`
> 本分支 `feat/mobile-v1-bridge` @ `ac9e9f0`（0.10.4）；上游 `upstream/main` @ `f467033`（0.11.1）。
> **behind 13 / ahead 53**，merge-base `286dd72`。（`git rev-list --count` 实测）

---

## 0. 先纠正一个前提（用户是对的，Chief 的担心不成立）

**上游的 agent-team 与我们的团队流不是同一套数据，来源完全不同**，不存在「同一功能两套实现」的重叠：

| | 上游 agent-team（0.11.0） | 我们的团队流（mobile-v1） |
| --- | --- | --- |
| 数据来源 | **DSH 宿主官方 Session 投影**：`api.sessions.projections({sessionId})` → `snapshot.values.agentTeam` / `.subagentCatalog`（`lib/index.mjs:1457-1479` 上游） | **ds-bot 插件的 cordis 服务**：`ctx.get('dsBotTeam')` / `ctx.get('dsBotCards')`（`lib/mobile-v1/index.mjs:30`、`lib/index.mjs:2994-2995` 我们） |
| 底层实现 | `invoke('session','projections',…)` 走 typert 官方 RPC（上游 `lib/dsh-host-adapter.mjs:254`） | `createSharedFetchHandler('/api')` 打 ds-bot 的 `POST /api/bot`（我们 `lib/mobile-v1/adapter.mjs:12-13`） |
| 通道 | **旧协议 `/ws/mobile`**（control 连接） | **新前缀 `/mobile/v1`**（独立 WS + REST） |
| 语义 | 一个 Lead 会话下的成员与任务、子会话目录树 | Bot 名册（主 Bot / Bots / 群聊）+ 实时工作态 + 卡片 |

**协议层撞名检查结果：没有撞名。** 上游新增的是 `agent-team` / `subagents` 请求类型与
`agent-team-updated` / `subagents-updated` / `subagent-identity-updated` / `subagent-timing-updated` 推送帧，
能力位是 `agent-team-v1` / `subagent-conversations-v1`；我们的整套是 `snapshot` / `delta` / `order` /
`avatar` / `card` / `card-snapshot` 帧 + `team` / `cards` / `teamDegraded` / `teamServing` 能力位。
**两边没有一个帧名、一个字段名、一个能力位重名**——`team` 这个字只出现在我们的
`/info` capabilities 里，上游用的是 `agent-team-v1`。

**App 页面消费层面**：我们的 App 只有「Bot 团队页」（`teamSnapshot`，消费 mobile-v1），
对 agent-team 只有 `GatewayModels.swift:217-220` 的**解码字段占位**（`agentTeam`/`subagentCatalog`/
`subagent`/`subagentTiming`/`projectionState`），**没有任何消费者**（`GatewayFrameRouter` 里 grep 为空）。
所以不存在「同一页面要同时消费两种团队」的冲突。

---

## A. 上游 13 个提交：性质分类

13 = 5 个 merge + 8 个实质提交。**能力新增只有 3 项，其余是 UI/语言/部署脚本**。

| # | 提交 | 性质 | 动了什么 | 给移动端带来新能力？ |
| --- | --- | --- | --- | --- |
| 1 | `6036e28` Add agent team and subagent conversation support | **能力新增（0.11.0 主线）** | `lib/index.mjs`(+131)、`lib/dsh-host-adapter.mjs`(+30)、**新增** `lib/session-target.mjs`(29)、`lib/session-follower.mjs`、`PROTOCOL.md`(+38)、`docs/agent-team-app-integration.md`(945 行新文档)、2 个新测试文件 | ✅ agent-team-v1 / subagent-conversations-v1 |
| 2 | `b7ce95d` Add chunked file uploads | **能力新增（0.11.1 主线）** | `lib/index.mjs`(+69)、`lib/dsh-host-adapter.mjs`(+35)、**新增** `lib/file-upload.mjs`(205)、`PROTOCOL.md`(+34)、`docs/file-upload-app-integration.md`(250) 、2 个新测试文件 | ✅ file-upload-v1 |
| 3 | `2f62486` Allow browsers to pass device id/name via WS subprotocols | 兼容性新增（浏览器配对） | `lib/index.mjs`(+37)、`PROTOCOL.md`(+13)、`test/auth.test.mjs`(+48) | ⚠️ 只对「浏览器/无法设自定义头的客户端」有用；App 用 header，不受影响 |
| 4 | `688bc9f` Harden browser device metadata subprotocols | 修复/加固 | `lib/index.mjs`(+15)：子协议 ID 收紧到 RFC 6455 token 字符（**不允许 `:`**）、设备名 Base64URL 上限 512、PROTOCOL 说明 | ❌ 纯加固 |
| 5 | `f467033` Merge PR #32（browser-pairing 分支收口） | 机械合并 | 同 3+4 合计的收口 | ❌ |
| 6 | `1adae9e` feat(ui): add automatic English locale | UI/国际化 | 仅 `lib/client.js`(+303/−120) | ❌ 旧协议网关的**网页面板** UI |
| 7 | `0dd5f5d` feat(ui): add localized install guide | UI/国际化 | 仅 `lib/client.js`(+136) | ❌ 同上 |
| 8 | `2cfe44c` feat(client): add Japanese (ja) locale | UI/国际化 | 仅 `lib/client.js` | ❌ 同上 |
| 9 | `69a6b22` fix: quote deploy-hook command in cert renewal systemd service | 部署修复 | `bin/setup-ip.mjs` **1 行**（加引号） | ❌ |
| 10 | `58878f5` / `25e9cf5` / `3254b1c` / `1ebaf95` | 机械 merge（ja/en/deploy-hook/browser-pairing 的 PR 收口） | — | ❌ |

**结论**：真正会改变移动端行为的只有 **2 个提交**（agent-team、file-upload），
其余 11 个对我们的 App 零影响或只影响桌面网页面板。

---

## B. 与我们 53 个自研提交的重叠面

### B.1 实测：文件级只有 2 个文件冲突、**2 个冲突块**

用 `git merge-tree --write-tree HEAD upstream/main` 干跑（不改工作区）：

```
CONFLICT (content): Merge conflict in lib/index.mjs
CONFLICT (content): Merge conflict in package.json
```

| 文件 | 冲突块 | 位置与原因 |
| --- | --- | --- |
| `lib/index.mjs` | **1 块** | `handleQuery` 的 `history` 分支：上游把 `requireSessionId(msg)` 换成 `parseSessionTarget(msg)`（支持 `parentSessionId`/`subagentMode` 的子会话寻址）并给响应加 `requestId` 回显；我们在这同一分支加了 `pluginContext.historyOwner(sessionId)` 归属解析 + `previousSessionId` 分段入口 |
| `package.json` | **1 块** | `test` 脚本：我们 34 条串行链 vs 上游 14 条（含 `file-upload`/`agent-team` 两个新文件） |

**两处都是「并集」型冲突，没有语义互斥**：history 分支可以是
`parseSessionTarget + 我们的 historyOwner/previousSessionId` 共存（子会话寻址与 Bot 分段寻址是不同 sessionId 空间，`resolveHistoryOwner` 对未知 sessionId 返回 null 即放行）。

### B.2 语义级重叠：逐项对照

| 上游新能力 | 我们有没有等价实现 | 结论 |
| --- | --- | --- |
| 普通文件分块上传（`file-upload-v1`，走官方附件存储 + `receiptId`） | **没有**。我们的 `card-frames.mjs` 只有**卡片**（question/view/secret），`parity` 表里 `attachments:false` / `files:false`。手机能发图走的是旧通道 `message` 帧内嵌 base64（`lib/index.mjs:179,298`），与「附件上传」是两件事 | **不重复**，是真新增。且 App 侧**已经实现**（见 C.3） |
| agent-team / 子会话目录 | **没有**，且数据源不同（见 §0） | **不重复** |
| 浏览器配对子协议（device id/name 走 subprotocol） | 没有 | 不重复，但我们不需要 |
| 英文/日文面板 locale | 我们的面板是 `lib/mobile-v1/panel.mjs`（自研），与 `lib/client.js` 无关 | 不重复，互不影响 |
| `session-status` 推送帧（`api-session/status|added|removed`） | 我们没有；我们的团队流用自己的 `delta` | 不重复 |

### B.3 合并时必须保住的自研（53 提交的主体）

按文件足迹聚合（`git log --name-only` 实测）：

- **`lib/mobile-v1/*` 整套**（团队帧 `team-feed.mjs`、卡片帧 `card-frames.mjs`、`server.mjs`、`auth.mjs`、`adapter.mjs`、`panel.mjs`、`host-service.mjs`、`chunked.mjs`）——上游**从未碰过**这个目录，零冲突风险。
- **`lib/index.mjs` 的 22 次改动**：mobile-v1 装配（`startMobileV1`、extraServers、`resolveTeamService`/`resolveCardService`）、`optionalService()`、`parseJsonBody()`、`paired` 帧早于 `hello` 的修复、history 归属解析。
- **`lib/cloudflare-tunnel.mjs` / `lib/multi-gateway*` / `bin/setup-ip.mjs`** 的修复（注意：`69a6b22` 也改 `bin/setup-ip.mjs`，但只改 1 行引号，与我们的改动不重叠——干跑无冲突已证）。
- 自研文档 4 份 + 评估/契约文档（`docs/history-segments.md`、`docs/answer-question-v1.md`、`docs/channel-parity.md`、`docs/mobile-v1-integration.md` 20+ 次更新）。

---

## C. 协议兼容性风险（最要紧）

### C.1 上游没有改协议版本号，只做增量

`PROTOCOL.md` 原文（新增段落逐字引用）：

> 「当前源码新增两个协议 3 可选能力，Host 适配基线为 DSH 0.2.1-rc.2、Session format 4。」

> 「已配对连接在启用 `fileUploadsEnabled` 时公布 `file-upload-v1`。上传请求走 control 连接（兼容 legacy），消息走 conversation 连接（兼容 legacy）。」

- `protocol: 3` **未变**（两边 `lib/index.mjs` 的 hello 都是 `protocol: 3`）；
- `SESSION_FORMAT_VERSION = 4` **未变**（`lib/dsh-host-adapter.mjs:17` 我们 / `:19` 上游）；
- 新增能力位 3 个：`agent-team-v1`、`subagent-conversations-v1`、`file-upload-v1`；
- 新增请求类型 2 个（`agent-team`、`subagents`）+ 上传 4 个（`file-upload-open/chunk/finish/cancel`）；
- 新增推送帧 1 个旧协议通用帧（`session-status`）+ 4 个团队投影帧（`agent-team-updated` 等）；
- `user/message` 事件新增 `files` 字段（additive）；history/attachment 响应新增 `parentSessionId`/`subagentMode`/`requestId` 回显（additive）。

### C.2 「不接入会怎样」——优雅降级，但有噪音

- **能力位是客户端主动读的**：App 不读 `agent-team-v1` 就不会发 `agent-team` 请求，那不接入 = 零影响。
- **但推送帧是广播的**：上游把 4 个团队投影帧挂进了 `broadcastSessionMetadataFrame`
  （`lib/index.mjs:3557`，`broadcast = key === 'turnOutline' || Object.hasOwn(TEAM_PROJECTION_KINDS, key)`），
  而这个广播**不做订阅过滤**：

  ```js
  const broadcastSessionMetadataFrame = (frame) => {
    const wire = stringifyWireFrame(frame)
    for (const client of clients) {
      if (client.mobileChannel === 'conversation') continue
      if (client.readyState === 1) client.send(wire)
    }
  }
  ```

  同一个广播还带 `session-status`（每次会话运行状态变化都发）。**我们的 App 会收到这些没见过的帧。**
  App 的处理（`DeepSeekHarnessMobile/Core/GatewayFrameRouter.swift:403-404`）：

  ```swift
  default:
      return .unknown(frame.kind)
  ```
  → `AppStore.swift:3472: case .unknown(let kind): notice("未知网关响应", kind)`
  → 进 `protocolNotices`（上限 100 条）。

  **实测这个 surface 对用户不可见**：`selectedNotices`（`:1300`）在整个 App 里**没有任何视图消费**（grep 只有定义处）。
  而且**这个机制今天就已经在跑**——我们的 0.10.4 已经广播 `turn-outline-updated`，App 同样不认识、同样进这个数组
  （`GatewayFrameRouter.swift` 里没有 `turn-outline-updated` 分支）。**所以：不炸、不崩、不弹窗，只是多几条内存里的字符串。**

### C.3 一个反向结论：File upload 合并后**会立刻亮起**

App **已经实现了完整的 `file-upload-v1` 客户端**：

- `DeepSeekHarnessMobile/Core/FileUploadController.swift`（247+ 行，含 `file-upload-finish` 60s / 其它 30s 超时）
- `AppStore.swift:3181`：`if frame.kind.hasPrefix("file-upload-") { fileUploads.accept(frame); return }`
- `AppStore.swift:3498`：`supported: payload.protocolVersion >= 3 && payload.capabilities.contains("file-upload-v1")`

也就是说：网关一旦升级到 0.11.1 并公布 `file-upload-v1`，**手机端文件上传会自动从「灰」变「可用」**——
这是本次合并最大的行为变化，也是**唯一会让用户立刻感知到的新功能**。

### C.4 风险清单

| # | 风险 | 等级 | 依据 |
| --- | --- | --- | --- |
| 1 | App 收到 4 种新推送帧（`agent-team-updated` 等）+ `session-status` → 进不可见的 `protocolNotices` | **低** | 已有同类先例（`turn-outline-updated`），数组上限 100，无 UI 消费 |
| 2 | 文件上传「自动亮起」：App 已实现但**从未在真机对过 0.11.1 网关** | **中** | App 代码在，联调证据缺；上传失败会表现为 UI 报错而非静默 |
| 3 | `history` 分支合并若解错（丢掉 `historyOwner` 或 `parseSessionTarget`）→ 分段历史或子会话寻址单边失效 | **中** | 唯一真冲突处；解错会让「Bot 旧历史翻页」或「子会话历史」其一坏掉 |
| 4 | `agent-team-v1` 公布后 App 不消费 → 能力位「说谎」（公布了却不显示） | **低** | 能力位语义是「网关支持」，客户端可实现；但在验收清单里要写清「App 侧 UI 未做」 |
| 5 | 我们的 `channel-parity` 审计会因上游新类型变红（实测已红） | **确定发生** | 见 E.1 |

---

## D. DSH 宿主版本适配（本机 rc.4）

上游声明基线 **rc.2**，本机是 **`@deepseek-ai/dsh-desktop-runtime 0.2.1-rc.4`**（从 `app.asar` 的
`dsh/package.json` 读出）。逐项核对上游用到的三个官方接口：

| 上游依赖 | rc.4 是否存在 | 证据（本机 app.asar 解包） |
| --- | --- | --- |
| `invoke('session','projections',…)`（agent-team 数据源） | ✅ | `@deepseek-ai/dsh-tool-cordis/lib/types/api-catalog.js:2592`：`@Remote('projections') projections(request: SessionProjectionsRequest, signal: AbortSignal): Promise<SessionProjectionsValue>` |
| 投影键 `agentTeam` / `subagentCatalog` | ✅ | `@deepseek-ai/dsh-api-session-controller/lib/typert.host.js:118`（subagentCatalog schema）、`:222`（agentTeam schema）、`:449`、`:553`；另有 `@deepseek-ai/dsh-experimental-agent-team` 包 |
| 上传路由 `/api/session/uploadFileBinary` + `requestBodyMode` | ✅ | `dsh-client-file-upload/lib/index.js:78`（`FILE_UPLOAD_PATH`）、`:182`（`requestBody: "streaming"`）；`dsh-client-connection/lib/index.js:822`（`requestBodyMode` 按路由返回 `route.requestBody`） |
| `connection.createPeer` / 共享 fetch | ✅ | 我们的插件现在就跑在 rc.4 上 |

**结论：`lib/dsh-host-adapter.mjs` 不需要跟随 rc.4 做任何额外改动**——上游新增的
`sessions.projections` / subagent 寻址 / 文件上传三块，在 rc.4 上都有对应实现。
注意 adapter 手工合并时要把上游新增的 `sessions.projections` 与 `files.{available,upload}` 两段并进去（干跑无冲突）。

---

## E. 三种方案的实测工作量

### E.1 方案 1：全合到 0.11.1（实测已干跑）

| 项 | 实测值 |
| --- | --- |
| 冲突 | **2 文件 / 2 块**（`lib/index.mjs` history 分支、`package.json` test 脚本） |
| 新增文件 | `lib/session-target.mjs`、`lib/file-upload.mjs`、2 份 App 对接文档、4 个测试文件 |
| 依赖变化 | **无**（`package.json` 只变 version/description/test 脚本，无新依赖） |
| 测试面 | 干跑解冲突后 `npm test`：**154 例 / 153 pass / 1 fail**（Node 22.23.4）；基线 150 例 / 0 fail |
| 唯一的红 | 我们自己的 `test/channel-parity.test.mjs`——上游新增 `agent-team`、`subagents` 两种请求类型 + `session-status` 推送帧没进对照表。**这是审计机制按设计生效**，补 3 行即可 |
| App 要不要改 | **不需要改就能兼容**；`file-upload-v1` 会自动启用（App 已实现）；agent-team 无 UI |
| 预估工时 | 解冲突 0.5h + 补 parity 表 0.5h + 全量回归 0.5h ≈ **1.5–2h**，另有真机验证文件上传（App 侧从未对过 0.11.1） |

### E.2 方案 2：选择性合（locale + 浏览器配对 + deploy hook）

实测：在 HEAD 的临时副本上**按序** `git apply` 6 个提交（`1adae9e`→`0dd5f5d`→`2cfe44c`→`69a6b22`→`2f62486`→`688bc9f`）：

- **全部 6 个 0 冲突应用成功**；
- 应用后 `npm test`：**150 例 / 0 fail / exit 0**（与基线持平）。

| 项 | 实测值 |
| --- | --- |
| 冲突 | **0** |
| 收益 | 面板英文/日文 locale、安装指引本地化、浏览器配对子协议、deploy hook 引号修复 |
| 成本 | 0.5h（应用+回归），App 零改动 |
| 代价 | **拿不到 file-upload-v1**（App 里已经写好的上传继续灰着）；agent-team 也没有；下次合并仍要面对 `lib/index.mjs` 那个 history 冲突，且上游会继续前进，越拖差距越大 |

### E.3 方案 3：先不合

| 维度 | 判断 |
| --- | --- |
| 失去什么 | ① 手机端文件上传（**App 已实现，只差网关**）；② agent-team 能力（App 无 UI，短期无感）；③ 面板 locale、浏览器配对；④ 与上游的版本差（现 13 提交，按 0.11.0→0.11.1 的节奏约每周 5–10 个） |
| 拖着有什么风险 | 冲突面**不会自己变小**：`lib/index.mjs` 是我们改动最密（22 次）且上游也最密（每次能力新增都动它）的文件；下次 merge 仍是同一个函数区。真正危险的是**未来某次上游重构（比如 0.12 拆文件）把我们依赖的 `requireSessionId`/`handleQuery` 结构改掉**，那时历史归属解析要重写 |
| 但也要说清 | 现在**没有任何用户可见的问题**逼着合；0.10.4 跑得好好的，`file-upload` 是「新增」不是「修复」 |

---

## F. 建议（不替用户决策）

**倾向方案 1（全合），但必须与 App 侧同步排期**，理由按权重：

1. **冲突成本现在是历史最低点**：实测 2 块，且都是并集型；等上游继续迭代，同一处只会更贵。
2. **有一个「已经写好但用不上」的功能在等网关**：`FileUploadController.swift` 完整实现了 `file-upload-v1`，网关不升级它就永远灰着。合并是让已有投入生效，不是新增投入。
3. **风险可控且可测**：协议版本号没动、能力位是增量、未知帧的处理机制今天已经在跑（`turn-outline-updated` 先例），并且实测只有我们自己的一条审计用例会红（补 3 行）。
4. **不建议方案 2**：省下的 1 小时换来「下次还得解同一个冲突」，且 file-upload 仍然拿不到——收益/成本比最差。
5. **方案 3 只在一种情况下合理**：如果 App 侧短期内没人力验证文件上传真机路径，那么合并会让一个**未经真机验证**的功能上线，风险从网关转到 App。此时建议「合但默认关」——上游有 `fileUploadsEnabled` 配置项（`lib/file-upload.mjs:11` 默认 true），把它配成 false 即可先合代码不亮功能。

**必须同时接受的前置**：
- App 真机验证 `file-upload-v1`（App 已实现，未对过 0.11.1 网关）；
- 合并后 `/info` 与 `hello.capabilities` 会多 3 个能力位，App 的验收清单要写明「agent-team 无 UI」；
- 我们的 `channel-parity` 表要加 3 行（`agent-team`、`subagents`、`session-status`），否则 `npm test` 恒红。

---

## 附：本次评估用到的实测命令

```sh
# 坐标与差距
git rev-list --count HEAD..upstream/main      # 13
git rev-list --count upstream/main..HEAD      # 53
git merge-base HEAD upstream/main             # 286dd72

# 干跑冲突（不动工作区）
git merge-tree --write-tree --name-only HEAD upstream/main

# 合并结果实证（/tmp 副本，非仓库）
git archive <merge-tree 的 tree> | tar -x -C /tmp/gw-merge
# 解 2 处冲突后
PATH="$HOME/.dsh/node-v22/bin:$PATH" npm test   # 154 例 / 153 pass / 1 fail
# 基线
PATH="$HOME/.dsh/node-v22/bin:$PATH" npm test   # 150 例 / 0 fail

# 方案 2 实证（/tmp 副本）
git format-patch -1 --stdout <c> | git apply    # 6 个提交按序全绿
PATH="$HOME/.dsh/node-v22/bin:$PATH" npm test   # 150 例 / 0 fail

# 宿主版本
npx @electron/asar extract-file ".../app.asar" dsh/package.json   # 0.2.1-rc.4
```
