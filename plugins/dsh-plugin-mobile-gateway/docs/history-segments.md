# 多段会话（parts）与历史读取通道

> 起因：真机反馈「只有 Chief 这个 Bot 在手机上看不到旧历史」。
> 结论先说：**这不是一个丢帧/漏 paging 的 bug，而是一个模型不兼容问题**——手机的聊天窗口按 `seq` 判定身份与顺序，而 `seq` 只在**单个 Session（一段）内**唯一。
> 本文记录 parts 语义、各读通道现状、为什么 WS 那条通道**不能**靠拼接修好（附代码证据），以及三条可选修法。

---

## 1. parts 是什么

ds-bot 的一个 Bot 的聊天由**多个 DSH Session 串联**而成（宿主侧叫 segment / part）：

- `state.bots[botId].segments`：更早的段（数组，顺序即时间）
- `bots[botId].sessionId`：**当前段**（新的消息都落在这里）
- 投影给手机时（`ds-bot/src/host/channel.js:42-45` 的 `view()`）才拍平成 `{ sessionId, parts }`

实测（宿主 `~/.dsh/bot/state.json`）：全团队只有 Chief 有 2 个 segment + 1 个当前段，其余 Bot 为 0 或 1 段——所以这个问题天然只有主 Bot 会撞上。

`parts` 是**历史分段**，不是「同一会话的副本」：每段是一个独立 Session，**各自的 event `seq` 从 1 开始**。

## 2. 两条读历史通道，一条拼段一条不拼

| 通道 | 入口 | 分段行为 | 判据 |
| --- | --- | --- | --- |
| REST | `GET /mobile/v1/conversations/{id}/messages?cursor=` | **拼**：游标里带 `sessionId`，一页永远只来自一段，翻到底自动换到上一段 | `lib/mobile-v1/adapter.mjs:200 cursorFor`、`:205 history`、`:139 requireSession` |
| WS（旧协议） | `{"type":"history","sessionId":…,"beforeSeq":…}` | **不拼**：`sessionId` 原样转给宿主 `api.sessions.history`，段与段之间的边界就是 `hasMore:false` | `lib/index.mjs:1484-1496`（全文无 `parts` 命中） |

手机主聊天窗走的是第二条（`AppStore.swift:1999 requestHistoryPage` → `GatewayClient.requestHistory` → WS）。所以只有当前段可见。

## 3. 为什么 WS 这条通道**不能**靠「拼接」修好

关键在手机侧的合并模型——它不是「按到达顺序追加」，而是**按 `seq` 去重 + 按 `seq` 排序**：

```kotlin
// shared/.../facade/SharedHistoryStore.kt:206
require(page.all { it.sessionId == sessionId })          // 一条会话只有一个 sessionId
// :551-560  mergeHistoryPage
val records = linkedMapOf<Int, SessionEvent>()
page.forEach { records[it.seq] = it }                    // seq 当主键
live.forEach { records[it.seq] = it }                    // 实时 lane 覆盖同 seq
return records.values.sortedBy(SessionEvent::seq)        // 按 seq 排序
// :343-351  installSnapshot
val normalized = records.associateBy(SessionEvent::seq).values.sortedBy(SessionEvent::seq)
```

于是「把上一段的帧拼进同一页」必然违反两件事：

1. **重复/丢失**：两段 `seq` 都从 1 开始，同号事件在 `records[seq]` 里互相覆盖——上一段的一部分消息会**静默消失**；
2. **错序**：合并结果按 `seq` 排序，上一段的 `seq 4700` 会排到当前段 `seq 300` **之后**，旧消息显示在新消息下面。

这不是实现细节，是「一段 = 一个 seq 空间」与「一个窗口 = 一个 seq 空间」的冲突。

**边角也堵死了**（都验过）：

- **游标本身不是瓶颈**：KMP 的翻页游标其实优先用网关给的 `nextBeforeSeq`（`sync/HistoryReducer.kt:112,158`），所以「把段编进游标」是可行的；坏的是**窗口组成**，不是翻页。
- **负数 seq 也走不通**：`GatewayClient.requestHistory` 在发 `beforeSeq` 前有 `guard beforeSeq >= 0 else { return }`，负游标会让手机直接放弃继续翻页。
- **「旧段整体重编号」是唯一自洽的方案**：当前段的原始 `seq` 从 1 开始，要让旧段既排在前、又是非负数，就得把当前段也整体上移——那就必须**同时**改实时帧、快照 `cursor`、投影 `asOfSeq`、读标记……任何一处漏改都会让主 Bot 的实时聊天出现重复或错序。风险与收益不匹配。

