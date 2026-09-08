// Wasi WhatsApp BSP connector — inbound webhook. Additive alongside
// whatsapp-webhook (Meta's direct webhook): both call the same shared
// handleMessage() (see _shared/whatsapp-handle-message.ts), each owning
// only its own provider's wire format and authenticity check. No GET
// verification handshake — confirmed with Wasi this isn't needed, unlike
// Meta's hub.challenge dance.
//
// Wasi's webhook_secret is per-org (per plan decision, credential storage
// in whatsapp_provider_credentials), not a single env var — so unlike
// whatsapp-webhook, org resolution has to happen BEFORE signature
// verification here: we can't know which secret to check against until we
// know which org this payload claims to be for. This mirrors how other
// multi-tenant webhook providers (Stripe Connect etc.) do it — reading an
// identifying field out of the payload is not "trusting" it, we still
// reject on signature mismatch afterwards, and nothing derived from the
// payload is acted on before that check passes.
import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2"
import { handleMessage, type NormalizedInboundMessage } from "../_shared/whatsapp-handle-message.ts"

type WasiContact = { wa_id: string; name?: string }
// button_reply is production-verified against a real tap (Wasi support,
// 2026-08-27); list_reply is spec-derived from their docs but NOT yet
// confirmed against a real live list-message tap — see the defensive
// logging in toNormalized below, added specifically because of that gap.
type WasiInteractiveReply =
  | { type: "button_reply"; id: string; title: string }
  | { type: "list_reply"; id: string; title: string; description?: string }
type WasiMessage = { body?: string; sent_at?: string; interactive?: WasiInteractiveReply }
type WasiMessageReceivedData = {
  chat_id?: string
  message_id: string
  message_type: string
  contact: WasiContact
  message?: WasiMessage
  waba_id: string
  enqueued_at?: string
}
type WasiMessageStatusData = { message_id: string; status: string; error?: unknown }
type WasiWebhookBody = { event: string; data: unknown }

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } })
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return diff === 0
}

/** Same HMAC-SHA256 "sha256=<hex>" scheme as whatsapp-webhook's
 * verifySignature, kept as its own small copy here rather than shared —
 * the two providers' header names and secret sources differ enough
 * (single env var vs. per-org DB lookup) that sharing would mean this
 * function reaching into whatsapp-webhook/index.ts, which we're
 * deliberately not touching beyond the extraction already done. */
async function verifyWasiSignature(rawBody: string, signatureHeader: string | null, secret: string): Promise<boolean> {
  if (!signatureHeader?.startsWith("sha256=")) return false
  const expectedHex = signatureHeader.slice("sha256=".length)
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"])
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(rawBody))
  const actualHex = Array.from(new Uint8Array(mac))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("")
  return timingSafeEqual(actualHex, expectedHex)
}

/** message.received: org is resolved from the payload's own waba_id — the
 * only org-identifying field Wasi's message.received data carries. */
async function resolveCredentialsByWabaId(admin: SupabaseClient, wabaId: string): Promise<{ orgId: string; webhookSecret: string } | null> {
  const { data } = await admin
    .from("whatsapp_provider_credentials")
    .select("org_id, webhook_secret")
    .eq("provider", "wasi")
    .eq("waba_id", wabaId)
    .eq("is_active", true)
    .maybeSingle()
  if (!data) return null
  return { orgId: data.org_id, webhookSecret: data.webhook_secret }
}

/** message.status: Wasi's payload has no waba_id at all, so org has to be
 * resolved a different way — via the whatsapp_outbox row we ourselves
 * created when the original message was sent (it already carries org_id).
 * This is a plain read, not a decision to trust the payload; the signature
 * still has to check out against that org's secret before anything writes. */
async function resolveCredentialsByOutboxMessageId(admin: SupabaseClient, messageId: string): Promise<{ outboxId: string; orgId: string; webhookSecret: string } | null> {
  const { data: outboxRow } = await admin.from("whatsapp_outbox").select("id, org_id").eq("wa_message_id", messageId).maybeSingle()
  if (!outboxRow) return null
  const { data: cred } = await admin
    .from("whatsapp_provider_credentials")
    .select("webhook_secret")
    .eq("provider", "wasi")
    .eq("org_id", outboxRow.org_id)
    .eq("is_active", true)
    .maybeSingle()
  if (!cred) return null
  return { outboxId: outboxRow.id, orgId: outboxRow.org_id, webhookSecret: cred.webhook_secret }
}

