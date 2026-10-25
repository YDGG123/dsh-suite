import { WebSocketServer, WebSocket } from 'ws'
import { ACCESS_TTL_MS, BridgeError, REFRESH_TTL_MS, createAuthStore, digest } from './auth.mjs'
import { normalizeMobileV1Origin } from './public-url.mjs'
import { CHUNK_CAPABILITY, MAX_FRAME_BYTES, MAX_REASSEMBLED_BYTES, MAX_STREAMS_PER_CONNECTION, clientCapabilities, planChunks } from './chunked.mjs'
import { randomUUID } from 'node:crypto'

const PREFIX = '/mobile/v1'
const LOOPBACK = new Set(['127.0.0.1', '::1', 'localhost'])
const fail = (status, code, message) => { throw new BridgeError(status, code, message) }
const required = (value, name, maximum = 256) => {
  if (typeof value !== 'string' || !value || value.length > maximum) fail(400, 'INVALID_REQUEST', `${name} is required and must be at most ${maximum} characters.`)
  return value
}
const safeError = error => ({ code: error.status ? error.code ?? 'REQUEST_FAILED' : 'INTERNAL_ERROR', message: error.status ? error.message : 'The mobile bridge could not complete this request.' })
function forDevice(value, deviceId) {
  const prefix = `${deviceId}_`
  const message = item => typeof item.requestId === 'string' && item.requestId.startsWith(prefix) ? { ...item, requestId: item.requestId.slice(prefix.length) } : item
  return { ...value, ...(value.messages ? { messages: value.messages.map(message) } : {}), ...(value.message ? { message: message(value.message) } : {}), ...(value.items ? { items: value.items.map(message) } : {}), ...(value.queue ? { queue: value.queue.map(message) } : {}) }
}

function readBody(request, maximum) {
  return new Promise((resolve, reject) => {
    const chunks = []
    let length = 0
    let failed = false
    const rejectOnce = error => { if (!failed) { failed = true; reject(error) } }
    if (Number(request.headers['content-length']) > maximum) rejectOnce(new BridgeError(413, 'BODY_TOO_LARGE', 'This upload is too large.'))
    request.on('data', chunk => {
      length += chunk.length
      if (length > maximum) rejectOnce(new BridgeError(413, 'BODY_TOO_LARGE', 'This upload is too large.'))
      if (!failed) chunks.push(chunk)
    })
    request.on('end', () => { if (!failed) resolve(Buffer.concat(chunks)) })
    request.on('error', rejectOnce)
    request.on('aborted', () => rejectOnce(new BridgeError(400, 'REQUEST_ABORTED', 'The request was interrupted.')))
  })
}

async function jsonBody(request) {
  const body = await readBody(request, 512 * 1024)
  try {
    const value = JSON.parse(body.toString('utf8'))
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Invalid body')
    return value
  } catch { fail(400, 'INVALID_JSON', 'Send a JSON object.') }
}