## 4. 对的地方已经存在（重要）

手机**另一套聊天界面**（团队页 `TeamView.swift:962` / `WorkspaceView.swift:674` → `BridgeChatEngine`）走的就是 REST 那条，它本来就能翻旧段：

- 游标编码「哪一段 + 该段 `beforeSeq`」（`adapter.mjs:200`），一页只含一段；
- 跨段还带**归属校验**（`requireSession`：`[sessionId, ...parts]`，`:139`）；
- 消息 `id = "${sessionId}:${seq}"`（`projection.mjs:65`）→ **跨段天然不冲突**；
- 合并按 `id` 去重、**跨段按 `createdAt` 排序**（`BridgeChatMerge.kt:81-147`：只有同段才按 `seq` 排）。

即「正确的模型」在 App 里已经跑着，缺的是让**主聊天窗**也用它。

## 5. 三条可选修法

| 方案 | 内容 | 归属 | 风险 |
| --- | --- | --- | --- |
| **A 复用** | 主聊天窗对 Bot 会话改走 bridge 聊天（REST + cursor）或同一套合并模型 | iOS | 低（服务端已正确，网关零改动） |
| **B 对齐模型** | KMP 历史合并改成「`id` 去重 + 跨段按时间排序」，`seq` 只用于段内 | iOS（共享层） | 中（动的是所有会话的合并路径） |
| **C 网关重编号** | 多段会话把 `seq` 映射到 `段基址 + 原始 seq`，并同步改实时帧/快照 `cursor`/投影 `asOfSeq`/读标记 | 网关 | **高**（漏一处 = 主 Bot 聊天重复或错序） |
| **D 分段可见** | 把「更早分段」作为**独立会话行**暴露（`projectSessions` 不再把 parts 排除），手机当普通会话打开 | 网关（小） | 低，但 UX 是多一行；且需只读语义（旧段不应能继续发消息） |

**推荐 A**：服务端已经正确，把主聊天窗接上即可；**D 可以作为当晚的最小缓解**（如果接受「更早的历史挂在单独一行会话」的形态），但它需要先问清 App 对「只读会话」的支持，否则用户能在归档段里发消息。

## 6. 复现与验收

```sh
# 1) 确认这个 Bot 真的是多段
node -e 'const s=require(process.env.HOME+"/.dsh/bot/state.json");
for (const b of Object.values(s.bots)) if ((b.segments||[]).length) console.log(b.id, b.segments.length, b.sessionId)'

# 2) REST（正确）：翻到 cursor 用完，观察 sessionId 从当前段切到 parts[0]
curl -s -H "Authorization: Bearer $TOKEN" \
  "http://<host>:<port>/api/mobile/v1/conversations/<botId>/messages?limit=50" | jq '.sessionId, .cursor'

# 3) WS（现状）：同一 conversation 的当前段翻到底后 hasMore=false，不再跨段
```

验收判据（任一方案都必须全绿）：**同一窗口内没有重复、顺序不倒退、翻到最旧一段的尽头时 `hasMore=false` 正常收尾、跨段不越权**。

---

## 7. 决策（2026-10-27）：WS 跨段**不做**，改由客户端接入 REST + cursor

**决定**：不在 WS `type: history` 上做跨段拼接。`/info` 的 `capabilities.parts` **保持 `false`**——这个能力位在契约里的语义是「WS 历史可跨段翻页」，不是「投影里带 parts」；后者由行内 `parts` 字段本身表达（`ds-bot/src/host/channel.js:42-45`），不该用一个能力位重复表达。既然决定了 WS 路线不做，`false` 就是对的事实陈述。

**三条代码证据**（手机侧，决定性的）：

