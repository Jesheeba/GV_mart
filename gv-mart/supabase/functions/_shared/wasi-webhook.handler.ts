// Wasi inbound webhook, as a dependency-injected handler (so every branch is unit-testable without Deno or Supabase).
// wasi-webhook/index.ts is the thin shell that builds the real store and the real `defer`.
// See docs/plan-dispatcher-fix.md (d).
//
// Rules this enforces:
//   - the HMAC signature is checked before ANY write, for every event type;
//   - message.status updates delivery_status / delivered_at / read_at / failed_at, never `status` (status is the SEND
//     confirmation and its CHECK does not allow delivered/read);
//   - updates are monotonic (sent < delivered < read; a retried or out-of-order event never regresses a row);
//   - Wasi retries for ~8.5 h, so a verified event is acknowledged with 200 immediately and processed afterwards
//     through `defer` (EdgeRuntime.waitUntil in production). A bad signature is a 401 (and is retried by Wasi).
//   - a wamid contains the recipient's number: it is only ever used to look the row up, never logged.
import { buildWasiErrorDetail } from "./wasi-error-detail.ts"
import type { NormalizedInboundMessage } from "./whatsapp-handle-message.ts"

export type WasiContact = { wa_id: string; name?: string }
export type WasiInteractiveReply =
  | { type: "button_reply"; id: string; title: string }
  | { type: "list_reply"; id: string; title: string; description?: string }
export type WasiMessage = { body?: string; sent_at?: string; interactive?: WasiInteractiveReply }
export type WasiMessageReceivedData = {
  chat_id?: string
  message_id: string
  message_type: string
  contact: WasiContact
  message?: WasiMessage
  waba_id: string
  enqueued_at?: string
}
export type WasiMessageStatusData = { message_id: string; status: string; error?: unknown; timestamp?: string; sent_at?: string }
export type WasiWebhookBody = { event: string; data: unknown }

export type DeliveryStatus = "sent" | "delivered" | "read" | "failed"
const RANK: Record<string, number> = { sent: 0, delivered: 1, read: 2 }

export type DeliveryState = { delivery_status: string | null; delivered_at: string | null; read_at: string | null }

/** The patch for one status event, or null when it changes nothing (duplicate / regression / unknown status). */
export function applyStatusEvent(
  current: DeliveryState,
  event: { status: string; error?: unknown; at?: string | null },
  nowIso: string
): Record<string, unknown> | null {
  const status = String(event.status ?? "").toLowerCase()
  const at = event.at && Number.isFinite(Date.parse(event.at)) ? new Date(event.at).toISOString() : nowIso
  const cur = current.delivery_status

  if (status === "failed") {
    // Positive evidence of delivery wins over a (late or stray) failure.
    if (cur === "delivered" || cur === "read" || cur === "failed") return null
    const errText = event.error == null ? "delivery_failed" : buildWasiErrorDetail("delivery_failed", typeof event.error === "string" ? event.error : JSON.stringify(event.error))
    return { delivery_status: "failed", failed_at: at, error: errText }
  }

  if (!(status in RANK)) return null
  const curRank = cur && cur in RANK ? RANK[cur] : -1
  const patch: Record<string, unknown> = {}

  if (RANK[status] > curRank || cur === "failed") patch.delivery_status = status
  // Timestamps fill in once even when events arrive out of order (read before delivered).
  if (status === "delivered" && !current.delivered_at) patch.delivered_at = at
  if (status === "read") {
    if (!current.read_at) patch.read_at = at
    if (!current.delivered_at) patch.delivered_at = at
  }
  return Object.keys(patch).length > 0 ? patch : null
}

async function verifySignature(rawBody: string, signatureHeader: string | null, secret: string): Promise<boolean> {
  if (!signatureHeader?.startsWith("sha256=")) return false
  const expectedHex = signatureHeader.slice("sha256=".length)
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"])
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(rawBody))
  const actualHex = Array.from(new Uint8Array(mac))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("")
  if (actualHex.length !== expectedHex.length) return false
  let diff = 0
  for (let i = 0; i < actualHex.length; i++) diff |= actualHex.charCodeAt(i) ^ expectedHex.charCodeAt(i)
  return diff === 0
}

export function toNormalized(data: WasiMessageReceivedData): NormalizedInboundMessage | null {
  if (!data.contact?.wa_id || !data.message_id) return null
  const timestamp = data.message?.sent_at ?? data.enqueued_at ?? new Date().toISOString()

  if (data.message_type === "text") {
    return { phone: data.contact.wa_id, waMessageId: data.message_id, timestamp, intent: { kind: "text", text: data.message?.body ?? "" } }
  }

  if (data.message_type === "interactive") {
    const interactive = data.message?.interactive
    if ((interactive?.type === "button_reply" || interactive?.type === "list_reply") && typeof interactive.id === "string" && interactive.id) {
      return { phone: data.contact.wa_id, waMessageId: data.message_id, timestamp, intent: { kind: "list_reply", id: interactive.id } }
    }
    return null
  }

  // Any other non-text message type with a body is treated as free text rather than guessing a field; otherwise skipped.
  if (data.message?.body) {
    return { phone: data.contact.wa_id, waMessageId: data.message_id, timestamp, intent: { kind: "text", text: data.message.body } }
  }
  return null
}

