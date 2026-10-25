// 大响应分块（chunked frames v1）：网关侧。
//
// 背景：WebSocket 单帧过大时，客户端要么撞内存红线、要么撞缓冲阈值被踢下线（4408 →
// 重连 → 再踢）。抬阈值解决不了根因，正确做法是把一条大帧的**序列化 JSON** 切成
// 若干块发，客户端按 streamId 拼回原文再走原处理链。
//
// 契约（与手机端 FrameReassembler 对齐）：
// - `/info` 的 capabilities 公布三个上限：maxFrameBytes / maxReassembledBytes /
//   maxStreamsPerConnection。
// - 客户端在握手帧里声明 `chunked-frames-v1` 之后，网关才可能发 chunk；
//   没声明的老客户端永远收到原样的整帧（不掉帧、不改变协议版本）。
// - chunk 帧：`{ kind:'chunk', streamId, index, total, finalKind, part, at }`。
//   `part` 是**按 UTF-8 字符边界**切开的原始 JSON 字符串片段——按字节硬切会把
//   多字节字符（中文/emoji）劈成两半，客户端拼回来就是乱码，JSON.parse 也会挂。
// - 切分后每块 ≤ maxFrameBytes（UTF-8 字节）。单条流累计 > maxReassembledBytes
//   时不切、不发（记日志），宁可让客户端保持上一份状态，也不发一条必然被拒的流。
// - 同一条连接上同时存在的流数 ≤ maxStreamsPerConnection。网关按帧串行发送
//   （一条流发完再发下一条），因此实际并发恒为 1，上限只作为防御性约束与客户端
//   的预算声明。

export const MAX_FRAME_BYTES = 512 * 1024
export const MAX_REASSEMBLED_BYTES = 4 * 1024 * 1024
export const MAX_STREAMS_PER_CONNECTION = 2
export const CHUNK_CAPABILITY = 'chunked-frames-v1'

const encoder = new TextEncoder()
const utf8Length = text => encoder.encode(text).length

// 把一段字符串按 UTF-8 字节上限切块，**只切在字符边界上**。
// 用 for…of 按码点迭代：代理对（emoji）天生不会被拆开。
export function utf8Parts(text, maxBytes = MAX_FRAME_BYTES) {
  if (typeof text !== 'string') throw new TypeError('utf8Parts expects a string')
  if (!Number.isSafeInteger(maxBytes) || maxBytes < 1) throw new RangeError('maxBytes must be a positive integer')
  if (text === '') return ['']
  const parts = []
  let current = ''
  let currentBytes = 0
  for (const char of text) {
    const bytes = utf8Length(char)
    if (currentBytes > 0 && currentBytes + bytes > maxBytes) {
      parts.push(current)
      current = ''
      currentBytes = 0
    }
    current += char
    currentBytes += bytes
    // 单个码点本身就超过上限（只有把 maxBytes 调到 4 以下才会发生）：单独成块，
    // 绝不把一个字符拆两半。
  }
  if (current !== '') parts.push(current)
  return parts
}

// 一条帧要不要分块、切成什么。纯函数，返回：
//   { mode: 'plain', bytes }            原样发
//   { mode: 'chunks', bytes, chunks }   发这些 chunk
//   { mode: 'refused', bytes, reason }  不发（记日志）
export function planChunks(json, options = {}) {
  const {
    finalKind = 'frame',
    streamId = '',
    maxFrameBytes = MAX_FRAME_BYTES,
    maxReassembledBytes = MAX_REASSEMBLED_BYTES,
    maxStreams = MAX_STREAMS_PER_CONNECTION,
    activeStreams = 0,
    at = Date.now(),
  } = options
  const bytes = utf8Length(json)
  if (bytes <= maxFrameBytes) return { mode: 'plain', bytes }
  if (bytes > maxReassembledBytes) return { mode: 'refused', bytes, reason: 'too-large' }
  if (activeStreams >= maxStreams) return { mode: 'refused', bytes, reason: 'too-many-streams' }
  const parts = utf8Parts(json, maxFrameBytes)
  const chunks = parts.map((part, index) => ({
    kind: 'chunk',
    streamId,
    index,
    total: parts.length,
    finalKind,
    part,
    at,
  }))
  return { mode: 'chunks', bytes, chunks }
}

// 握手帧里声明的能力列表：容错接受 capabilities / features / caps 三种数组写法，
// 只要含 `chunked-frames-v1` 就算声明（老客户端什么都不给 → 不分块）。
export function clientCapabilities(frame) {
  const lists = [frame?.capabilities, frame?.features, frame?.caps]
  const declared = new Set()
  for (const list of lists) {
    if (!Array.isArray(list)) continue
    for (const item of list) if (typeof item === 'string') declared.add(item)
  }
  return declared
}