1. `dsh-mobile/shared/src/commonMain/kotlin/com/clarklevis/dsh/shared/facade/SharedHistoryStore.kt:206` —— `require(page.all { it.sessionId == sessionId })`：一页只允许一个 `sessionId`，且 App 会把事件 `sessionId` 归一化成会话 id → **段的身份在进窗口前就被抹掉了**。
2. 同文件 `:347` —— `installSnapshot` 里 `records.associateBy(SessionEvent::seq).values.sortedBy(SessionEvent::seq)`：`seq` 既是去重主键又是排序键。
3. 同文件 `:551-560` —— `mergeHistoryPage`：`linkedMapOf<Int, SessionEvent>()`，`page` 与 `live` 都按 `seq` 写入（live 覆盖），最后 `sortedBy(SessionEvent::seq)`。

两条边角（同样验过）：

- `dsh-mobile/.../Core/GatewayClient.swift:549` —— `guard beforeSeq >= 0 else { return }`：负游标会让手机**静默放弃**继续翻页。
- `dsh-mobile/shared/.../sync/HistoryReducer.kt:112` 与 `:158` —— 翻页游标**优先用网关的 `nextBeforeSequence`**，所以「把段编进游标」本身可行；瓶颈是**窗口组成**，不是翻页。

**为什么不能靠「整体重编号」兜**：当前段的原始 `seq` 从 1 起，旧段要既排在前、又非负，就只能把当前段整体上移；那就必须同时改实时帧、快照 `cursor`、投影 `asOfSeq`、读标记——漏一处就是主 Bot 实时聊天重复或错序，而这恰好是用户的主会话。风险与收益不匹配，故不取。

### 7.1 给接方案 A 的人（iOSCoder）的三个陷阱

1. **`MISSING_NEXT_CURSOR` 是隐蔽陷阱，已修（`0911e70`）：拿不出游标即降级 `hasMore:false`；用例 `test/history-cursor.test.mjs`。** 背景留档：`hasMore: true` 但 `nextBeforeSeq` 缺失时，KMP 会直接让**整次翻页失败**（`HistoryReducer.kt:158`），表现是「翻不动」而不是一条报错文本，极难查。
   **耦合不变量**：`historyPage`（`lib/index.mjs`）里 `hasMore` 与 `nextBeforeSeq` 必须**同时成立、同时不成立**——以后谁改这个返回形状，两个字段要一起看；拿不出游标时把 `hasMore` 一起降级，让「到头了」是真的。
   这条也是判据范式：任何能力位/游标字段遇到「语义上应该还有、但实际拿不出来」时，**降级成真实**，不要给客户端一个无法兑现的承诺。
2. **实时帧与历史两源合并**：REST 只给历史，新消息仍靠 WS。合并**必须复用 `BridgeChatMerge` 的现成语义**（按消息 `id` 去重、跨段按 `createdAt` 排序、只有同段才按 `seq`），不要新写一套——否则症状是「历史重复一遍」或「新消息排到旧消息下面」。
3. **发送/局部更新与 REST 的交互**：ACK、`requestId`、`localSubmission` 这些已有合并规则要跟着走，别让两条通道各自维护窗口。

### 7.2 备选 D（若 A 的实时通道接不顺就退这条）

把「更早分段」作为**独立会话行**暴露（`adapter.mjs` 的 `projectSessions` 不再把 `parts` 排除），手机当普通会话打开。上之前必须同时满足：

- **只读**：归档段绝不能继续发消息——发送会写进旧 Session，而 ds-bot 的视图读的是当前段，等于消息**凭空消失**。当前快照只有整体 `readOnly`，没有逐行只读，所以要么客户端承认一个逐会话只读标志，要么**网关侧直接拒收对非当前段的提交**（后者更稳，不依赖客户端配合）。
- **可区分**：标题/时间要能看出是哪一段，否则列表里出现两个同名「Chief」。
- **只取 `parts`，不取群成员隐藏会话**：`channel.js:49` 把 room 的成员隐藏会话和更早分段混着拼，room 路径**不得复用**这套。

---

## 8. WS 通道的跨段入口：`previousSessionId`（2026-10-27 落地）

WS `type:'history'` 仍然**一页只含一段**（`SharedHistoryStore.kt:206` 的 `require` 不受任何影响）。
新增的只是「本段到头了，上一段从哪进」这一个字段。