function toNormalized(data: WasiMessageReceivedData): NormalizedInboundMessage | null {
  if (!data.contact?.wa_id || !data.message_id) return null
  const timestamp = data.message?.sent_at ?? data.enqueued_at ?? new Date().toISOString()

  if (data.message_type === "text") {
    return { phone: data.contact.wa_id, waMessageId: data.message_id, timestamp, intent: { kind: "text", text: data.message?.body ?? "" } }
  }

  if (data.message_type === "interactive") {
    const interactive = data.message?.interactive
    if (interactive?.type === "list_reply") {
      // TEMPORARY — remove once a real list-message tap has been confirmed
      // to actually match this shape (Wasi support flagged list_reply as
      // spec-derived, not yet verified against a real live tap, unlike
      // button_reply below which is production-confirmed). Log the whole
      // raw payload so a spec-vs-reality mismatch is caught immediately —
      // e.g. a wrong field name — instead of silently mis-parsing and only
      // noticing once routing looks broken downstream.
      console.log("wasi-webhook: UNVERIFIED list_reply payload — logging in full until confirmed against a real tap:", JSON.stringify(data))
    }
    if ((interactive?.type === "button_reply" || interactive?.type === "list_reply") && typeof interactive.id === "string" && interactive.id) {
      return { phone: data.contact.wa_id, waMessageId: data.message_id, timestamp, intent: { kind: "list_reply", id: interactive.id } }
    }
    console.error("wasi-webhook: interactive message with no usable interactive.id", JSON.stringify(data))
    return null
  }

  // Stopgap (approved) for any OTHER non-text, non-interactive message_type
  // Wasi might send (e.g. media): treat a present body as free text rather
  // than guess a field name and silently misroute; otherwise skip routing.
  if (data.message?.body) {
    return { phone: data.contact.wa_id, waMessageId: data.message_id, timestamp, intent: { kind: "text", text: data.message.body } }
  }
  return null
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return jsonResponse({ error: "Method not allowed" }, 405)

  const supabaseUrl = Deno.env.get("SUPABASE_URL")
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
  if (!supabaseUrl || !serviceRoleKey) {
    return jsonResponse({ error: "Not configured (missing Supabase service credentials)" }, 500)
  }

  const rawBody = await req.text()
  let body: WasiWebhookBody
  try {
    body = JSON.parse(rawBody)
  } catch {
    return jsonResponse({ error: "Invalid JSON body" }, 400)
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { autoRefreshToken: false, persistSession: false } })
  const signatureHeader = req.headers.get("x-wasi-signature-256")

  if (body.event === "message.received") {
    const data = body.data as WasiMessageReceivedData
    const wabaId = data?.waba_id
    if (!wabaId) return jsonResponse({ error: "Missing waba_id" }, 401)

    const creds = await resolveCredentialsByWabaId(admin, wabaId)
    if (!creds) return jsonResponse({ error: "Unknown waba_id" }, 401)

    const isValid = await verifyWasiSignature(rawBody, signatureHeader, creds.webhookSecret)
    if (!isValid) return jsonResponse({ error: "Invalid signature" }, 401)

    const normalized = toNormalized(data)
    if (!normalized) {
      console.error("wasi-webhook: could not normalize message.received payload (non-text message_type with no body, or missing contact/message_id)", data?.message_type)
      return jsonResponse({ received: true })
    }

    try {
      await handleMessage(admin, creds.orgId, normalized)
    } catch (e) {
      // Log and move on — same reasoning as whatsapp-webhook: give Wasi a
      // fast 200 regardless of a single message's processing outcome, so a
      // thrown error here doesn't trigger a retry storm on the same failure.
      console.error("wasi-webhook: error handling message", normalized.waMessageId, e)
    }
    return jsonResponse({ received: true })
  }

  if (body.event === "message.status") {
    const data = body.data as WasiMessageStatusData
    const messageId = data?.message_id
    if (!messageId) return jsonResponse({ received: true })

    // Approved fallback: if we don't have an outbox row for this
    // message_id, there's no org to verify the signature against — log and
    // no-op with 200 rather than 401 (an unrecognized message id isn't
    // necessarily a forged request, e.g. it could predate this table).
    const creds = await resolveCredentialsByOutboxMessageId(admin, messageId)
    if (!creds) {
      console.error("wasi-webhook: message.status for unknown wa_message_id, skipping", messageId)
      return jsonResponse({ received: true })
    }

    const isValid = await verifyWasiSignature(rawBody, signatureHeader, creds.webhookSecret)
    if (!isValid) return jsonResponse({ error: "Invalid signature" }, 401)

    const { error: updateError } = await admin
      .from("whatsapp_outbox")
      .update({ status: data.status, error: data.error ? JSON.stringify(data.error) : null })
      .eq("id", creds.outboxId)
    if (updateError) console.error("wasi-webhook: failed to update whatsapp_outbox status", updateError)

    return jsonResponse({ received: true })
  }

  // Forward-compatible: an event we don't handle yet (e.g. Wasi's
  // message_template_status_update, separate future work) — acknowledge
  // rather than error, so Wasi doesn't retry something we deliberately
  // aren't acting on.
  console.error("wasi-webhook: unhandled event type, ignoring", body.event)
  return jsonResponse({ received: true })
})
