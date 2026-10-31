# 通道能力盘点：旧通道（WS `/ws/mobile`）vs bridge（`/mobile/v1`）

> 用户的要求：「bridge 动作太少，旧通道 76 种，这中间差了哪些要搞清楚，不要后面发现一个问题加一种，
> 那要是我测试没发现的话真遗漏了，毕竟我测试也不是什么都能测试到的。」
> **这单的目标不是把表填全，而是让「漏掉」变成机器能发现的事**——见 §5。
>
> 三张表由脚本生成框架，判断列人工维护：
> `node scripts/channel-parity.mjs --write`（补新行，保留已写判断） / `--check`（校验，已挂 `npm test`）。
>
> **判定口径**（确定性，不做语义猜测）：
> - 旧通道请求类型 = `lib/index.mjs` 里与 `msg.type` 比较的字面量 ∪ `plugin-management.mjs` 的 `PLUGIN_REQUEST_TYPES`
> - 服务端推送帧 = `sendFrame(...)` / `stringifyWireFrame(...)` / `broadcastSessionMetadataFrame(...)` 实参里的 `kind` 字面量
> - bridge 动作 = `lib/mobile-v1/actions.mjs` 的 `MOBILE_ACTIONS`（直接 import，不手抄）
>
> **这些数字由脚本生产，不再靠谁数。** 之前口头流传的「旧通道 76 种」实测是 69——
> 差的 13 个 `plugin-*` 走的是 `PLUGIN_REQUEST_TYPES` 这个独立 Set（`lib/index.mjs:141/1445`），
> 不经过 `msg.type ===` 比较，靠人眼 grep 一定漏。这正是用户担心的那件事，所以判定口径全部固化成代码。
>
> 「手机实际使用 / 有没有 UI 入口」是**按当前 iOS 代码统计**（不是「应该」也不是「以后」）：
> iOS 新增页面或停止调用时，这两列会变，缺口数也跟着变。

> 「手机实际使用」一列的证据来自 iOS 仓库 `DeepSeekHarnessMobile/Core/GatewayClient.swift`（旧通道发送点）
> 与 `AppStore.swift`（插件管理发送点）；桥接动作的调用点在 `BridgeTeamAdapter.swift` / `BridgeChatEngine.swift`。

## 0. 结论摘要

**盘点规模（全部由代码提取，不是手抄）**：旧通道请求类型 **71** 种（v0.11.1 起）、服务端 `kind` 字面量 **63** 个
（其中真正推送帧 18 个，其余是响应帧与非帧）、bridge 动作 **11** 个。
按当前 iOS 代码统计：**44 种手机确实在发**（UI 入口与证据行号见 §1），25 种没在发；其中 15 种属于
「桌面端专用、不该迁」。

**按当前 iOS 代码统计的缺口（手机有 UI、bridge 没有）**——数量会随 iOS 变化，别当常数：

| 优先级 | 缺口 | 依据 |
| --- | --- | --- |
| **已做（本轮）** | `question-answer` → 动作 `answer-question`（见 `docs/answer-question-v1.md`） | 手机卡片能答了；`question-cancel` 仍未迁 |
| **现在做** | `session-create` / `session-rename` / `session-archive` | §1 的 UI 列为「有」，不迁等于这三件事只能开电脑 |
| **记录，不排期** | `goal*`、`permission*`、`plugin-*`、`attachment`、`search`、`providers`、`workspaces`、`workspace-create`、`session-stats`、`context-usage` | 手机有调用点，但频率低或等用户真撞上再说 |

- **能力位两种性质要分开**（决定是「补 bridge」还是「改声明」）：
  - `images: false` **准确描述了 bridge**；手机能发图走的是**未迁移的旧通道** `message` 帧内嵌 base64
    （`lib/index.mjs:179,298`）。**这是迁移缺口，不是声明错误。**
  - `parts: false` 在这个位的契约语义（「WS 历史可否**一页内**跨段翻页」）下**是对的**：
    上一单给的是「换段再请求」（`previousSessionId`），一页仍只含一段。**值不改**；
    但这个名字容易被误读成「投影带不带 parts」，属**语义歧义位，需在契约里改名或加注释**。
