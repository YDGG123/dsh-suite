// 一个 Bot 的聊天由**多个 DSH Session 串联**而成：`parts`（更早的分段，旧→新）+
// `sessionId`（当前段）。新的消息只落在当前段，所以只按当前段读历史，用户就看不到旧的。
//
// WS `type:'history'` 这条通道以前没有任何归属/分段概念：`sessionId` 原样转给宿主。
// 这里补两件事（**只做 bot 路径**）：
//   1. 解出「这个 sessionId 属于哪个 Bot、它的更早一段是谁」，让客户端能顺着往更早翻；
//   2. 给调用方一个可靠判据来做归属校验（隐藏 Bot 的段一律不服务）。
//
// 为什么**不用** `room.parts`：ds-bot 的 `view()` 里房间的 `parts` 是**混拼**的
// （成员隐藏会话 + 更早分段，`channel.js:49`）。拿它做分段，会把别的成员的隐藏会话
// 当成自己的历史读出来——那是越权。房间路径保持现状，不在这里解析。

/** 名册里一个 bot 的段链，旧 → 新（当前段在末尾）。缺字段一律当作没有。 */
export function segmentsOf(bot) {
  if (!bot || typeof bot !== 'object') return []
  const current = typeof bot.sessionId === 'string' && bot.sessionId !== '' ? bot.sessionId : null
  const parts = (Array.isArray(bot.parts) ? bot.parts : []).filter(id => typeof id === 'string' && id !== '')
  return current === null ? [] : [...parts, current]
}

/**
 * 把请求的 sessionId 解析成归属信息。返回：
 * - `{ botId, hidden, previous, index, chain }`：属于某个 Bot 的段（`previous` 为更早一段，
 *   最旧的一段为 `undefined`）；
 * - `{ room: true }`：名册里的房间本身（不给分段入口，房间路径不解析）；
 * - `null`：不是名册里的 Bot 段——**普通会话 / 子代理 / 群成员隐藏会话都是这种**，
 *   调用方必须按原样放行，否则会打死手机上的普通会话（它们同样走这条 WS 读历史）。
 */
export function resolveHistoryOwner(roster, sessionId) {
  if (typeof sessionId !== 'string' || sessionId === '') return null
  const bots = Array.isArray(roster?.bots) ? roster.bots : []
  for (const bot of bots) {
    if (!bot || typeof bot.id !== 'string') continue
    const chain = segmentsOf(bot)
    const index = chain.indexOf(sessionId)
    if (index < 0) continue
    return {
      botId: bot.id,
      hidden: bot.hidden === true,
      previous: index > 0 ? chain[index - 1] : undefined,
      index,
      chain,
    }
  }
  const rooms = Array.isArray(roster?.rooms) ? roster.rooms : []
  if (rooms.some(room => room && (room.id === sessionId || room.sessionId === sessionId))) return { room: true }
  return null
}

/**
 * 把「读名册」的函数包成 WS 历史通道用的归属解析器。
 * 策略放在这里而不是装配层，是为了可单测：隐藏 Bot 的段一律拒（手机侧本来就看不到它），
 * 其余（Bot 段 / 房间 / 普通会话）交给调用方按 `resolveHistoryOwner` 的结果处理。
 */
export function createHistoryOwner(readRoster) {
  return (sessionId) => {
    let roster = null
    try { roster = typeof readRoster === 'function' ? readRoster() : null } catch { roster = null }
    const owner = resolveHistoryOwner(roster, sessionId)
    if (owner?.hidden === true) {
      throw Object.assign(new Error('This Session belongs to a hidden Bot'), { code: 'SESSION_DENIED' })
    }
    return owner
  }
}
