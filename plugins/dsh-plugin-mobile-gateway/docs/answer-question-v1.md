# `answer-question`：手机上回答 ds-bot 的提问卡（bridge 契约 v1）

> 状态：**网关侧已实现**（动作 `answer-question`）。ds-bot 零改动——服务端逻辑本来就在
> `ds-bot/src/host/channel.js:437-470`，这里只是把它从 bridge 开出来。
> 手机侧接线见 §6（`pendingQuestionRequests` 的正文来源另议：卡片帧已经带正文）。
>
> **生效条件：需要重启宿主进程。** 代码合并 ≠ 跑着的网关有这个动作——宿主内存里跑的是旧的那份
> （实测运行中 `/info` 仍是 10 个动作、不含 `answer-question`）。重启后 `GET /mobile/v1/info` 的
> `capabilities.actions` 应变成 11 个并包含它；这是判断"到底生效了没有"的唯一可靠办法。
>
> 为什么动作名是 `answer-question` 而不是 `question-answer`：网关把动作名**原样**当 ds-bot 的
> `body.endpoint` 发过去，`channel.js:437` 的 case 就是 `'answer-question'`。差一个词 =
> `bot/not-found`，而且失败长相很像"功能没实现"。

## 1. 请求

```http
POST /mobile/v1/actions
Authorization: Bearer <accessToken>
Content-Type: application/json

{
  "endpoint": "answer-question",
  "payload": {
    "sessionId": "session-08bf1a39-22da-4ad3-97be-c8dae17feaee",
    "questionId": "9a1f5c2e-6f1b-4a63-9d0f-4b7c1f9d2a11",
    "answer": {
      "selected": ["选项 A 的原文"],
      "custom": "用户自己写的一段话"
    }
  }
}
```

字段：

| 字段 | 类型 | 约束 |
| --- | --- | --- |
| `sessionId` | string | 1–256 字符；必须是**卡片帧上那个** `sessionId`（Bot 卡=该 Bot 当前段或更早分段；群卡=`roomId`） |
| `questionId` | string | 1–256 字符；来自卡片帧的 `id`（问题卡的 `id` 就等于服务端的 `question.id`） |
| `answer.selected` | string[] | 最多 50 项，每项 1–2000 字符；**选项 `label` 原文** |
| `answer.custom` | string? | ≤8000 字符 |
| `answer` 其它字段 | — | **一律拒绝**（400），未知字段不透传 |

**`selected` 逐字原样**：不做 trim、不去重、不归一化。服务端拿 `label` 当答案身份
（`ds-bot/src/host/parts.js:69-87` 用 `new Set(options.map(o => o.label))` 过滤），
差一个字符（少个空格、全角半角）就会被过滤掉 → 整条答案变空 → `bot/invalid`。

## 2. 响应（成功）

```json
{ "sessionId": "session-08bf1a39-…", "questionId": "9a1f5c2e-…", "answered": true }
```

- 返回对象而不是 `true`：网关的响应封装会展开 `{ ...value }`，标量会被吞成 `{}`。
- HTTP 200 只代表**受理且已 flush**（服务端 `agent.followup` + `ctx.sessions.flush` 已经跑完），
  **不代表**客户端的本地卡片状态该立刻改——见 §3。

## 3. 答完之后，手机怎么知道成功（三条独立信道，别混）

| 信道 | 内容 | 用途 |
| --- | --- | --- |
| **HTTP 响应** | 上面那个 `{sessionId, questionId, answered:true}` | 「已受理」；网络失败可据此决定是否重试 |
| **卡片流**（推荐作为唯一真源） | `{kind:"card", ops:[{op:"card.answered", id:"<卡片 id>"}]}` | 卡片真的离队了：拿 `id` 与本地卡对账，把卡片标成「已答」。ds-bot 在 `channel.js` 里 `rt.cardFeed?.answered(question.id)` 触发（`card-feed.js:217`） |
| **团队流** | 该 Bot 的 `pending` 里这张卡消失（群卡：群里多一行「Question card answered: …」日志） | 列表红点/等卡计数会自己消失——不要自己本地删了又去猜 |