- **不该迁的（桌面端专用，迁过去只增风险）**：目录浏览/建目录、文件面板、fork、命令面板、`defaults`/`providers` 设置、
  插件的 registries/catalog 等管理类接口。

<!-- parity:requests -->

## 1. 旧通道请求类型（客户端 → 服务端）

| 旧通道类型 | bridge 对应 | 状态 | 判断理由 | 客户端有无 UI 入口 | 手机实际使用 |
| --- | --- | --- | --- | --- |
| `agent-presets` | — | 未迁 | 桌面 Agent 预设目录，bridge 没有 | 有（旧通道在用） | 已用 `GatewayClient.swift:529 |
| `agent-team` | — | 不该迁 | 上游 0.11.0 新增（旧通道）：数据源是**宿主官方 Session 投影** `agentTeam`，与我们的 dsBotTeam（ds-bot 插件服务）不是同一件事；App 只有 `GatewayModels.swift:217` 解码占位、无 UI | 无 | 未使用 |
| `approval-response` | — | 未迁 | 手机没有审批 UI（`capabilities.approvals:false`） | 有（旧通道在用） | 已用 `:716 |
| `attachment` | — | 未迁 | 附件读取没做（`capabilities.attachments:false`） | 有（旧通道在用） | 已用 `:566 |
| `command-execute` | — | 不该迁 | 手机没有斜杠命令入口 | 无 | 未使用 |
| `command-options` | — | 不该迁 | 同上 | 无 | 未使用 |
| `command-select` | — | 不该迁 | 同上 | 无 | 未使用 |
| `commands` | — | 不该迁 | 同上 | 无 | 未使用 |
| `context-usage` | — | 未迁 | 桌面状态栏的上下文压力，bridge 没有 | 有（旧通道在用） | 已用 `:458 |
| `default-model` | action:models | 已迁 | models` 动作同时返回 `defaultModel | 有（已在用） | 已用 `:535 |
| `defaults` | — | 不该迁 | 桌面设置聚合；改名/模型/effort 已由动作覆盖 | 有（旧通道在用） | 已用 `:532`（取默认值） |
| `directories` | — | 不该迁 | 桌面目录选择器 | 有（旧通道在用） | 已用 `:423`（建会话选目录） |
| `directory-create` | — | 不该迁 | 同上 | 有（旧通道在用） | 已用 `:428 |
| `file-download-cancel` | — | 不该迁 | 手机没有文件面板（`capabilities.files:false`） | 无 | 未使用 |
| `file-download-open` | — | 不该迁 | 同上 | 无 | 未使用 |
| `file-download-read` | — | 不该迁 | 同上 | 无 | 未使用 |
| `file-list` | — | 不该迁 | 同上 | 无 | 未使用 |
| `file-resolve` | — | 不该迁 | 桌面文件引用解析 | 无 | 未使用 |
| `fork` | — | 不该迁 | 桌面会话 fork | 无 | 未使用 |
| `goal` | — | 未迁 | 手机有目标面板，仍走旧通道 | 有（旧通道在用） | 已用 `:501 |
| `goal-clear` | — | 未迁 | 同上 | 有（旧通道在用） | 已用（`sendGoalAction` `:516`） |
| `goal-edit` | — | 未迁 | 同上 | 有（旧通道在用） | 已用 `:505 |
| `goal-pause` | — | 未迁 | 同上 | 有（旧通道在用） | 已用（动态 type） |
| `goal-resume` | — | 未迁 | 同上 | 有（旧通道在用） | 已用（动态 type） |
| `history` | rest:GET /conversations/{id}/messages | 已迁 | REST 游标可跨段（`adapter.mjs:200`）；WS 侧见 `docs/history-segments.md | 有（已在用） | 已用 `:553 |
| `host` | — | 不该迁 | 桌面 host 摘要；bridge 用 `/info` 表达 | 有（旧通道在用） | 已用 `:420 |
| `message` | rest:POST /submissions | 已迁 | 稳定 requestId 提交（`adapter.mjs` submissions） | 无 | 已用（`BridgeChatEngine`） |
| `models` | action:models | 已迁 | 含默认模型与思考等级来源 | 有（已在用） | 已用 `:432 |
| `permission` | — | 未迁 | 手机没有权限面板 | 有（旧通道在用） | 已用 `:455 |
| `permission-options` | — | 未迁 | 同上 | 有（旧通道在用） | 已用 `:450 |
| `ping` | ws:/team | 已迁 | bridge 控制帧 `ping → pong{at}`（sync-resume-v1） | 有（已在用） | 已用 `:416 |
| `plugin-bundle-set-enabled` | — | 未迁 | bridge 没有插件管理面（13 个 plugin-* 全缺） | 有（旧通道在用） | 已用 `AppStore.swift:1773 |
| `plugin-catalog` | — | 未迁 | 同上 | 无 | 未使用 |
| `plugin-entry-set-enabled` | — | 未迁 | 同上 | 有（旧通道在用） | 已用 `AppStore.swift:1772 |
| `plugin-inspect` | — | 未迁 | 同上 | 无 | 未使用 |
| `plugin-install` | — | 未迁 | 同上 | 无 | 未使用 |
| `plugin-install-cancel` | — | 未迁 | 同上 | 无 | 未使用 |
| `plugin-install-status` | — | 未迁 | 同上 | 无 | 未使用 |
| `plugin-registries` | — | 未迁 | 同上 | 无 | 未使用 |
| `plugin-remove` | — | 未迁 | 同上 | 无 | 未使用 |
| `plugin-settings` | — | 未迁 | 同上 | 无 | 未使用 |
| `plugin-settings-mutate` | — | 未迁 | 同上 | 无 | 未使用 |
| `plugin-version-exemption-set` | — | 未迁 | 同上 | 无 | 未使用 |
| `plugin-version-exemptions` | — | 未迁 | 同上 | 无 | 未使用 |
| `providers` | — | 未迁 | bridge 没有 provider 编辑 | 有（旧通道在用） | 已用 `:437 |
| `question-answer` | — | 已规划 | 动作名 `answer-question`（差一个词就 `bot/not-found`）；服务端 `channel.js:437-470` 已完整 | 有（旧通道在用） | 已用 `:694 |
| `question-cancel` | — | 未迁 | 与 `answer-question` 同批规划 | 有（旧通道在用） | 已用 `:703 |
| `queue-update` | — | 不该迁 | bridge 不宣告 queue（消费端没有队列 UI） | 无 | 未使用 |
| `save-default-model` | — | 未迁 | bridge 没有「设默认模型」动作 | 有（旧通道在用） | 已用 `:538 |
| `schedule-catalog` | action:schedules | 已迁 | schedules` 动作给出任务与可用模型 | 有（已在用） | 已用 `:467 |
| `schedule-delete` | action:schedule-delete | 已迁 | 已迁 | 有（已在用） | 已用 `:496 |
| `schedule-history` | — | 未迁 | 执行历史 bridge 没有 | 有（旧通道在用） | 已用 `:473 |
| `schedule-list` | action:schedules | 已迁 | 已迁 | 有（已在用） | 已用 `:470 |
| `schedule-update` | — | 未迁 | bridge 没有更新动作 | 有（旧通道在用） | 已用 `:484 |
| `search` | — | 未迁 | bridge 没有搜索（`capabilities.search:false`） | 有（旧通道在用） | 已用 `:421 |
| `select-agent-preset` | — | 未迁 | 预设选择 bridge 没有 | 无 | 未使用 |
| `select-model` | action:update-bot | 已迁 | 改模型走 `update-bot | 有（已在用） | 已用 `:441 |
| `session-agent-preset` | — | 未迁 | bridge 没有预设切换 | 无 | 未使用 |
| `session-archive` | — | 未迁 | 手机有归档入口，仍走旧通道 | 有（旧通道在用） | 已用 `:600 |
| `session-cancel` | rest:POST /conversations/{id}/cancel | 已迁 | adapter.cancel | 有（已在用） | 已用 `:608 |
| `session-create` | — | 未迁 | 手机建会话仍走旧通道 | 有（旧通道在用） | 已用 `:187 |
| `session-rename` | — | 未迁 | 手机能改名，仍走旧通道 | 有（旧通道在用） | 已用 `:604 |
| `session-stats` | — | 未迁 | 运行统计 bridge 没有 | 有（旧通道在用） | 已用 `:461 |
| `sessions` | rest:GET /conversations | 已迁 | 含 `kind:"session"` 普通会话行 | 有（已在用） | 已用 `:419 |
| `set-default` | — | 未迁 | 设默认模型 bridge 没有 | 有（旧通道在用） | 已用 `:543 |
| `subagents` | — | 不该迁 | 同上，官方 `subagentCatalog` 投影；App 无子会话目录 UI | 无 | 未使用 |
| `subscribe` | ws:/team | 已迁 | bridge 连接即订阅，没有显式订阅请求 | 有（已在用） | 已用 `:593 |
| `tasks` | action:schedules | 已迁 | 任务列表即 schedules | 有（已在用） | 已用 `:464 |
| `unsubscribe` | ws:/team | 已迁 | 断开连接即退订 | 有（已在用） | 已用 `:595 |
| `workspace-create` | — | 未迁 | 手机建会话需要工作区，bridge 没有 | 有（旧通道在用） | 已用 `:430 |
| `workspaces` | — | 未迁 | 同上（列表） | 有（旧通道在用） | 已用 `:418 |

