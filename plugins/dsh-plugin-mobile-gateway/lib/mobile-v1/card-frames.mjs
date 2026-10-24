import crypto from 'node:crypto'

/**
 * 卡片帧（B2）：承接 ds-bot 自研卡（ask_user / show_view / 密钥卡）的投影。
 *
 * 为什么不复用 roster 帧：卡片正文（问题、选项、表单）比实时状态大一个量级，
 * 混进每秒变化的 roster 流会拖慢手机端的团队页；契约 §8 把卡片单列一条流。
 *
 * 两条来源：
 * 1. 正式来源 `dsBotCards` 服务（ds-bot 侧任务 3 发布，形状见 `CARD_SERVICE_CONTRACT`）；
 * 2. 降级来源：ds-bot 还没发布服务时，用团队帧里的 `pending`（**只有类型与时间，没有正文**）
 *    造「占位卡」——手机会显示「有 1 张卡在等你」，点进去仍要靠网关原有的
 *    `question-requested` 通道拿正文。占位卡带 `placeholder: true`，不会被误当成可答复卡片。
 *
 * 群聊语境：每张卡都带 `botId` / `sessionId` / `roomId?` / `group`，
 * 群里出的卡能用 roomId 归到群会话行上（这是 §9 点出的手机端缺口）。
 */

export const CARD_FRAMES_VERSION = 1
export const CARD_POLL_MS = 5_000

export const CARD_SERVICE_CONTRACT = Object.freeze({
  v: 1,
  shape: 'readonly { instanceId, seq(), snapshot(): {seq, at, cards[]}, subscribe(fn): () => void }',
  kinds: ['question', 'view', 'secret'],
  ops: ['card.shown', 'card.answered', 'card.cleared'],
})

const isObject = value => !!value && typeof value === 'object' && !Array.isArray(value)
const clone = value => (value === undefined ? undefined : JSON.parse(JSON.stringify(value)))

function cardTextSites(card) {
  const sites = []
  const push = (object, fields) => {
    if (!isObject(object)) return
    for (const field of fields) if (typeof object[field] === 'string' && object[field]) sites.push({ object, field })
  }
  push(card, ['title', 'text'])
  push(card.view, ['title', 'text', 'body'])
  push(card.secret, ['name', 'description'])
  for (const question of Array.isArray(card.questions) ? card.questions : []) {
    push(question, ['question', 'title', 'description'])
    for (const option of Array.isArray(question.options) ? question.options : []) push(option, ['label', 'description'])
  }
  return sites
}

async function redactCards(cards, redact) {
  if (typeof redact !== 'function') return cards
  const sites = cards.flatMap(cardTextSites)
  if (sites.length === 0) return cards
  const redacted = await redact(sites.map(({ object, field }) => object[field]))
  sites.forEach(({ object, field }, index) => {
    if (typeof redacted?.[index] === 'string') object[field] = redacted[index]
  })
  return cards
}

/** 归一化一张卡：只保留契约字段，未知字段丢弃（上游多给字段也不让手机端崩）。 */
export function normalizeCard(raw, { now = Date.now } = {}) {
  if (!isObject(raw) || typeof raw.id !== 'string' || !raw.id) return null
  const kind = raw.kind === 'view' || raw.kind === 'secret' ? raw.kind : 'question'
  const card = {
    id: raw.id,
    kind,
    at: Number.isSafeInteger(raw.at) ? raw.at : now(),
    ...(typeof raw.botId === 'string' && raw.botId ? { botId: raw.botId } : {}),
    ...(typeof raw.sessionId === 'string' && raw.sessionId ? { sessionId: raw.sessionId } : {}),
    ...(typeof raw.roomId === 'string' && raw.roomId ? { roomId: raw.roomId, group: true } : {}),
    ...(raw.placeholder === true ? { placeholder: true } : {}),
  }
  if (kind === 'question') {
    const questions = (Array.isArray(raw.questions) ? raw.questions : [])
      .filter(question => isObject(question) && typeof question.question === 'string')
      .slice(0, 20)
      .map(question => ({
        id: typeof question.id === 'string' && question.id ? question.id : crypto.randomUUID(),
        question: question.question,
        multiple: question.multiple === true,
        ...(typeof question.description === 'string' ? { description: question.description } : {}),
        ...(question.custom === true ? { custom: true } : {}),
        // 选项 label 是答复时的权威标识（网关原协议要求逐字一致），不做裁剪。
        options: (Array.isArray(question.options) ? question.options : [])
          .filter(option => isObject(option) && typeof option.label === 'string')
          .slice(0, 50)
          .map(option => ({ label: option.label, ...(typeof option.description === 'string' ? { description: option.description } : {}) })),
      }))
    if (questions.length === 0) return null
    card.questions = questions
    card.approval = raw.approval === true
  } else if (kind === 'view') {
    if (!isObject(raw.view)) return null
    card.view = {
      ...(typeof raw.view.title === 'string' ? { title: raw.view.title } : {}),
      ...(typeof raw.view.text === 'string' ? { text: raw.view.text } : {}),
      ...(typeof raw.view.body === 'string' ? { body: raw.view.body } : {}),
    }
    if (!card.view.title && !card.view.text && !card.view.body) return null
  } else {
    if (!isObject(raw.secret)) return null
    card.secret = {
      ...(typeof raw.secret.name === 'string' ? { name: raw.secret.name } : {}),
      ...(typeof raw.secret.description === 'string' ? { description: raw.secret.description } : {}),
      // 值永远不下发；手机只负责收集后回投。
      save: raw.secret.save !== false,
    }
    if (!card.secret.name && !card.secret.description) return null
  }
  return card
}