export async function createMobileV1({ home, config = {}, adapter, team = null, cards = null, publicUrl: configuredPublicUrl = '', resolvePublicUrl = null, issueGatewayDevice = null, log = () => {} }) {
  let publicUrl = ''
  if (configuredPublicUrl) {
    const parsed = new URL(configuredPublicUrl)
    if (parsed.username || parsed.password || parsed.search || parsed.hash || parsed.pathname !== '/') throw new Error('Mobile publicUrl must be a server origin without credentials, a path, or a query.')
    if (parsed.protocol !== 'https:' && !(config.devAllowInsecure === true && parsed.protocol === 'http:' && LOOPBACK.has(parsed.hostname.replace(/^\[|\]$/g, '')))) throw new Error('Mobile publicUrl must use HTTPS. Loopback HTTP requires devAllowInsecure.')
    publicUrl = parsed.origin
  }
  // 心跳（sync-resume-v1）：客户端按 interval 发应用层 ping，超 timeout 没收到任何帧判死重连。
  // 与已有的 WS 层 15s ping/pong 互补：后者清服务端的僵死连接，前者发现「TCP 半开、本端以为还活着」。
  const HEARTBEAT_INTERVAL_SECONDS = 25
  const HEARTBEAT_TIMEOUT_SECONDS = 75
  const SYNC_MAX_DELTAS = 200
  const SYNC_MAX_DELTAS_LIMIT = 1000
  // 常驻订阅：没有手机连着时也保持 dsBotTeam 订阅，断线期间的事件才进得了回放留窗。
  const releaseRetention = typeof team?.retain === 'function' ? team.retain() : null
  const sockets = new Map()
  // 统一出口：一条帧的序列化字节超过 maxFrameBytes 且客户端声明了分块能力时，
  // 改发 chunk 序列；否则原样发。所有大响应（团队/卡片快照、delta、事件帧）都走这里。
  // 串行发送：一条流发完再发下一条，因此同一连接的实际并发恒为 1（≤ 公布的上限），
  // 帧与帧之间的顺序不会被分块打乱。
  const emitFrame = ({ frame, json, state, sendJson, label }) => {
    if (state.chunked !== true) return sendJson(json)
    let plan
    try {
      plan = planChunks(json, {
        finalKind: String(frame?.kind ?? frame?.type ?? 'frame'),
        streamId: randomUUID(),
        activeStreams: state.streams ?? 0,
      })
    } catch (error) {
      log(`${label}: could not plan a chunked frame: ${error?.message ?? error}`)
      return false
    }
    if (plan.mode === 'plain') return sendJson(json)
    if (plan.mode === 'refused') {
      log(`${label}: ${frame?.kind ?? frame?.type ?? 'frame'} frame is ${plan.bytes} bytes; not sent (${plan.reason}, limits ${MAX_FRAME_BYTES}/${MAX_REASSEMBLED_BYTES})`)
      return false
    }
    state.streams = (state.streams ?? 0) + 1
    try {
      for (const chunk of plan.chunks) {
        if (!sendJson(JSON.stringify(chunk))) return false
      }
      return true
    } finally {
      state.streams = (state.streams ?? 0) - 1
    }
  }
  const requestControllers = new Map()
  const auth = await createAuthStore(home, { issueGatewayDevice, onRevoke: id => {
    for (const [socket, state] of sockets) if (state.deviceId === id) socket.close(4403, 'Device revoked')
    for (const [controller, deviceId] of requestControllers) if (deviceId === id) controller.abort(new BridgeError(401, 'UNAUTHORIZED', 'This device was revoked.'))
  } })
  const allowedOrigins = new Set(config.allowedOrigins ?? [])
  if (publicUrl) allowedOrigins.add(publicUrl)
  const rates = new Map()
  function rate(key, maximum) {
    const now = Date.now()
    let value = rates.get(key)
    if (!value || value.expiresAt <= now) {
      if (rates.size > 4000) for (const [id, item] of rates) if (item.expiresAt <= now) rates.delete(id)
      if (rates.size > 4000) fail(429, 'RATE_LIMITED', 'Try again in a minute.')
      rates.set(key, value = { count: 0, expiresAt: now + 60_000 })
    }
    if (++value.count > maximum) fail(429, 'RATE_LIMITED', 'Try again in a minute.')
  }
  function checkOrigin(request) {
    const origin = request.headers.origin
    if (origin) {
      // 隧道 quick 模式的域名每次启动都可能变，允许当前生效的 origin（已归一化）。
      const allowed = allowedOrigins.has(origin) || origin === effectiveUrl()
      if (!allowed) fail(403, 'ORIGIN_DENIED', 'This browser origin is not allowed.')
    }
    return origin
  }
  function access(request) {
    const header = request.headers.authorization
    if (!header?.startsWith('Bearer ')) fail(401, 'UNAUTHORIZED', 'A paired device session is required.')
    return auth.verifyAccess(header.slice(7))
  }
  const submissions = new Map()
  const recoveries = new Map()
  const prefixKey = (deviceId, id) => `${deviceId}:${id}`
  async function recover(device, saved, signal) {
    if (saved.receipt.status !== 'unknown' || !adapter.reconcile) return saved.receipt
    const key = prefixKey(device.id, saved.receipt.requestId)
    if (submissions.has(key)) {
      await submissions.get(key).catch(() => {})
      if (saved.receipt.status !== 'unknown') return saved.receipt
    }
    if (recoveries.has(key)) return recoveries.get(key)
    rate(`recover:${device.id}`, 30)
    const operation = (async () => {
      try {
        const proof = await adapter.reconcile({ conversationId: saved.receipt.conversationId, sessionId: saved.receipt.sessionId,
          requestId: `${device.id}_${saved.receipt.requestId}` }, signal)
        if (proof?.accepted === true) {
          Object.assign(saved.receipt, { accepted: true, status: 'accepted', recovered: true })
          await auth.save()
        }
      } catch {
        // A missing or unavailable proof cannot establish rejection or authorize a replay.
        signal.throwIfAborted()
      } finally { recoveries.delete(key) }
      return saved.receipt
    })()
    recoveries.set(key, operation)
    return operation
  }
  async function submit(device, body, signal, assertActive) {
    required(body.requestId, 'requestId', 128)
    if (!/^[A-Za-z0-9_-]+$/.test(body.requestId)) fail(400, 'INVALID_REQUEST', 'requestId may contain only letters, numbers, underscores, and hyphens.')
    required(body.conversationId, 'conversationId')
    required(body.sessionId, 'sessionId')
    if (typeof body.text !== 'string' || body.text.length > 100_000) fail(400, 'INVALID_REQUEST', 'text must contain at most 100000 characters.')
    const attachments = body.attachments ?? []
    if (!Array.isArray(attachments) || attachments.length > 8) fail(400, 'INVALID_ATTACHMENTS', 'A message supports at most 8 attachments.')
    const receiptIds = attachments.map(item => required(typeof item === 'string' ? item : item?.receiptId, 'receiptId'))
    const payload = { conversationId: body.conversationId, sessionId: body.sessionId, requestId: body.requestId, text: body.text, attachments: receiptIds.map(receiptId => ({ receiptId })) }
    const hash = digest(JSON.stringify(payload))
    const key = prefixKey(device.id, body.requestId)
    const existing = auth.data.submissions[key]
    if (existing) {
      if (existing.hash !== hash) fail(409, 'REQUEST_ID_CONFLICT', 'This requestId was already used for a different message.')
      if (submissions.has(key)) return submissions.get(key)
      if (existing.error) throw new BridgeError(existing.error.status, existing.error.code, existing.error.message)
      return recover(device, existing, signal)
    }
    for (const receiptId of receiptIds) {
      const upload = auth.data.uploads[receiptId]
      if (!upload || upload.deviceId !== device.id || upload.conversationId !== body.conversationId || upload.sessionId !== body.sessionId || upload.expiresAt <= Date.now()) fail(409, 'UPLOAD_EXPIRED', 'Upload this attachment again for the selected conversation.')
    }
    if (Object.keys(auth.data.submissions).length >= 100_000) fail(507, 'LEDGER_FULL', 'The message receipt store is full. Contact the server operator.')
    const receipt = { requestId: body.requestId, conversationId: body.conversationId, sessionId: body.sessionId, status: 'unknown', createdAt: Date.now() }
    auth.data.submissions[key] = { hash, receipt }
    const operation = (async () => {
      try {
        await auth.save()
        assertActive()
        // The same device request must also stay stable in DSH after a bridge restart.
        const result = await adapter.submit({ ...payload, requestId: `${device.id}_${body.requestId}` }, signal)
        if (result?.accepted !== true) fail(503, 'ADMISSION_UNCONFIRMED', 'The host has not confirmed this message.')
        Object.assign(receipt, { accepted: result.accepted === true, status: 'accepted' })
        await auth.save()
        return receipt
      } catch (error) {
        if (error.status >= 400 && error.status < 500) {
          auth.data.submissions[key].error = { status: error.status, ...safeError(error) }
          receipt.status = 'rejected'
          await auth.save()
        }
        throw error
      } finally { submissions.delete(key) }
    })()
    submissions.set(key, operation)
    return operation
  }
  async function route(request, response) {
    const controller = new AbortController()
    requestControllers.set(controller, null)
    response.on('close', () => { if (!response.writableEnded) controller.abort() })
    const signal = AbortSignal.any([controller.signal, AbortSignal.timeout(120_000)])
    try {
      response.setHeader('Cache-Control', 'no-store')
      response.setHeader('X-Content-Type-Options', 'nosniff')
      const origin = checkOrigin(request)
      if (origin) {
        response.setHeader('Access-Control-Allow-Origin', origin)
        response.setHeader('Vary', 'Origin')
      }
      if (request.method === 'OPTIONS') {
        response.writeHead(204, { 'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS', 'Access-Control-Allow-Headers': 'Authorization, Content-Type', 'Access-Control-Max-Age': '600' })
        response.end()
        return
      }
      const url = new URL(request.url, 'http://bridge.invalid')
      if (url.searchParams.has('token') || url.searchParams.has('accessToken')) fail(400, 'TOKEN_IN_URL', 'Send session credentials in the Authorization header.')
      const path = url.pathname
      const method = request.method
      const ip = request.socket.remoteAddress ?? 'unknown'
      let result
      if (method === 'GET' && path === `${PREFIX}/info`) {
        rate(`info:${ip}`, 120)
        result = { protocolVersion: 1, serverId: auth.data.serverId, name: config.name ?? 'DS Bot',
          // teamDegraded = 源服务缺席（与订阅者无关）；teamServing = 当前是否真的在走实时帧。
          capabilities: { ...(adapter.capabilities?.() ?? {}), team: !!team,
            teamDegraded: team ? team.sourceAvailable === false : true,
            teamServing: team?.degraded === false,
            cards: !!cards, cardsDegraded: cards ? cards.sourceAvailable === false : true,
            cardsServing: cards?.degraded === false,
            // 凭证有效期（秒）：客户端据此算主动刷新间隔；网关改 TTL 不必再发客户端版本。
            accessTokenTtlSeconds: ACCESS_TTL_MS / 1000,
            refreshTokenTtlSeconds: REFRESH_TTL_MS / 1000,
            // 大响应分块（chunked-frames-v1）的三个上限，单位字节 / 条：
            // 客户端声明能力后才会收到 chunk 帧；老客户端永远收整帧。
            maxFrameBytes: MAX_FRAME_BYTES,
            maxReassembledBytes: MAX_REASSEMBLED_BYTES,
            maxStreamsPerConnection: MAX_STREAMS_PER_CONNECTION,
            // 心跳（控制面）：客户端按 interval 发 ping，超 timeout 判死重连。
            heartbeatIntervalSeconds: HEARTBEAT_INTERVAL_SECONDS,
            heartbeatTimeoutSeconds: HEARTBEAT_TIMEOUT_SECONDS,
            // 断线补增量：auth 可带 resume，或连接中发 sync.from。
            syncResume: typeof team?.history === 'function' },
          compatibility: adapter.compatibility?.() ?? {} }
      } else if (method === 'POST' && path === `${PREFIX}/pairings`) {
        rate(`pair:${ip}`, 10)
        result = auth.beginPairing(await jsonBody(request))
      } else if (method === 'POST' && path === `${PREFIX}/pairings/complete`) {
        rate(`complete:${ip}`, 120)
        result = await auth.completePairing((await jsonBody(request)).claimToken)
      } else if (method === 'POST' && path === `${PREFIX}/auth/refresh`) {
        rate(`refresh:${ip}`, 30)
        result = await auth.refresh((await jsonBody(request)).refreshToken)
      } else {
        rate(`auth:${ip}`, 600)
        const device = access(request)
        requestControllers.set(controller, device.id)
        const assertActive = () => { signal.throwIfAborted(); access(request) }
        rate(`device:${device.id}`, 600)
        const parts = path.startsWith(`${PREFIX}/`) ? path.slice(PREFIX.length + 1).split('/').map(value => {
          try { return decodeURIComponent(value) } catch { fail(400, 'INVALID_PATH', 'The request path is invalid.') }
        }) : []
        if (method === 'GET' && path === `${PREFIX}/state`) result = await adapter.state(signal)
        // B1/B2：团队投影帧与卡片帧的一次性快照。手机端首屏可以先拉这个，
        // 再连 `/events/…` 式 WS 拿增量；两处数据同源（同一 feed 实例）。
        else if (method === 'GET' && path === `${PREFIX}/team`) {
          if (!team) fail(501, 'TEAM_FEED_UNAVAILABLE', 'This host does not publish the team feed.')
          result = await team.snapshot()
        }
        else if (method === 'GET' && path === `${PREFIX}/cards`) {
          if (!cards) fail(501, 'CARD_FEED_UNAVAILABLE', 'This host does not publish card frames.')
          result = await cards.snapshot()
        }
        else if (method === 'GET' && path === `${PREFIX}/conversations`) result = await adapter.conversations(signal)
        else if (parts[0] === 'conversations' && parts.length === 3 && method === 'GET' && parts[2] === 'messages') {
          const limit = url.searchParams.has('limit') ? Number(url.searchParams.get('limit')) : 50
          if (!Number.isInteger(limit) || limit < 1 || limit > 100) fail(400, 'INVALID_LIMIT', 'limit must be between 1 and 100.')
          result = forDevice(await adapter.history(parts[1], { cursor: url.searchParams.get('cursor') ?? undefined, limit }, signal), device.id)
        } else if (parts[0] === 'conversations' && parts.length === 3 && method === 'GET' && parts[2] === 'target') result = await adapter.target(parts[1], signal)
        else if (parts[0] === 'conversations' && parts.length === 3 && method === 'POST' && parts[2] === 'cancel') result = await adapter.cancel(parts[1], signal)
        else if (method === 'POST' && path === `${PREFIX}/submissions`) {
          if (adapter.capabilities?.().send !== true) fail(501, 'STABLE_SUBMIT_REQUIRED', 'The upstream reliable submit extension is unavailable.')
          const body = await jsonBody(request)
          assertActive()
          result = await submit(device, body, signal, assertActive)
        }
        else if (method === 'GET' && parts[0] === 'submissions' && parts.length === 2) {
          const saved = auth.data.submissions[prefixKey(device.id, parts[1])]
          if (!saved) fail(404, 'SUBMISSION_NOT_FOUND', 'This message receipt does not exist.')
          result = saved.error ? { ...saved.receipt, error: { code: saved.error.code, message: saved.error.message } } : await recover(device, saved, signal)
        } else if (method === 'POST' && path === `${PREFIX}/actions`) {
          const body = await jsonBody(request)
          if (!body || typeof body.endpoint !== 'string' || !Array.isArray(adapter.capabilities?.().actions) || !adapter.capabilities().actions.includes(body.endpoint)) fail(403, 'ACTION_NOT_ALLOWED', 'This mobile action is unavailable.')
          assertActive()
          result = forDevice(await adapter.action(body.endpoint, body.payload ?? {}, signal), device.id)
        }
        else if (method === 'GET' && path === `${PREFIX}/devices`) result = { devices: auth.devices(), currentDeviceId: device.id }
        else if (method === 'DELETE' && parts[0] === 'devices' && parts.length === 2) result = await auth.revoke(parts[1])
        else if (method === 'POST' && path === `${PREFIX}/read-markers`) {
          const body = await jsonBody(request)
          assertActive()
          required(body.conversationId, 'conversationId')
          if (!Number.isSafeInteger(body.seq) || body.seq < 0) fail(400, 'INVALID_SEQUENCE', 'seq must be a nonnegative integer.')
          await adapter.target(body.conversationId, signal)
          const key = prefixKey(device.id, body.conversationId)
          auth.data.readMarkers[key] = Math.max(auth.data.readMarkers[key] ?? 0, body.seq)
          await auth.save()
          result = { conversationId: body.conversationId, seq: auth.data.readMarkers[key] }
        } else fail(404, 'NOT_FOUND', 'This mobile bridge endpoint does not exist.')
      }
      signal.throwIfAborted()
      if (requestControllers.get(controller) !== null) access(request)
      response.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' })
      response.end(JSON.stringify(result ?? { ok: true }))
    } catch (error) {
      if (process.env.MOBILE_V1_DEBUG) console.error('[mobile-v1]', error)
      // 4xx/5xx 都要留痕：5xx 带栈（此前只回 INTERNAL_ERROR、不落日志，真机只能靠猜）；
      // 4xx 记一行码与文案（真机 409 TARGET_CHANGED 就是靠回执库才还原的）。
      const status = error?.status ?? 500
      if (status >= 500) {
        log(`mobile-v1 ${request.method} ${request.url} failed (${status}): ${error?.stack ?? String(error)}`)
      } else if (status >= 400) {
        log(`mobile-v1 ${request.method} ${request.url} rejected (${status} ${error?.code ?? 'REQUEST_FAILED'}): ${error?.message ?? ''}`)
      }
      if (!response.headersSent) {
        response.writeHead(error.status ?? 500, { 'Content-Type': 'application/json; charset=utf-8' })
        response.end(JSON.stringify({ error: safeError(error) }))
      } else response.end()
    } finally { requestControllers.delete(controller) }
  }
  const wss = new WebSocketServer({ noServer: true, maxPayload: 64 * 1024, perMessageDeflate: false })
  // 团队流（B1/B2）：一条长连接同时承载团队帧与卡片帧，按 `kind` 区分。
  // 与按会话的 `/events` 分开：那里的鉴权帧必须带 conversationId 且受 redacted transcript 门控，
  // 而团队名册在没有会话正文能力时也必须可用。
  const teamWss = new WebSocketServer({ noServer: true, maxPayload: 16 * 1024, perMessageDeflate: false })
  const teamSockets = new Map()
  function handleUpgrade(request, socket, head) {
    try {
      checkOrigin(request)
      const isTeam = request.url === `${PREFIX}/team`
      if (request.url !== `${PREFIX}/events` && !isTeam) fail(404, 'NOT_FOUND', 'WebSocket endpoint not found.')
      if (isTeam && !team) fail(501, 'TEAM_FEED_UNAVAILABLE', 'This host does not publish the team feed.')
      rate(`ws:${request.socket.remoteAddress}`, 60)
      if (wss.clients.size + teamWss.clients.size >= 100) fail(429, 'CONNECTION_LIMIT', 'Too many mobile connections.')
      if (isTeam) teamWss.handleUpgrade(request, socket, head, client => teamWss.emit('connection', client, request))
      else wss.handleUpgrade(request, socket, head, client => wss.emit('connection', client, request))
    } catch (error) {
      socket.end(`HTTP/1.1 ${error.status ?? 400} Rejected\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`)
    }
  }
  wss.on('connection', socket => {
    const controller = new AbortController()
    const state = { controller, deviceId: null, authenticated: false, busy: false, chunked: false, streams: 0 }
    sockets.set(socket, state)
    const timeout = setTimeout(() => socket.close(4401, 'Authentication required'), 5000)
    const sendRaw = json => {
      if (socket.readyState !== WebSocket.OPEN) return false
      if (socket.bufferedAmount > 2 * 1024 * 1024) { socket.close(4408, 'Reconnect to catch up'); return false }
      socket.send(json)
      return true
    }
    const send = event => {
      const frame = state.deviceId ? forDevice(event, state.deviceId) : event
      let json
      try { json = JSON.stringify(frame) } catch (error) { log(`mobile-v1: could not serialize an event frame: ${error?.message ?? error}`); return false }
      return emitFrame({ frame, json, state, sendJson: sendRaw, label: 'mobile-v1 events' })
    }
    let expiry
    let alive = true
    socket.on('pong', () => { alive = true })
    socket.on('close', () => { clearTimeout(timeout); clearInterval(expiry); controller.abort(); sockets.delete(socket) })
    socket.on('error', () => controller.abort())
    socket.on('message', async bytes => {
      let frame
      try { frame = JSON.parse(bytes.toString()) } catch {
        if (state.authenticated) { send({ type: 'error', error: { code: 'INVALID_JSON', message: 'Control frames must be JSON.', details: {} } }); return }
        state.busy = true
        try { fail(400, 'INVALID_JSON', 'Invalid authentication frame.') } catch {}
        return
      }
      // 认证后只接受心跳（sync-resume-v1 的补增量只属于团队流）。
      if (state.authenticated) {
        if (frame?.type === 'ping') {
          const at = Date.now()
          if (state.lastPingAt === undefined || at - state.lastPingAt >= 2000) { state.lastPingAt = at; send({ type: 'pong', at }) }
          return
        }
        if (frame?.type === 'pong') return
        socket.close(4400, 'Only control frames are accepted after authentication')
        return
      }
      if (state.busy) { socket.close(4400, 'Only an initial authentication frame is accepted'); return }
      state.busy = true
      try {
        if (frame?.type !== 'auth') fail(401, 'UNAUTHORIZED', 'Authenticate before following a conversation.')
        const device = auth.verifyAccess(frame.token)
        if (adapter.capabilities?.().stream !== true) fail(501, 'REDACTED_PROJECTION_REQUIRED', 'The upstream redacted transcript extension is unavailable.')
        required(frame.conversationId, 'conversationId')
        if ([...sockets.values()].filter(item => item.deviceId === device.id).length >= 5) fail(429, 'CONNECTION_LIMIT', 'Close another connection on this device.')
        await adapter.target(frame.conversationId, controller.signal)
        auth.verifyAccess(frame.token)
        state.chunked = clientCapabilities(frame).has(CHUNK_CAPABILITY)
        state.deviceId = device.id
        state.authenticated = true
        clearTimeout(timeout)
        expiry = setInterval(() => {
          try { auth.verifyAccess(frame.token) } catch { socket.close(4401, 'Session expired') }
          if (!alive) { socket.terminate(); return }
          alive = false
          if (socket.readyState === WebSocket.OPEN) socket.ping()
        }, 15_000)
        expiry.unref()
        send({ type: 'ready', conversationId: frame.conversationId, serverId: auth.data.serverId })
        for await (const event of adapter.follow(frame.conversationId, { after: frame.after }, controller.signal)) {
          if (controller.signal.aborted) break
          send(event)
        }
        if (!controller.signal.aborted && socket.readyState === WebSocket.OPEN) socket.close(1012, 'Reconnect to the host stream')
      } catch (error) {
        if (!controller.signal.aborted) {
          send({ type: 'error', error: safeError(error) })
          socket.close(error.status === 401 ? 4401 : error.status === 403 ? 4403 : 4400, 'Cannot follow conversation')
        }
      }
    })
  })
  teamWss.on('connection', socket => {
    const state = { deviceId: null, authenticated: false, busy: false, ready: false, unsubscribers: [], chunked: false, streams: 0 }
    const buffer = []
    // 团队流的背压阈值要比按会话的 /events 宽：**快照是一次性大帧**
    // （20 个 Bot 的角色头像 data URL 合计可达数 MB，契约明确「可能较大、只在快照出现一次」）。
    // 2MB 会在真实头像下直接把手机踢下线（4408）→ 重连 → 再踢，形成循环。
    const TEAM_BUFFER_LIMIT = 8 * 1024 * 1024
    const sendRaw = json => {
      if (socket.readyState !== WebSocket.OPEN) return false
      if (socket.bufferedAmount > TEAM_BUFFER_LIMIT) { socket.close(4408, 'Reconnect to catch up'); return false }
      socket.send(json)
      return true
    }
    const send = frame => {
      let json
      try { json = JSON.stringify(frame) } catch (error) { log(`mobile-v1 team: could not serialize a frame: ${error?.message ?? error}`); return false }
      return emitFrame({ frame, json, state, sendJson: sendRaw, label: 'mobile-v1 team' })
    }
    teamSockets.set(socket, state)
    const timeout = setTimeout(() => socket.close(4401, 'Authentication required'), 5000)
    let alive = true
    let expiry
    const teardown = () => {
      clearTimeout(timeout); clearInterval(expiry)
      for (const off of state.unsubscribers) { try { off() } catch {} }
      state.unsubscribers = []
      teamSockets.delete(socket)
    }
    // ---- 控制面（认证后）：心跳 ping/pong 与断线补增量 sync-resume-v1 ----
    const replyControl = (code, message) => send({ type: 'error', error: { code, message, details: {} } })
    const clampDeltas = value => Math.min(Math.max(Number.isSafeInteger(value) ? value : SYNC_MAX_DELTAS, 1), SYNC_MAX_DELTAS_LIMIT)
    const resnapshot = async (reason) => {
      if (!team) { replyControl('SYNC_UNAVAILABLE', 'The team feed is not available on this gateway.'); return }
      const snapshot = await team.snapshot()
      const plan = typeof team.splitSnapshot === 'function' ? team.splitSnapshot(snapshot) : { primary: snapshot, batches: [] }
      send(plan.primary)
      for (const batch of plan.batches) send(batch)
      send({ type: 'sync.done', instanceId: team.instanceId ?? null, seq: team.seq ?? 0, reason })
    }
    // 回放判定：缺口必须按 base 链（400ms 合并窗口让 seq 跳号是常态，不能按 +1 判）。
    const replayFrom = async ({ instanceId: wanted, afterSeq, maxDeltas }, reason) => {
      if (!team || typeof team.history !== 'function') { replyControl('SYNC_UNAVAILABLE', 'This gateway cannot resume a team feed.'); return }
      if (!Number.isSafeInteger(afterSeq) || afterSeq < 0) { replyControl('SYNC_BAD_REQUEST', 'afterSeq must be a non-negative integer.'); return }
      if (typeof wanted === 'string' && wanted !== team.instanceId) {
        replyControl('SYNC_UNKNOWN_INSTANCE', 'The team feed restarted; sending a fresh snapshot.')
        await resnapshot('unknown-instance')
        return
      }
      const answer = team.history(afterSeq, clampDeltas(maxDeltas))
      if (answer.mode !== 'ok') {
        replyControl('SYNC_GAP', 'The resume window does not reach back that far; sending a fresh snapshot.')
        await resnapshot('gap')
        return
      }
      for (const frame of answer.frames) send(frame)
      send({ type: 'sync.done', instanceId: team.instanceId ?? null, seq: team.seq ?? 0, reason: answer.frames.length > 0 ? reason : 'caught-up' })
    }
    const handleControl = async (frame) => {
      // auth 首次快照/回放还没跑完时先排队：否则 sync.from 会和快照交错，客户端收到重复帧。
      if (state.busy) { state.pendingControl = frame; return }
      if (frame?.type === 'ping') {
        const at = Date.now()
        // 限速：2s 内多余的 ping 直接丢弃（客户端正常 25s 一条，不会撞到）。
        if (state.lastPingAt !== undefined && at - state.lastPingAt < 2000) return
        state.lastPingAt = at
        send({ type: 'pong', at })
        return
      }
      if (frame?.type === 'pong') return
      if (frame?.type === 'sync.from') {
        const at = Date.now()
        if (state.lastSyncAt !== undefined && at - state.lastSyncAt < 5000) { replyControl('SYNC_RATE_LIMITED', 'Wait a few seconds before asking again.'); return }
        state.lastSyncAt = at
        await replayFrom({ instanceId: frame.instanceId, afterSeq: frame.afterSeq, maxDeltas: frame.maxDeltas }, 'sync.from')
        return
      }
      socket.close(4400, 'Only control frames are accepted after authentication')
    }
    socket.on('pong', () => { alive = true })
    socket.on('close', teardown)
    socket.on('error', teardown)
    socket.on('message', async bytes => {
      let frame
      try { frame = JSON.parse(bytes.toString()) } catch {
        if (state.authenticated) { replyControl('INVALID_JSON', 'Control frames must be JSON.'); return }
        state.busy = true
        try { fail(400, 'INVALID_JSON', 'Invalid authentication frame.') } catch {}
        return
      }
      if (state.authenticated) { await handleControl(frame); return }
      if (state.busy) { socket.close(4400, 'Only an initial authentication frame is accepted'); return }
      state.busy = true
      try {
        if (frame?.type !== 'auth') fail(401, 'UNAUTHORIZED', 'Authenticate before subscribing to the team feed.')
        const device = auth.verifyAccess(frame.token)
        // 同一设备最多 5 条连接（与按会话的 /events 同口径），各自独立计数。
        if ([...teamSockets.values()].filter(item => item.deviceId === device.id).length >= 5) fail(429, 'CONNECTION_LIMIT', 'Close another connection on this device.')
        clearTimeout(timeout)
        state.chunked = clientCapabilities(frame).has(CHUNK_CAPABILITY)
        state.deviceId = device.id
        state.authenticated = true
        expiry = setInterval(() => {
          try { auth.verifyAccess(frame.token) } catch { socket.close(4401, 'Session expired') }
          if (!alive) { socket.terminate(); return }
          alive = false
          if (socket.readyState === WebSocket.OPEN) socket.ping()
        }, 15_000)
        expiry.unref()
        send({ type: 'ready', serverId: auth.data.serverId, kind: 'team',
          instanceId: team?.instanceId ?? null, seq: team?.seq ?? 0, cards: !!cards,
          degraded: { team: team?.degraded === true, cards: cards?.degraded === true } })
        // 先订阅再取快照：订阅窗口内的变化落进 buffer，快照之后按 seq 补齐，
        // 不会出现「快照与首帧之间丢一次变化」的空档。
        const listen = feed => item => {
          if (!state.ready) buffer.push(item)
          else send(item)
        }
        const snapshotSeqs = { team: 0, cards: 0 }
        if (team) {
          state.unsubscribers.push(team.subscribe(listen(team)))
          // 断线重连的零往返路径：auth 里带 resume:{instanceId, afterSeq} 就直接补增量，
          // 命中不了窗口再回快照（省掉「先收整帧快照、再补增量」的浪费）。
          const resume = state.authenticated && frame && typeof frame.resume === 'object' && frame.resume !== null ? frame.resume : null
          let resumed = false
          if (resume && typeof team.history === 'function') {
            const wanted = typeof resume.instanceId === 'string' ? resume.instanceId : undefined
            const afterSeq = resume.afterSeq
            if (typeof wanted === 'string' && wanted !== team.instanceId) {
              replyControl('SYNC_UNKNOWN_INSTANCE', 'The team feed restarted; sending a fresh snapshot.')
            } else if (!Number.isSafeInteger(afterSeq) || afterSeq < 0) {
              replyControl('SYNC_BAD_REQUEST', 'resume.afterSeq must be a non-negative integer.')
            } else {
              const answer = team.history(afterSeq, clampDeltas(resume.maxDeltas))
              if (answer.mode === 'ok') {
                for (const delta of answer.frames) send(delta)
                snapshotSeqs.team = team.seq ?? 0
                send({ type: 'sync.done', instanceId: team.instanceId ?? null, seq: team.seq ?? 0, reason: answer.frames.length > 0 ? 'resume' : 'caught-up' })
                resumed = true
              } else {
                replyControl('SYNC_GAP', 'The resume window does not reach back that far; sending a fresh snapshot.')
              }
            }
          }
          if (!resumed) {
            const snapshot = await team.snapshot()
            snapshotSeqs.team = snapshot.seq ?? 0
            // 快照过大（头像 data URL）时先发名册主帧，再分批补头像帧：
            // 手机先有内容，头像随后到，且不会因为单帧几 MB 撞背压。
            const plan = typeof team.splitSnapshot === 'function' ? team.splitSnapshot(snapshot) : { primary: snapshot, batches: [] }
            send(plan.primary)
            for (const batch of plan.batches) send(batch)
            if (resume) send({ type: 'sync.done', instanceId: team.instanceId ?? null, seq: snapshot.seq ?? 0, reason: 'snapshot' })
          }
        }
        if (cards) {
          state.unsubscribers.push(cards.subscribe(listen(cards)))
          const snapshot = await cards.snapshot()
          snapshotSeqs.cards = snapshot.seq ?? 0
          send(snapshot)
        }
        state.ready = true
        for (const item of buffer) {
          const isCard = item.kind === 'card' || item.kind === 'card-snapshot'
          const base = isCard ? snapshotSeqs.cards : snapshotSeqs.team
          // 快照已覆盖的帧（seq <= snapshot.seq）丢掉；order 帧不占契约 seq，总是补发。
          if (item.kind === 'order' || !Number.isSafeInteger(item.seq) || item.seq > base) send(item)
        }
        buffer.length = 0
      } catch (error) {
        if (socket.readyState === WebSocket.OPEN) {
          send({ type: 'error', error: safeError(error) })
          socket.close(error.status === 401 ? 4401 : error.status === 403 ? 4403 : 4400, 'Cannot subscribe to the team feed')
        }
        teardown()
      } finally {
        state.busy = false
        const queued = state.pendingControl
        state.pendingControl = undefined
        if (queued !== undefined) void handleControl(queued)
      }
    })
  })

  if (!publicUrl && config.devAllowInsecure === true) {
    publicUrl = `http://127.0.0.1:${config.loopbackPort ?? 3082}`
  }
  if (publicUrl) allowedOrigins.add(publicUrl)
  let closing
  // 隧道快照给的是 wss://host/ws/mobile（旧网关 WS 形态），App 只接受 https 根 origin。
  // 这里统一折成 origin，配对资料与面板显示都用可直连的 https 地址。
  function effectiveUrl() {
    const resolved = resolvePublicUrl ? normalizeMobileV1Origin(resolvePublicUrl()) : ''
    return resolved || publicUrl
  }
  return {
    handleHttp: route,
    /** U5 对称配对：网关配对成功后签发 mobile-v1 session。 */
    issueSessionForDevice: ({ name, serverUrl } = {}) => auth.issueSessionForName(name, { serverUrl }),
    handleUpgrade,
    url: publicUrl,
    serverId: auth.data.serverId,
    hasActiveDevices: () => auth.data.devices.some(device => !device.revokedAt && device.refreshExpiresAt > Date.now()),
    isDeviceAuthorized: id => auth.data.devices.some(device => device.id === id && !device.revokedAt && device.refreshExpiresAt > Date.now()),
    async operator(endpoint, payload = {}) {
      switch (endpoint) {
        case 'status': return { enabled: true, url: effectiveUrl(), serverId: auth.data.serverId,
          // teamDegraded = 源服务缺席（与订阅者无关）；teamServing = 当前是否真的在走实时帧。
          capabilities: { ...(adapter.capabilities?.() ?? {}), team: !!team,
            teamDegraded: team ? team.sourceAvailable === false : true,
            teamServing: team?.degraded === false,
            cards: !!cards, cardsDegraded: cards ? cards.sourceAvailable === false : true,
            cardsServing: cards?.degraded === false },
          compatibility: adapter.compatibility?.() ?? {}, pending: auth.pending(), devices: auth.devices() }
        case 'pairing.create': return auth.createPairing(effectiveUrl())
        case 'pairing.approve': return auth.decidePairing(payload.requestId, true)
        case 'pairing.deny': return auth.decidePairing(payload.requestId, false)
        case 'device.revoke': return auth.revoke(payload.id ?? payload.deviceId)
        case 'approvals.list': return adapter.approvalOperator?.(endpoint, payload) ?? { requests: [] }
        case 'approvals.resolve':
          if (!adapter.approvalOperator) fail(503, 'APPROVAL_UNAVAILABLE', 'Tool approvals are unavailable on this host.')
          return adapter.approvalOperator(endpoint, payload)
        default: fail(404, 'NOT_FOUND', 'Unknown mobile device operation.')
      }
    },
    close() {
      if (closing) return closing
      closing = (async () => {
        for (const controller of requestControllers.keys()) controller.abort()
        for (const [socket, state] of sockets) { state.controller.abort(); socket.terminate() }
        for (const socket of teamSockets.keys()) { try { socket.terminate() } catch {} }
        teamWss.close()
        releaseRetention?.()
        team?.dispose?.()
        cards?.dispose?.()
        await adapter.dispose?.()
        wss.close()
        await Promise.allSettled(submissions.values())
        await Promise.allSettled(recoveries.values())
        await auth.close()
      })()
      return closing
    },
  }
}