<!-- parity:frames -->

## 2. 服务端推送帧（服务端 → 客户端）

| 帧 kind | 来源 | bridge 对应 | 状态 | 手机实际使用 |
| --- | --- | --- | --- | --- |
| `approval-requested` | 推送帧（构造器） | ws:/team | 已迁 | 显示改由卡片帧承接；回答链路仍未迁 |
| `approval-resolved` | 推送帧（构造器） | ws:/team | 已迁 | 同上 |
| `approval-response` | 响应帧 | — | 未迁 | approval-response` 的应答帧 |
| `assistant-stream` | 推送帧 | ws:/events | 未迁 | 手机主聊天窗在用（旧通道）；bridge `assistantDeltas:false |
| `command-executed` | 响应帧 | — | 不该迁 | 命令执行回执（手机无命令入口） |
| `command-options` | 响应帧 | — | 不该迁 | 命令选项 |
| `command-selected` | 响应帧 | — | 不该迁 | 命令选择 |
| `commands` | 响应帧 | — | 不该迁 | 命令目录 |
| `context-usage` | 响应帧 | — | 未迁 | 上下文压力 |
| `default-model` | 响应帧 | action:models | 已迁 | models` 动作的 `defaultModel |
| `defaults` | 响应帧 | — | 不该迁 | 桌面设置聚合 |
| `directories` | 响应帧 | — | 不该迁 | 目录浏览 |
| `directory` | 非帧 | — | 不该迁 | 目录条目类型，不是帧 |
| `directory-create` | 响应帧 | — | 不该迁 | 建目录 |
| `edit` | 非帧 | — | 不该迁 | 提交动作的 kind |
| `error` | 推送帧 | ws:/team | 已迁 | 两条通道都有错误帧 |
| `event` | 非帧 | — | 不该迁 | 事件信封（随快照/增量下发，不是独立帧） |
| `file` | 非帧 | — | 不该迁 | 文件条目类型 |
| `file-download-cancelled` | 响应帧 | — | 不该迁 | 文件下载 |
| `file-download-chunk` | 响应帧 | — | 不该迁 | 同上 |
| `file-download-opened` | 响应帧 | — | 不该迁 | 同上 |
| `file-list` | 响应帧 | — | 不该迁 | 文件面板 |
| `file-resolved` | 响应帧 | — | 不该迁 | 文件引用解析 |
| `hello` | 推送帧 | ws:/team | 已迁 | bridge 握手帧 |
| `history` | 响应帧 | rest:GET /conversations/{id}/messages | 已迁 | bridge 走 REST；WS 侧见 `docs/history-segments.md |
| `immediate` | 非帧 | — | 不该迁 | 命令 UI 描述符 |
| `input` | 非帧 | — | 不该迁 | 命令 UI 描述符 |
| `owner` | 非帧 | — | 不该迁 | connection peer 的 principal kind |
| `paired` | 推送帧 | rest:POST /pairings | 已迁 | 配对改成 REST 完成 |
| `pairing` | 非帧 | — | 不该迁 | 配对协议 token 解析结果 |
| `pending` | 非帧 | — | 不该迁 | 答子的中间状态 |
| `permission` | 响应帧 | — | 未迁 | 权限清单 |
| `permission-options` | 响应帧 | — | 未迁 | 权限选项 |
| `plugin-settings-changed` | 推送帧 | — | 未迁 | 插件流未迁 |
| `plugins-changed` | 推送帧 | — | 未迁 | 同上 |
| `pong` | 推送帧 | ws:/team | 已迁 | sync-resume-v1 的 `ping → pong{at} |
| `prefix` | 非帧 | — | 不该迁 | 内部广播键 |
| `projection-baseline` | 推送帧 | — | 未迁 | 会话投影基线，bridge 没有 |
| `question-requested` | 推送帧（构造器） | ws:/team | 已迁 | 显示改由卡片帧承接；`answer-question` 已排期 |
| `question-resolved` | 推送帧（构造器） | ws:/team | 已迁 | 同上 |
| `question-response` | 响应帧 | — | 已规划 | answer-question` 动作的回执；服务端已具备 |
| `queue-item-updated` | 响应帧 | — | 不该迁 | 队列更新（bridge 不宣告 queue） |
| `rejected` | 非帧 | — | 不该迁 | 答子的中间状态 |
| `save-default-model` | 响应帧 | — | 未迁 | 设默认模型的回执 |
| `schedule-changed` | 推送帧 | — | 未迁 | 定时任务变更推送 |
| `select` | 非帧 | — | 不该迁 | 表单字段类型 |
| `sent` | 响应帧 | rest:POST /submissions | 已迁 | 发消息回执 |
| `session-agent-preset-updated` | 推送帧 | — | 未迁 | 预设变更推送 |
| `session-archived` | 响应帧 | — | 未迁 | 归档回执 |
| `session-archives` | 推送帧 | — | 未迁 | 归档列表推送 |
| `session-cancelled` | 响应帧 | rest:POST /conversations/{id}/cancel | 已迁 | 打断正在跑的回合 |
| `session-queue` | 推送帧 | — | 未迁 | 队列推送（bridge 不宣告 queue） |
| `session-queues` | 推送帧 | — | 未迁 | 同上 |
| `session-renamed` | 响应帧 | — | 未迁 | 改名回执 |
| `session-snapshot` | 推送帧 | ws:/events | 已迁 | bridge `/events` 的快照帧 |
| `session-stats` | 响应帧 | — | 未迁 | 运行统计 |
| `session-status` | 推送帧 | — | 未迁 | 上游 0.11.0 新增广播（`api-session/status|added|removed` → running 状态）；App 按未知帧处理（进 protocolNotices，无 UI 消费） | App 不消费（看到即丢弃） |
| `session-stream-reset` | 推送帧 | — | 未迁 | 流重置 |
| `session-title-changed` | 推送帧 | — | 未迁 | 标题变更（团队快照里带标题） |
| `set-default` | 响应帧 | — | 未迁 | 设默认值的回执 |
| `subscribed` | 推送帧 | ws:/team | 已迁 | bridge 连接即订阅 |
| `token` | 非帧 | — | 不该迁 | 配对 token 解析结果 |
| `unavailable` | 非帧 | — | 不该迁 | 答子的中间状态 |

<!-- parity:actions -->

## 3. bridge 动作（含反向：bridge 有、旧通道没有）

| 动作 | 对应旧通道 | 状态 | 手机实际使用 |
| --- | --- | --- | --- | --- |
| `answer-question` | question-answer | 已迁 | 已用（旧通道 `GatewayClient.swift:694`） |
| `efforts` | — | 新增 | 已用（思考等级） |
| `memory-forget` | — | 新增 | 已用 |
| `memory-view` | — | 新增 | 已用 |
| `models` | models / default-model | 已迁 | 已用（模型选择） |
| `schedule-create` | — | 新增 | 已用 |
| `schedule-delete` | schedule-delete | 已迁 | 已用 |
| `schedules` | schedule-list / tasks | 已迁 | 已用 |
| `set-flags` | — | 新增 | 已用（置顶/隐藏） |
| `update-bot` | select-model | 已迁 | 已用 |
| `usage` | — | 新增 | 已用 |

<!-- parity:end -->

## 4. `/info` 声明 vs 实际能力（比缺口表更危险）

能力位是客户端做判断的依据；**声明错了会让客户端走错误的降级路径**（明明能用却降级，或者明明没做却尝试）。

| 声明 | 代码位置 | 实际 | 谁在用 | 结论 |
| --- | --- | --- | --- | --- |
| `images: false` | `adapter.mjs` capabilities | **bridge 确实不收图**（`send` / `submissions` 没有图片字段）；手机能发图是走旧通道 `message` 帧的 base64 内嵌（`lib/index.mjs:179,298`） | 手机相册发送（旧通道） | **声明准确，是迁移缺口不是声明错误**：要补的是 bridge 的图片提交能力（另立项），不是把声明改成 true |
| `attachments: false` | 同上 | 确实没有附件通道（拉取/上传） | — | 保持 `false`，但要在文档里写清**与「能发图」不是一回事** |
| `files: false` | 同上 | 没有文件列表/下载 | — | 保持 |
| `parts: false` | 同上 | 这个位的契约语义是「WS 历史能否**一页内**跨段翻页」；一页仍只含一段（`previousSessionId` 是「换段再请求」，见 `docs/history-segments.md` §8） | 手机主聊天窗（待接线） | **值不改**：在该语义下 `false` 是对的。但名字易被误读成「投影带不带 parts」，**记为语义歧义位，需在契约里改名或加注释** |
| `sessions: true` | 同上 | 手机在用（`/conversations` 的 `kind:'session'` 行） | 会话列表 | 保持 |
| `send: true` | `description.stableRequestId` | 手机在用 `/submissions` | 发消息 | 保持 |
| `actions: [...]` | 由 `MOBILE_ACTIONS` 派生 | 10 个，确实可用 | 团队页设置 | 保持，新增动作自动出现 |
| `queue / cancel / approvals / memory*` | 同上 | 与实现一致（`cancel` 由 `sessionController` 在场决定） | — | 保持 |
| `groups` | `description.groups === true && groupProjection === 1` | 取决于 ds-bot 版本 | 群聊 | 保持 |

> 结论：**没有一处「声明撒谎」**——两处看起来矛盾的地方性质不同：
> `images` 是**迁移缺口**（bridge 缺能力，声明本身准确），`parts` 是**语义歧义**（值对、名字易误读）。
> 补能力与改名都属另一个单（要同步 iOS 的降级判断），本单只记录、不动值。

## 5. 自动校验（这单真正的产出）

`test/channel-parity.test.mjs` 调 `problems()`（与 `--check` 同一份逻辑），任一条不成立就让 `npm test` 变红：

1. **旧通道新增一种请求类型**、表 A 没记 → 红（反之表 A 记了代码里没有的 → 也红）
2. **服务端新增一个推送帧**、表 B 没记 → 红（标为推送帧但代码里已不发 → 也红）
3. **bridge 新增/删除动作**、表 C 没同步 → 红（双向）
4. 表 A 里标「已迁」但没有落点，或落点写成 `action:x` 而 `x` 不在 `MOBILE_ACTIONS` 里 → 红
5. 状态词只能是 `已迁 / 未迁 / 不该迁 / 状态不明 / 已规划`，写别的 → 红

**变异测试的反例必须用一定不存在的值（哨兵），不能拿真实实体当反例。**
本单第一次写自检时，反例用的是真动作名 `answer-question`——它一上线，那个「反例」就变成合法的了，
用例会**永远变绿、不再报警**（这是变异测试最典型的失效陷阱）。现在反例统一用 `not-a-real-action` 这类哨兵名：
无论哪个真实实体上线，它都不会变成合法值。

于是「加了能力忘了同步对照表」不再依赖任何人手测：**新增的人必须同时改表，否则 CI 直接挡下来**。