export function createCardFrames({ resolveService = () => null, teamFeed = null, redact = null, log = () => {}, now = Date.now, pollMs = CARD_POLL_MS } = {}) {
  const localInstanceId = `gateway-cards-${crypto.randomUUID()}`
  const subscribers = new Set()
  let service = null
  let detach = null
  let instanceId = localInstanceId
  let head = 0
  let lastServiceSeq = 0
  let fallbackSeq = 0
  let tick = null
  let queue = Promise.resolve()
  let disposed = false
  let lastPlaceholders = new Map()

  const emit = frame => {
    for (const listener of subscribers) {
      try { listener(frame) } catch (error) { log(`card-frames subscriber failed: ${error?.message ?? error}`) }
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
      try { detach = next.subscribe(frame => enqueue(frame)) } catch (error) { log(`card-frames subscribe failed: ${error?.message ?? error}`); detach = null }
      log(`card-frames: subscribed dsBotCards (instanceId=${instanceId})`)
    } else if (!next && service) {
      try { detach?.() } catch {}
      detach = null; service = null; instanceId = localInstanceId; head = 0
      log('card-frames: dsBotCards disappeared, serving placeholder cards')
    }
  }

  /** 降级：把团队帧的 pending（类型+时间，无正文）摊成占位卡。 */
  async function placeholderSnapshot() {
    if (!teamFeed) return { cards: [] }
    const frame = await teamFeed.snapshot()
    const cards = []
    const push = (item, owner) => {
      if (!isObject(item) || typeof item.kind !== 'string') return
      const sessionId = typeof item.sessionId === 'string' ? item.sessionId : owner.sessionId
      if (!sessionId) return
      const id = `pending:${owner.id}:${item.kind}:${sessionId}`
      cards.push({ id, kind: item.kind === 'view' ? 'view' : item.kind === 'secret' ? 'secret' : 'question', placeholder: true,
        at: Number.isSafeInteger(item.at) ? item.at : now(),
        ...(owner.id ? { botId: owner.id } : {}), sessionId,
        ...(typeof item.roomId === 'string' ? { roomId: item.roomId, group: true } : {}),
        questions: item.kind === 'question' ? [] : undefined,
      })
    }
    for (const bot of frame.bots ?? []) for (const item of bot.pending ?? []) push(item, { id: bot.id, sessionId: bot.sessionId })
    for (const room of frame.rooms ?? []) for (const item of room.pending ?? []) push(item, { id: room.id, sessionId: room.id })
    for (const item of frame.pending ?? []) push(item, { id: typeof item.botId === 'string' ? item.botId : '', sessionId: '' })
    for (const card of cards) if (!card.questions) delete card.questions
    return { cards, degraded: true }
  }

  function normalizeSnapshot(raw) {
    const cards = (Array.isArray(raw?.cards) ? raw.cards : []).map(card => normalizeCard(card, { now })).filter(Boolean)
    if (typeof raw?.instanceId === 'string' && raw.instanceId) instanceId = raw.instanceId
    const seq = Number.isSafeInteger(raw?.seq) ? raw.seq : head
    head = seq
    lastServiceSeq = seq
    return { v: CARD_FRAMES_VERSION, kind: 'card-snapshot', instanceId, seq, at: Number.isSafeInteger(raw?.at) ? raw.at : now(), cards }
  }

  async function snapshot() {
    let frame
    if (!service) bind()
    if (service) {
      let raw
      try { raw = service.snapshot() } catch (error) { throw new Error(`dsBotCards.snapshot failed: ${error?.message ?? error}`) }
      frame = normalizeSnapshot(raw)
    } else {
      const derived = await placeholderSnapshot()
      // 占位卡没有正文，只有归属与类型；seq 用降级空间自增，不与契约 seq 混。
      frame = { v: CARD_FRAMES_VERSION, kind: 'card-snapshot', instanceId, seq: fallbackSeq, at: now(), cards: derived.cards,
        ...(derived.degraded ? { degraded: true } : {}) }
      lastPlaceholders = new Map(derived.cards.map(card => [card.id, card]))
    }
    return redactCards(frame.cards, redact).then(() => frame)
  }

  async function ingest(frame) {
    if (disposed || !isObject(frame) || frame.v !== CARD_FRAMES_VERSION) return
    if (frame.kind === 'card-snapshot') {
      const normalized = normalizeSnapshot(frame)
      await redactCards(normalized.cards, redact)
      emit(normalized)
      return
    }
    if (frame.kind !== 'card') return
    if (Number.isSafeInteger(frame.seq)) lastServiceSeq = frame.seq
    const ops = (Array.isArray(frame.ops) ? frame.ops : []).flatMap(op => {
      if (!isObject(op) || !['card.shown', 'card.answered', 'card.cleared'].includes(op.op) || typeof op.id !== 'string') return []
      if (op.op === 'card.shown') {
        const card = normalizeCard(op.card, { now })
        return card ? [{ op: 'card.shown', id: op.id, card }] : []
      }
      return [{ op: op.op, id: op.id }]
    })
    if (ops.length === 0) return
    const seq = Number.isSafeInteger(frame.seq) ? frame.seq : ++lastServiceSeq
    if (seq <= head) return
    head = seq
    const out = { v: CARD_FRAMES_VERSION, kind: 'card', instanceId, seq, base: Number.isSafeInteger(frame.base) ? frame.base : head - 1,
      at: Number.isSafeInteger(frame.at) ? frame.at : now(), ops }
    for (const op of ops) if (op.card) await redactCards([op.card], redact)
    emit(out)
  }

  function enqueue(frame) {
    queue = queue.then(() => ingest(frame)).catch(error => log(`card-frames ingest failed: ${error?.message ?? error}`))
    return queue
  }

  /** 降级轮询：占位卡的 shown/cleared 由团队 pending 的增减推导。 */
  async function pollFallback() {
    if (!teamFeed || service) return
    try {
      const derived = await placeholderSnapshot()
      const next = new Map(derived.cards.map(card => [card.id, card]))
      const ops = []
      for (const [id, card] of next) if (!lastPlaceholders.has(id)) ops.push({ op: 'card.shown', id, card })
      for (const id of lastPlaceholders.keys()) if (!next.has(id)) ops.push({ op: 'card.cleared', id })
      lastPlaceholders = next
      if (ops.length === 0) return
      const seq = ++fallbackSeq
      const frame = { v: CARD_FRAMES_VERSION, kind: 'card', instanceId, seq, base: head, at: now(), ops, degraded: true }
      head = seq
      emit(frame)
    } catch (error) {
      log(`card-frames fallback poll failed: ${error?.message ?? error}`)
    }
  }

  function start() {
    if (disposed || tick) return
    bind()
    tick = setInterval(() => { bind(); pollFallback() }, pollMs)
    tick.unref?.()
  }

  function stop() {
    if (tick) { clearInterval(tick); tick = null }
    if (detach) { try { detach() } catch {}; detach = null }
    service = null
    lastPlaceholders = new Map()
  }

  return {
    get instanceId() { return instanceId },
    get seq() { return head },
    get degraded() { return service == null },
    /// 源服务是否在位（与订阅状态无关，理由同 team-feed）。
    get sourceAvailable() {
      try { return resolveService() != null } catch { return false }
    },
    snapshot,
    subscribe(listener) {
      if (typeof listener !== 'function') throw new TypeError('card frames listener must be a function')
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