> **🔒 铁律（最容易接错的一条）：`nextBeforeSeq` 与 `previousSessionId` 互斥。**
> 同一帧里**永远不会同时出现**，也**不允许**出现：
> - 有 `nextBeforeSeq` → 说明**本段还有更早内容**，只翻本段，别换段；
> - 有 `previousSessionId` → 说明**本段已到头**，换段，且**不要带 `beforeSeq`**
>   （带了会从上一段的某个位置开始翻，而不是从该段最新一页开始——表现是「翻到旧段却缺最后几条」）。
> 两个都没有 → **真到头了**，停止翻页。
>
> 网关侧保证：`hasMore === true` 时绝不附 `previousSessionId`；附了 `previousSessionId` 的帧 `hasMore` 一定不是 true。

| 字段 | 含义 | 何时出现 |
| --- | --- | --- |
| `nextBeforeSeq` | **本段**还有更早内容，带着它再发一次 `history` | `hasMore === true` |
| `previousSessionId` | **本段**已经到头，换这个 `sessionId` 再发一次 `history` | `hasMore !== true` 且该 Bot 还有更早段 |

两者**互斥**：`hasMore` 为真时不会给 `previousSessionId`（否则客户端会在两段之间来回跳）；
`previousSessionId` 存在时 `hasMore` 一定不是 true。拿不出游标时 `historyPage` 已经把
`hasMore` 降级为 `false`（见 §7.1），那种情况同样属于「本段到头」，会照常给入口。

### 8.1 客户端怎么接（零归一：不需要构造任何 `SessionEvent`）

1. 打开 Bot 会话：`{"type":"history","sessionId":<当前段>,"maxMessages":…,"view":"conversation"}`（与今天完全一样）
2. 回应里 `hasMore === true` → 用 `nextBeforeSeq` 作 `beforeSeq` 继续翻**本段**（同今天）
3. 回应里 `hasMore === false` 且带 `previousSessionId` → 用 `{"type":"history","sessionId":<previousSessionId>}`
   **不带 `beforeSeq`** 再发一次，宿主会返回该段最新一页；把这一页**当作同一会话的延续**接在更早处
4. 最旧一段到头的回应里既没有 `nextBeforeSeq` 也没有 `previousSessionId` → **真到头了**，停止

要点：一页只含一段，所以「按 `sessionId + seq` 分桶」天然成立；**不要**把两段的 events 合成一页
去按 `seq` 全局排序（那正是同号覆盖 + 旧段排到新段后面的来源）。

### 8.2 归属校验（这条通道以前完全没有）

请求的 `sessionId` 现在先过一遍解析（名册取 ds-bot 的 `dsBotTeam`，与手机看到的是同一份）：

| 情况 | 处理 |
| --- | --- |
| 属于某个 **可见 Bot** 的段（`[ ...parts, sessionId ]`） | 放行，并按需给 `previousSessionId` |
| 属于某个**隐藏 Bot** 的段 | **拒绝** `SESSION_DENIED`（手机侧本来就看不到这个 Bot） |
| 名册里的**房间**本身 | 放行，但**不给分段入口** |
| 解析不出 Bot（普通会话 / 子代理 / 群成员隐藏会话） | **原样放行**——手机上的普通会话同样走这条 WS 读历史，严格白名单会直接打死它们 |

**故意没有做严格白名单**：那需要「手机能看见的会话集合」定义（名册 ∪ 群 ∪ 宿主会话列表），
而且新增会话要立刻可用（缓存边界会让刚建的会话被拒），风险大于收益。要做另立项。

**房间的 `parts` 不参与解析**：`channel.js:49` 把成员隐藏会话与更早分段混拼在一起，
拿它做分段会把别的成员的隐藏会话当成历史读出来（越权）。用例里专门钉了这条
（`test/history-segments.test.mjs` 的「绝不把房间的成员隐藏会话当成 Bot 段」）。

### 8.3 代码与用例

- 解析与策略：`lib/history-segments.mjs`（纯函数，`segmentsOf` / `resolveHistoryOwner` / `createHistoryOwner`）
- WS 接入：`lib/index.mjs` 的 `history` 分支 + `apply` 里的 `historyOwner`（服务缺席时解析器不生效，只是没有入口）
- 用例：`test/history-segments.test.mjs`（13 条：纯函数 5 + 通道 8）
- 反向验证（各自定向变红，exit 1）：删掉入口字段 → 两条跨段用例红；去掉 `hasMore === true` 守卫 →
  「段内还有更早内容时不给入口」红；把 `room.parts` 当分段吃进来 → 越权用例红