export interface WebhookStore {
  findCredentialsByWabaId(wabaId: string): Promise<{ orgId: string; webhookSecret: string } | null>
  /** Looked up by the WhatsApp message id (wa_message_id). */
  findOutboxByWhatsAppId(messageId: string): Promise<({ id: string; orgId: string; webhookSecret: string } & DeliveryState) | null>
  applyDeliveryUpdate(id: string, patch: Record<string, unknown>): Promise<void>
  upsertTemplateStatus(orgId: string, wasiName: string, status: string): Promise<void>
  /** Runs the bot (handleMessage). Failures are caught by the handler and logged without identifiers. */
  processInbound(orgId: string, msg: NormalizedInboundMessage): Promise<void>
}

export type WebhookResult = { status: number; body: Record<string, unknown> }

function logError(label: string, e: unknown) {
  // Message text only: the error object can carry request context, and a wamid embeds the recipient's number.
  console.error(label, e instanceof Error ? e.message : "unknown error")
}

export async function handleWasiWebhook(
  rawBody: string,
  signatureHeader: string | null,
  store: WebhookStore,
  defer: (work: Promise<unknown>) => void,
  nowIso: () => string = () => new Date().toISOString()
): Promise<WebhookResult> {
  let body: WasiWebhookBody
  try {
    body = JSON.parse(rawBody)
  } catch {
    return { status: 400, body: { error: "Invalid JSON body" } }
  }

  if (body.event === "message.received") {
    const data = body.data as WasiMessageReceivedData
    const wabaId = data?.waba_id
    if (!wabaId) return { status: 401, body: { error: "Missing waba_id" } }

    const creds = await store.findCredentialsByWabaId(wabaId)
    if (!creds) return { status: 401, body: { error: "Unknown waba_id" } }
    if (!(await verifySignature(rawBody, signatureHeader, creds.webhookSecret))) return { status: 401, body: { error: "Invalid signature" } }

    const normalized = toNormalized(data)
    if (!normalized) {
      console.error("wasi-webhook: could not normalize message.received payload", data?.message_type)
      return { status: 200, body: { received: true } }
    }
    defer(
      store.processInbound(creds.orgId, normalized).catch((e) => logError("wasi-webhook: error handling inbound message", e))
    )
    return { status: 200, body: { received: true } }
  }

  if (body.event === "message.status") {
    const data = body.data as WasiMessageStatusData
    const messageId = data?.message_id
    if (!messageId) return { status: 200, body: { received: true } }

    const row = await store.findOutboxByWhatsAppId(messageId)
    if (!row) {
      // No row means no org and so no secret to verify against: acknowledged, nothing is written.
      console.error("wasi-webhook: message.status for an unknown message id, skipped")
      return { status: 200, body: { received: true, matched: false } }
    }
    if (!(await verifySignature(rawBody, signatureHeader, row.webhookSecret))) return { status: 401, body: { error: "Invalid signature" } }

    const patch = applyStatusEvent(
      { delivery_status: row.delivery_status, delivered_at: row.delivered_at, read_at: row.read_at },
      { status: data.status, error: data.error, at: data.timestamp ?? data.sent_at ?? null },
      nowIso()
    )
    if (patch) {
      defer(store.applyDeliveryUpdate(row.id, patch).catch((e) => logError("wasi-webhook: failed to update delivery status", e)))
    }
    return { status: 200, body: { received: true, matched: true } }
  }

  if (body.event === "message_template_status_update") {
    const data = body.data as { waba_id?: string; name?: string; template_name?: string; status?: string; event?: string } | null
    const wabaId = data?.waba_id
    const name = data?.name ?? data?.template_name
    const status = String(data?.status ?? data?.event ?? "").toLowerCase()
    if (wabaId && name && status) {
      const creds = await store.findCredentialsByWabaId(wabaId)
      if (creds) {
        if (!(await verifySignature(rawBody, signatureHeader, creds.webhookSecret))) return { status: 401, body: { error: "Invalid signature" } }
        defer(store.upsertTemplateStatus(creds.orgId, name, status).catch((e) => logError("wasi-webhook: failed to update template status", e)))
      }
    } else {
      console.error("wasi-webhook: message_template_status_update without waba_id/name/status, ignored")
    }
    return { status: 200, body: { received: true } }
  }

  // account_update and anything new: acknowledged so Wasi does not retry something we deliberately do not act on.
  console.error("wasi-webhook: unhandled event type, ignoring", body.event)
  return { status: 200, body: { received: true } }
}
