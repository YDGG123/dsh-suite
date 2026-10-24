import crypto from 'node:crypto'

/**
 * 团队投影帧（B1）：读 ds-bot 发布的 `dsBotTeam` 服务，转成手机可消费的快照 + 增量流。
 *
 * 契约见 ds-bot `docs/roster-publish-v1.md`（v2，已冻结）：
 * - `snapshot()` 纯读、**不消耗 seq**，`snapshot.seq = head`；
 * - `delta` 带 `base`（= 订阅端已应用的最后一条 seq），不等于就重取快照；
 * - `patch` 是绝对值，合并安全；`add/update/remove` 是结构变更，立即发、且先冲刷待发 patch；
 * - 静态字段（名字/头像/角色/instructions…）只出现在快照与结构变更帧里。
 *
 * 网关这一层的职责（不新增第二份 host 真相）：
 * 1. 把 patch 再合并一次（400 ms），保证手机端每秒最多 ~2.5 帧（ds-bot 已节流，这里是保险）；
 * 2. 结构帧到来时先冲刷待发 patch，避免「先 patch 后 add」；
 * 3. 静态字段本地缓存一份，供 `snapshot()` 与新订阅者复用（头像 data URL 不重复拉）；
 * 4. 排序权威用网关自己的会话 `updatedAt`（契约 §9.3），以独立的 `order` 帧下发，
 *    **不占契约 seq**，也不污染 roster 帧；
 * 5. 服务缺席时降级：用 `/state` 投影出「名册快照」（无 activity/work/pending），
 *    帧上标 `degraded: true`，让手机明确知道实时状态不可用，而不是显示成「全部空闲」。
 *
 * Redaction：所有自由文本（名字、角色、instructions、preview、work.note…）在转发前
 * 过一遍网关本地的密钥替换器（与 ds-bot 共用 ~/.dsh/bot/secrets.json），
 * 该能力由网关自持，不进入契约、也不依赖 ds-bot 的 RPC。
 */

export const TEAM_FEED_VERSION = 1
export const PATCH_MERGE_MS = 400
export const FALLBACK_POLL_MS = 10_000
export const ORDER_POLL_MS = 15_000
export const MAX_OPS = 200

const STRUCTURAL_OPS = new Set(['bot.add', 'bot.update', 'bot.remove', 'room.add', 'room.update', 'room.remove', 'main.set'])
const PATCH_OPS = new Set(['bot.patch', 'room.patch'])
const BOT_TEXT_FIELDS = ['name', 'role', 'model', 'effort', 'workDir', 'instructions']
const ROOM_TEXT_FIELDS = ['name', 'notice', 'preview']
const WORK_TEXT_FIELDS = ['tool', 'target', 'said', 'note']
const LIST_BY_KIND = { bot: 'bots', room: 'rooms' }

const clone = value => (value === undefined ? undefined : JSON.parse(JSON.stringify(value)))
const isObject = value => !!value && typeof value === 'object' && !Array.isArray(value)

function normalizeOp(op) {
  if (!isObject(op) || typeof op.op !== 'string') return null
  const match = /^(bot|room)\.(add|update|patch|remove)$/.exec(op.op)
  if (match) {
    const [, entity, verb] = match
    if (typeof op.id !== 'string' || !op.id) return null
    if (verb === 'remove') return { op: op.op, id: op.id }
    const body = verb === 'patch' ? (isObject(op.set) ? op.set : null) : (isObject(op.entity) ? op.entity : null)
    if (!body) return null
    return verb === 'patch' ? { op: op.op, id: op.id, set: clone(body) } : { op: op.op, id: op.id, entity: clone(body) }
  }
  if (op.op === 'main.set') {
    const ids = Array.isArray(op.mainBotIds) ? op.mainBotIds.filter(id => typeof id === 'string') : null
    if (!ids) return null
    return { op: 'main.set', mainBotIds: ids }
  }
  return null
}