追问生效后的新消息走正常聊天流（`assistant-stream` / 消息帧），与本动作无关。

> 结论：**HTTP 200 只当"收到了"，卡片的最终状态以 `card.answered` 为准**；
> 若三条信道矛盾（200 但卡片流没有 answered），按 §4 的「状态错位」处置。

## 4. `bot/stale`（409）的三种情况与处置

服务端一处返回覆盖三种情况（`channel.js:449`）：

```js
if (question === undefined || question.id !== body.questionId) return fail('This question is no longer open', 'bot/stale')
```

| 情况 | 含义 | 是不是 bug |
| --- | --- | --- |
| `question === undefined` | 已经被答过 / 已被撤（`dismiss-question` 会删 `state.questions`） | 否，正常收尾 |
| `question.id !== body.questionId` | 客户端发上来的 id 与服务端在等的那张卡不一致 | **是**（客户端 bug 或状态错位） |

**客户端处置（必须先判后处置）**：

1. 收到 409 `bot/stale` 后，**先看卡片流里这个 id 还在不在**；
2. **还在** → 判「状态错位」，**刷新卡片帧**，不重试；
3. **不在** → 按「已答」收尾（把本地卡标成已答/移除），不重试；
4. 两种情况都**不重试**（重试不会成功）；
5. 例外要留痕：**卡片还在、用户确实点了选项、却收到 stale → 记一条诊断日志**。这种组合理论上不该发生
   （id 来自卡片本身），静默吞掉等于把「id 拼错 / 卡片过期」这类 bug 永久掩盖。

配套另两个码：

| 错误 | 含义 | 客户端怎么做 |
| --- | --- | --- |
| 409 `QUESTION_IN_FLIGHT` | 同一 `questionId` 已有一条在途（连点） | **忽略**（第一条的结果会自己回来），不要提示失败、不要重试 |
| 404 `TARGET_DENIED` | `sessionId` 不在可见团队里（越权/过期会话） | 刷新团队与卡片流；这是客户端状态问题，不是用户操作失败 |

## 5. 群卡与单聊的差异（**不一样，别当一样**）

服务端先走群卡，再走 Bot 卡（`channel.js:441-447`）：

```js
const inRoom = roomCardFor(body.sessionId, body.questionId, 'question')   // sessionId 必须是 roomId
if (inRoom !== undefined) { …answerRoomCard… }                            // 答回投到群
const question = rt.own(state.questions, sessionId)                      // 单聊：Bot 当前段/历史段
```

| 维度 | Bot 卡（单聊） | 群卡 |
| --- | --- | --- |
| `sessionId` | 该 Bot 的 `sessionId` 或 `parts[]` 之一 | **`roomId`**（不是成员的隐藏会话） |
| `questionId` | 必须精确等于 `question.id`，否则 `bot/stale` | **客户端同样必须精确**（卡片帧的 `id` 原文）；服务端另有单卡回退的实现细节，见 §8 脚注——**客户端不得依赖** |
| 归属校验 | 在可见团队的 bot 段链里 | `sessionId === room.id`（列表里只有以 group id 开头的房间会话） |
| 回执 | `card.answered` + `pending` 消失 | `card.answered` + 群日志一行 `Question card answered: …`（`channel.js:186-188`） |
| 错误码 | `bot/stale` / `bot/invalid` | **同一套 `bot/stale` / `bot/invalid`**，判法一致 |

## 6. 客户端该怎么接（给 iOSCoder）

1. **发现能力**：`GET /mobile/v1/info` → `capabilities.actions` 里有 `answer-question` 才显示"可作答"。
   注意：整份 `actions` 为空是**另一个条件**（`bridge.describe` 的 `version===1 && redactedText===true` 不满足），
   别把它和"动作没上线"混判。
