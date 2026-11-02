// attachmentId -> complete image reference index.
//
// Why this exists: the wire protocol only carries `{ type:"attachment", sessionId,
// attachmentId }` (mobile clients never re-send image metadata), but the Host's
// `session/attachment` endpoint requires the FULL reference nested under
// `attachment`:
//
//   { sessionId, attachment: { attachmentId, mediaType, bytes, width, height } }
//
// The Host decodes that request with a strict codec (additionalProperties:false),
// and re-verifies id/format/byte length/dimensions against the stored bytes, so the
// gateway must echo back the exact reference it already forwarded to the client —
// it must not invent or repair metadata. A flat `{ sessionId, attachmentId }` payload
// fails boundary validation (`gateway/input-invalid ... wire field "request"`) on
// every image, which is what this module fixes.
//
// References are only ever taken from Host data (live session events and history
// pages), never synthesized. Lookup misses are reported explicitly by the caller as
// `attachment/unknown-ref` — never silently downgraded to the flat shape.

// Bounded FIFO. A phone session may show hundreds of images; a few thousand entries
// of five scalars is negligible, and the oldest ones fall out first.
const LIMIT = 4096
const refs = new Map()

const MEDIA_TYPES = new Set(['image/png', 'image/jpeg', 'image/webp', 'image/gif'])

const finiteOrNull = value => (typeof value === 'number' && Number.isFinite(value) ? value : null)

// Only the five fields the Host schema requires — extra keys are rejected by the
// strict codec, so `name`/`originalDimensions` are intentionally not forwarded.
function encodeRef(attachment) {
  if (!attachment || typeof attachment !== 'object') return null
  const attachmentId = typeof attachment.attachmentId === 'string' ? attachment.attachmentId : null
  if (!attachmentId) return null
  const mediaType = typeof attachment.mediaType === 'string' ? attachment.mediaType : null
  if (!mediaType || !MEDIA_TYPES.has(mediaType)) return null
  const bytes = finiteOrNull(attachment.bytes)
  const width = finiteOrNull(attachment.width)
  const height = finiteOrNull(attachment.height)
  // The Host requires all five; a half-known reference would be rejected again, so
  // treat it as unknown and let the caller report it.
  if (bytes === null || width === null || height === null) return null
  return Object.freeze({ attachmentId, mediaType, bytes, width, height })
}

export function rememberAttachment(ref) {
  const encoded = encodeRef(ref)
  if (!encoded) return null
  // Delete first so a re-observed id counts as most recent (Map keeps insertion order).
  refs.delete(encoded.attachmentId)
  refs.set(encoded.attachmentId, encoded)
  while (refs.size > LIMIT) refs.delete(refs.keys().next().value)
  return encoded
}

// ContentBlock[] (user message content, assistant content, history message content).
export function rememberContentRefs(content) {
  if (!Array.isArray(content)) return
  for (const block of content) {
    if (!block || (block.type !== 'image' && block.type !== 'file')) continue
    rememberAttachment(block.attachment)
  }
}

// Raw SessionEvent[], either bare or wrapped as the history endpoint returns them
// (`{ event: SessionEvent, ... }`).
export function rememberEventRefs(events) {
  if (!Array.isArray(events)) return
  for (const entry of events) {
    const event = entry && typeof entry.event === 'object' && entry.event ? entry.event : entry
    const data = event && event.data
    if (!data || typeof data !== 'object') continue
    rememberContentRefs(data.content)
    rememberContentRefs(data.message?.content)
  }
}

export function attachmentRefOf(attachmentId) {
  if (typeof attachmentId !== 'string') return null
  return refs.get(attachmentId) ?? null
}

// Test hook: forget everything (keeps cases independent).
export function resetAttachmentRefs() {
  refs.clear()
}