/** 逐字段替换，避免 JSON.stringify 往返把 data URL / 长文本放大。 */
async function redactFrame(frame, redact) {
  if (typeof redact !== 'function') return frame
  const sites = []
  const collect = (object, fields) => {
    if (!isObject(object)) return
    for (const field of fields) if (typeof object[field] === 'string' && object[field]) sites.push({ object, field })
  }
  const collectWork = work => {
    collect(work, WORK_TEXT_FIELDS)
    if (Array.isArray(work)) for (const item of work) collect(item, WORK_TEXT_FIELDS)
  }
  const collectEntity = (kind, entity) => {
    if (!isObject(entity)) return
    collect(entity, kind === 'bot' ? BOT_TEXT_FIELDS : ROOM_TEXT_FIELDS)
    collectWork(entity.work)
    if (Array.isArray(entity.approvals)) for (const approval of entity.approvals) collect(approval, ['tool', 'reason'])
  }
  if (frame.kind === 'snapshot') {
    for (const bot of frame.bots ?? []) collectEntity('bot', bot)
    for (const room of frame.rooms ?? []) collectEntity('room', room)
  } else if (frame.kind === 'delta') {
    for (const op of frame.ops ?? []) {
      if (!isObject(op.entity) && !isObject(op.set)) continue
      const kind = op.op.startsWith('room.') ? 'room' : 'bot'
      collectEntity(kind, isObject(op.entity) ? op.entity : op.set)
      if (isObject(op.set)) for (const item of Array.isArray(op.set.work) ? op.set.work : []) collect(item, ['tool', 'target', 'said', 'note'])
    }
  } else if (frame.kind === 'order') {
    return frame
  }
  if (sites.length === 0) return frame
  const texts = sites.map(({ object, field }) => object[field])
  const redacted = await redact(texts)
  sites.forEach(({ object, field }, index) => {
    if (typeof redacted?.[index] === 'string') object[field] = redacted[index]
  })
  return frame
}