2. **渲染**：卡片正文来自 bridge 的卡片帧（`kind:"card"`），问题卡带 `id`、`sessionId`、`questions[0].options[].label`。
3. **用户提交**：按 §1 组 payload，把用户点的 `label` **原样**放进 `selected`；自定义输入放 `custom`。
4. **成功**：拿到 200 后**不要立刻删本地卡**，等 `card.answered`（同 id）或一次卡片流 refresh；两者都没有再按 §4 处置。
5. **409 `bot/stale`**：按 §4 的两分支（在/不在）处置，**永不重试**。
6. **409 `QUESTION_IN_FLIGHT`**：静默忽略。
7. **网络超时/断连**：**可以重试一次**——服务端是「先认领、失败回滚」（`channel.js:449-460`：
   `delete state.questions[...]` 在 `await` 之前、catch 里 `??= question` 回滚），
   所以真正的投递失败会把卡放回去，重试会成功；已经答成功则回 `bot/stale`（按 §4 收尾）。
8. **群卡**：`sessionId` 用 `roomId`，其余一样；回执看群日志那一行。

## 7. 实现位置与用例

- `lib/mobile-v1/actions.mjs`：`fields` 增加 `answer-question: ['sessionId', 'questionId', 'answer']`；
  `actions()` 加分支（参数形状校验 → **归属校验** `TARGET_DENIED` → **in-flight 守卫** → 透传 `callTeam`）。
  `/info` 的 `actions` 与 `adapter.mjs` 的 `allowed` 都由 `MOBILE_ACTIONS` 派生，**不需要另改**。
- 用例：`test/mobile-v1-answer-question.test.mjs`（10 条）——能力位、逐字透传、更早分段、群卡、
  越权、`bot/stale`、连点、参数形状、真实 HTTP 面的 `/info`、夹具自检。
- 反向自证（各自 `exit 1`，定向变红）：
  1. 删掉 `fields` 里那条 → 9 条红（动作 403 / 能力位消失）；
  2. 删掉归属校验 → 只有「越权」那条红；
  3. 删掉 in-flight 守卫 → 只有「连点」那条红。
- 已知边界：`question-cancel`（撤回/跳过提问）**仍未迁**；`show_view` 的 `view-reply` 与本动作同构，另开单。

## 8. 两条容易踩的边界

### 8.1 `rpcId` 不参与提交

服务端 `channel.js:437-470` 的 `answer-question` 分支**没有任何一处读 `rpcId`**——它只认 `sessionId`、`questionId`、`answer`。`rpcId` 是旧协议 `question-requested` 的遗留字段，这条新路径用不到。

- **提交时不要传 `rpcId`**，更**不要**拿它当 `questionId` 传；
- 如果 UI 需要一个稳定的视图 id（SwiftUI 的 `.id(...)`），用 **`card.id`** 就够了（卡片帧的 `id` 就是 `question.id`），或者用别的局部唯一值——那是 UI 层的事，与提交无关。

### 8.2 `questionId` 必须精确匹配（群卡也一样，客户端不得"猜"）

客户端提交的 `questionId` **只能是卡片帧的 `id` 原文**：不裁剪、不改写、**不做模糊匹配、不做回退猜测**。

- Bot 卡：服务端严格比对 `question.id !== body.questionId` → 不匹配即 `bot/stale`（`channel.js:449`）；
- 群卡：客户端**同样**必须传精确 id。若客户端猜错，多卡房间会直接失败；单卡房间也可能"答对了但自己不知道答的是哪张"，出问题极难查。

> **脚注（服务端实现细节，客户端不得依赖）**：群卡的房间级查找 `roomCardFor` 里有
> `rt.roomCardOf(room.id, cardId) ?? (list.length === 1 ? list[0] : undefined)`（`channel.js:144`）——
> 即**房间里只有一张卡时**，传错 id 也会命中那张。这条回退唯一的安全护栏是种类比对
> （`channel.js:145`，`card.kind === kind`）：回退命中的也不会把 view 卡当 question 卡答，
> **但 id 仍然可能是错的**。这是给桌面端交互留的容错，**不是客户端的契约**：
> 房间里一旦出现第二张卡就失效，而且会让"id 发错了"这种 bug 静默通过。客户端按本节严格传精确 id。