export function createTeamFeed({
  resolveService = () => null,
  fallback = null,
  loadSessions = null,
  redact = null,
  log = () => {},
  now = Date.now,
  mergeMs = PATCH_MERGE_MS,
  pollMs = FALLBACK_POLL_MS,
  orderMs = ORDER_POLL_MS,
} = {}) {
  const localInstanceId = `gateway-${crypto.randomUUID()}`
  const subscribers = new Set()
  const staticBots = new Map()
  const staticRooms = new Map()
  let service = null
  let detach = null
  let instanceId = localInstanceId
  let head = 0            // 已发出的最后一条契约 seq（快照不消耗）
  let lastServiceSeq = 0  // ds-bot 侧最近一次看到的 seq（合并 patch 用）
  let fallbackSeq = 0     // 降级模式自造的 seq 空间
  let orderSeq = 0
  let pending = new Map() // `${kind}:${id}` → { op, id, set }
  // 合并窗口内最后一帧的 seq：冲刷时用它当本帧 seq，才能排在随后到达的结构帧之前
  // （用「最近的 seq」会把结构帧自己要用的 seq 占掉，结构帧就发不出去）。
  let pendingSeq = 0
  let timer = null
  let queue = Promise.resolve()
  let tick = null
  let lastOrder = ''
  let lastRosterKey = ''
  let disposed = false

  const degraded = () => service == null

  function emit(frame) {
    for (const listener of subscribers) {
      try { listener(frame) } catch (error) { log(`team-feed subscriber failed: ${error?.message ?? error}`) }
    }
  }

  async function stampUpdatedAt(entities) {
    if (typeof loadSessions !== 'function' || !entities.length) return
    let items = []
    try { items = (await loadSessions()) ?? [] } catch { items = [] }
    if (!Array.isArray(items)) items = []
    const updatedAt = new Map()
    for (const item of items) {
      if (typeof item?.sessionId === 'string' && Number.isSafeInteger(item.updatedAt)) updatedAt.set(item.sessionId, item.updatedAt)
    }
    for (const entity of entities) {
      const stamp = updatedAt.get(entity.sessionId) ?? updatedAt.get(entity.id)
      if (Number.isSafeInteger(stamp)) entity.updatedAt = stamp
    }
  }

  /**
   * 排序权威：网关自己的会话列表（与桌面 sidebar 同源），契约 §9.3。
   * 只发 `sessions: {sessionId: updatedAt}`，手机按实体 `sessionId` 匹配；
   * 群聊的 sessionId 就是 room.id，所以一张表够用。不占契约 seq。
   */
  async function orderKeys() {
    if (typeof loadSessions !== 'function') return null
    let items = []
    try { items = (await loadSessions()) ?? [] } catch { return null }
    if (!Array.isArray(items)) return null
    const sessions = {}
    for (const item of items) {
      if (typeof item?.sessionId !== 'string' || !Number.isSafeInteger(item.updatedAt)) continue
      sessions[item.sessionId] = item.updatedAt
    }
    return { sessions }
  }

  async function maybeOrder() {
    const keys = await orderKeys()
    if (!keys) return
    const signature = JSON.stringify(keys)
    if (signature === lastOrder) return
    lastOrder = signature
    const frame = { v: TEAM_FEED_VERSION, kind: 'order', instanceId, seq: head, orderSeq: ++orderSeq, at: now(), sessions: keys.sessions,
      ...(degraded() ? { degraded: true } : {}) }
    emit(frame)
  }

  function normalizeSnapshot(raw) {
    const bots = Array.isArray(raw?.bots) ? raw.bots.filter(isObject) : []
    const rooms = Array.isArray(raw?.rooms) ? raw.rooms.filter(isObject) : []
    const mainBotIds = Array.isArray(raw?.mainBotIds) ? raw.mainBotIds.filter(id => typeof id === 'string') : []
    const frame = {
      v: TEAM_FEED_VERSION, kind: 'snapshot',
      instanceId: typeof raw?.instanceId === 'string' && raw.instanceId ? raw.instanceId : instanceId,
      seq: Number.isSafeInteger(raw?.seq) ? raw.seq : head,
      at: Number.isSafeInteger(raw?.at) ? raw.at : now(),
      // 契约 §4：mainBotId ≡ mainBotIds[0] ?? null，两处同源。
      mainBotId: mainBotIds[0] ?? null,
      mainBotIds,
      bots, rooms,
      pending: Array.isArray(raw?.pending) ? raw.pending.filter(isObject) : [],
    }
    for (const bot of bots) staticBots.set(bot.id, clone(bot))
    for (const room of rooms) staticRooms.set(room.id, clone(room))
    // avatar/color 属于静态字段：随快照进入本地缓存，新订阅者靠快照拿到，增量帧不再重复传。
    if (typeof frame.instanceId === 'string') instanceId = frame.instanceId
    if (Number.isSafeInteger(frame.seq)) { head = frame.seq; lastServiceSeq = frame.seq }
    return frame
  }

  /** 服务缺席时的降级快照：只有名册（名字/角色/成员/置顶），没有任何实时态。 */
  async function fallbackSnapshot() {
    if (!fallback) throw new Error('team feed is unavailable: ds-bot did not publish dsBotTeam')
    const state = await fallback.state()
    const bots = []
    const rooms = []
    const mainBotIds = Array.isArray(state?.mainBotIds) ? state.mainBotIds.filter(id => typeof id === 'string') : []
    const botIds = new Set()
    for (const bot of Array.isArray(state?.bots) ? state.bots : []) {
      if (typeof bot?.id !== 'string' || typeof bot?.sessionId !== 'string') continue
      botIds.add(bot.id)
      // 降级名册刻意**不写 `activity`**：契约的枚举里没有 unknown，写 idle 就是谎报
      // 「全部空闲」（联调时最难分辨的假象）。缺字段 + `degraded: true` 才是诚实的表达；
      // 同理不写 instructions / createdAt / notice 这些拿不到的占位值。
      bots.push({
        id: bot.id, kind: 'bot', name: String(bot.name ?? ''), role: String(bot.role ?? ''),
        ...(bot.model ? { model: String(bot.model) } : {}), ...(bot.effort ? { effort: String(bot.effort) } : {}),
        main: mainBotIds.includes(bot.id), pinned: bot.pinned === true,
        ...(bot.hidden === true ? { hidden: true } : {}),
        sessionId: bot.sessionId, parts: Array.isArray(bot.parts) ? bot.parts.slice(0, 200) : [],
        work: {}, approvals: [], pending: [], waiting: { bots: [], rooms: [], for: [] },
      })
      staticBots.set(bot.id, clone(bots.at(-1)))
    }
    for (const room of Array.isArray(state?.rooms) ? state.rooms : []) {
      if (typeof room?.id !== 'string') continue
      rooms.push({
        id: room.id, kind: 'room', name: String(room.name ?? ''), pinned: room.pinned === true,
        members: (Array.isArray(room.members) ? room.members : []).filter(id => botIds.has(id)),
        admin: typeof room.admin === 'string' ? room.admin : null,
        mode: room.mode === 'everyone' ? 'everyone' : 'admin',
        work: [], pending: [],
      })
      staticRooms.set(room.id, clone(rooms.at(-1)))
    }
    await stampUpdatedAt([...bots, ...rooms])
    return {
      v: TEAM_FEED_VERSION, kind: 'snapshot', instanceId, seq: fallbackSeq, at: now(),
      mainBotId: mainBotIds[0] ?? null, mainBotIds, bots, rooms, pending: [],
      degraded: true,
    }
  }

  async function snapshot() {
    let frame
    // 没订阅者时也允许直接取快照（服务器首发就是这条路），所以这里补一次 bind。
    if (!service) bind()
    if (service) {
      let raw
      try { raw = service.snapshot() } catch (error) {
        log(`team-feed: dsBotTeam.snapshot failed (${error?.message ?? error}), falling back to the roster projection`)
        try { detach?.() } catch {}
        detach = null; service = null; instanceId = localInstanceId; head = 0
      }
      if (service) {
      frame = normalizeSnapshot(raw)
      await stampUpdatedAt(frame.bots)
      // static 缓存也补上 updatedAt，避免同一 bot 两次快照排序键不一致。
      for (const bot of frame.bots) { const cached = staticBots.get(bot.id); if (cached && bot.updatedAt) cached.updatedAt = bot.updatedAt }
      }
    }
    if (!frame) frame = await fallbackSnapshot()
    return redactFrame(frame, redact)
  }

  /** 冲刷合并窗口里的 patch。seq 取窗口内最后一帧的 seq，且必须大于当前 head。 */
  function flushPending() {
    if (timer) { clearTimeout(timer); timer = null }
    if (pending.size === 0) return
    const ops = [...pending.values()]
    pending = new Map()
    const seq = service ? Math.max(pendingSeq, head + 1) : Math.max(++fallbackSeq, head + 1)
    pendingSeq = 0
    if (seq <= head) return // 防御：seq 不前进就不发，免得订阅端 base 判断失效
    const base = head
    head = seq
    emit({ v: TEAM_FEED_VERSION, kind: 'delta', instanceId, seq, base, at: now(), ops })
  }

  function scheduleFlush() {
    if (timer) return
    timer = setTimeout(() => { timer = null; flushPending() }, mergeMs)
    timer.unref?.()
  }

  // 契约 §4 的静/动边界：静态字段（含 avatar）只允许出现在 snapshot / add / update，
  // patch 只带易变字段。生产者也可能会把静态字段塞进 patch，这里统一裁掉，
  // 避免头像这类大字段进入每秒变化的高频路径（一次 data URL 可能上百 KB）。
  const STATIC_ONLY = new Set(['avatar', 'color', 'name', 'role', 'model', 'effort', 'workDir', 'instructions',
    'main', 'pinned', 'hidden', 'createdAt', 'members', 'admin', 'mode', 'notice', 'sessionId', 'parts'])
  function stripStatic(set) {
    const out = {}
    for (const [key, value] of Object.entries(set ?? {})) if (!STATIC_ONLY.has(key)) out[key] = value
    return out
  }

  function mergePatch(op, seq) {
    const key = `${op.op.startsWith('room.') ? 'room' : 'bot'}:${op.id}`
    if (Number.isSafeInteger(seq)) pendingSeq = Math.max(pendingSeq, seq)
    const clean = stripStatic(op.set)
    if (Object.keys(clean).length === 0) return
    const existing = pending.get(key)
    if (existing) { Object.assign(existing.set, clean); return }
    pending.set(key, { op: op.op, id: op.id, set: clean })
  }

  async function ingest(frame) {
    if (disposed || !isObject(frame) || frame.v !== TEAM_FEED_VERSION) return
    if (frame.instanceId && frame.instanceId !== instanceId && service) {
      // 实例变了（host 重启）：按契约丢弃增量，等订阅端重取快照。
      instanceId = frame.instanceId
      head = 0
      lastServiceSeq = 0
      pending = new Map()
      pendingSeq = 0
    }
    if (frame.kind === 'snapshot') {
      pending = new Map()
      pendingSeq = 0
      if (timer) { clearTimeout(timer); timer = null }
      const normalized = normalizeSnapshot(frame)
      emit(await redactFrame(normalized, redact))
      return
    }
    if (frame.kind !== 'delta') return
    // 契约 §6：入方向也要对齐——本地已消费的水位是 lastServiceSeq（不是转发出去的 head，
    // 合并窗口会让 head 暂时落后）。base 对不上说明中间丢了帧，丢弃并重取快照，
    // 把重同步局部化；否则会把错位的增量继续转给手机，手机只能逐帧丢弃再反复取快照。
    if (Number.isSafeInteger(frame.base) && frame.base !== lastServiceSeq) {
      log(`team-feed: delta base ${frame.base} != local seq ${lastServiceSeq}, resyncing from snapshot`)
      pending = new Map()
      pendingSeq = 0
      if (timer) { clearTimeout(timer); timer = null }
      if (service) {
        try { emit(await redactFrame(normalizeSnapshot(service.snapshot()), redact)) } catch (error) { log(`team-feed: resync snapshot failed: ${error?.message ?? error}`) }
      }
      return
    }
    if (Number.isSafeInteger(frame.seq)) lastServiceSeq = frame.seq
    const ops = (Array.isArray(frame.ops) ? frame.ops : []).map(normalizeOp).filter(Boolean)
    if (ops.length === 0) return
    if (ops.length > MAX_OPS) {
      // 防御：超大帧改发快照，别让手机处理一帧上千条 op（契约 §4）。
      pending = new Map()
      if (timer) { clearTimeout(timer); timer = null }
      emit(await redactFrame(normalizeSnapshot(service.snapshot()), redact))
      return
    }
    const structural = ops.filter(op => STRUCTURAL_OPS.has(op.op))
    const patches = ops.filter(op => PATCH_OPS.has(op.op))
    const rest = ops.filter(op => !STRUCTURAL_OPS.has(op.op) && !PATCH_OPS.has(op.op))
    const carriesStructure = structural.length > 0 || rest.length > 0
    // 生产者会把「turn 进行中的 patch」和「store.save 触发的结构变更」合进同一帧，很常见。
    // 这种帧**整体转发**、其中的 patch 不进合并窗口：否则 mergePatch 会用本帧的 seq 设 pendingSeq，
    // flushPending 又以同一个 seq 发出 patch 帧（head 被推到本帧 seq），随后结构帧的
    // `seq <= head` 判断就把结构 op 整条丢掉——干活期间的改名/改成员/置顶会长期不更新，
    // 而且 3s reconcile 不会补发，只能等下一次纯结构帧或重连。
    //
    // ⚠️ 前提（别再混用两个 seq 空间）：转发出去的 seq 空间属于生产者（ds-bot 的单调 seq），
    // 合并窗口只是把多帧 patch 压成一帧；**压出来的那一帧借的是窗口内最后一帧的 seq**，
    // 因此它永远只能出现在「该 seq 对应的帧」位置上——所以带结构 op 的帧不能再压。
    if (!carriesStructure) {
      for (const op of patches) mergePatch(op, frame.seq)
      scheduleFlush()
      return
    }
    // 结构优先：先冲刷**之前帧**待发的 patch，再整体转发本帧（ops 保持原顺序）。
    flushPending()
    const seq = Number.isSafeInteger(frame.seq) ? frame.seq : lastServiceSeq
    if (seq <= head) {
      // 防御：seq 不前进就没法安全转发（消费者会当成重复帧），改发快照对齐。
      if (service) {
        try { emit(await redactFrame(normalizeSnapshot(service.snapshot()), redact)) } catch (error) { log(`team-feed: realign snapshot failed: ${error?.message ?? error}`) }
      }
      return
    }
    const base = head
    head = seq
    emit(await redactFrame({ v: TEAM_FEED_VERSION, kind: 'delta', instanceId, seq, base: Number.isSafeInteger(frame.base) ? frame.base : base, at: Number.isSafeInteger(frame.at) ? frame.at : now(), ops }, redact))
    return
  }

  function enqueue(frame) {
    queue = queue.then(() => ingest(frame)).catch(error => log(`team-feed ingest failed: ${error?.message ?? error}`))
    return queue
  }

  /** 降级模式的结构轮询：只有订阅者时跑，diff 成 add/update/remove。 */
  async function pollFallback() {
    if (!fallback) return
    try {
      const next = await snapshot()
      const entities = [...next.bots.map(bot => ['bot', bot]), ...next.rooms.map(room => ['room', room])]
      const key = JSON.stringify(entities.map(([kind, entity]) => [kind, entity.id, entity.name, entity.members, entity.admin, entity.mode, entity.pinned, entity.sessionId]))
      if (lastRosterKey && key !== lastRosterKey) {
        const previous = new Map(JSON.parse(lastRosterKey).map(([kind, id]) => [`${kind}:${id}`, true]))
        const ops = []
        for (const [kind, entity] of entities) {
          const known = previous.has(`${kind}:${entity.id}`)
          ops.push({ op: `${kind}.${known ? 'update' : 'add'}`, id: entity.id, entity: clone(entity) })
        }
        const present = new Set(entities.map(([kind, entity]) => `${kind}:${entity.id}`))
        for (const key of previous.keys()) if (!present.has(key)) { const [kind, id] = key.split(':'); ops.push({ op: `${kind}.remove`, id }) }
        if (ops.length) {
          const seq = ++fallbackSeq
          const frame = { v: TEAM_FEED_VERSION, kind: 'delta', instanceId, seq, base: head, at: now(), ops, degraded: true }
          head = seq
          emit(frame)
        }
      }
      lastRosterKey = key
      await maybeOrder()
    } catch (error) {
      log(`team-feed fallback poll failed: ${error?.message ?? error}`)
    }
  }

  function bind() {
    if (disposed) return
    const next = (() => { try { return resolveService() } catch { return null } })()
    if (next && next !== service && typeof next.subscribe === 'function') {
      try { detach?.() } catch {}
      service = next
      instanceId = typeof next.instanceId === 'string' && next.instanceId ? next.instanceId : localInstanceId
      try { head = Number.isSafeInteger(next.seq?.()) ? next.seq() : 0 } catch { head = 0 }
      lastServiceSeq = head
      try {
        detach = next.subscribe(frame => { enqueue(frame) })
      } catch (error) {
        log(`team-feed subscribe failed: ${error?.message ?? error}`)
        detach = null
      }
      log(`team-feed: subscribed dsBotTeam (instanceId=${instanceId}, seq=${head})`)
      return
    }
    if (!next && service) {
      // 服务消失（ds-bot 卸载/重启）：退回降级名册，并让订阅端重取快照。
      try { detach?.() } catch {}
      detach = null; service = null; instanceId = localInstanceId; head = 0
      log('team-feed: dsBotTeam disappeared, serving degraded roster')
    }
  }

  function tickOnce() {
    if (disposed || subscribers.size === 0) return
    bind()
    if (service) maybeOrder()
    else pollFallback()
  }

  function start() {
    if (disposed || tick) return
    bind()
    tick = setInterval(tickOnce, service ? orderMs : pollMs)
    tick.unref?.()
  }

  function stop() {
    if (tick) { clearInterval(tick); tick = null }
    if (timer) { clearTimeout(timer); timer = null }
    if (detach) { try { detach() } catch {}; detach = null }
    service = null
    pending = new Map()
    lastRosterKey = ''
    lastOrder = ''
  }

  return {
    get instanceId() { return instanceId },
    get seq() { return head },
    get degraded() { return degraded() },
    /// 源服务是否在位（活探 cordis 服务，与「当前有没有订阅者」无关）。
    /// `/info` 的 `teamDegraded` 必须用这个：`degraded` 表达的是「此刻正在降级供数」，
    /// 无订阅者时自然为真，用它做健康判读会误报（真机踩过）。
    get sourceAvailable() {
      try { return resolveService() != null } catch { return false }
    },
    snapshot,
    subscribe(listener) {
      if (typeof listener !== 'function') throw new TypeError('team feed listener must be a function')
      subscribers.add(listener)
      if (subscribers.size === 1) start()
      return () => {
        subscribers.delete(listener)
        if (subscribers.size === 0) stop()
      }
    },
    dispose() {
      if (disposed) return
      disposed = true
      subscribers.clear()
      stop()
    },
  }
}
