// WhatsApp Integration, Phase 1 — the real webhook the existing ADM-23
// simulation never had (see InboundTestTab.tsx's own comment: "this is a
// Vite SPA with no server to host a real HTTP route on"). This is that
// route, as an Edge Function, following the same shape as geocode/
// admin-create-technician: JWT verification is off for this one function
// only (see supabase/config.toml — Meta can't send a Supabase session),
// and authenticity is instead enforced by verifying Meta's own
// X-Hub-Signature-256 HMAC against WHATSAPP_APP_SECRET.
//
// Two things this function is deliberately conservative about for Phase 1,
// left to Phase 2b:
//   - No journey/menu logic yet. It identifies the customer, loads/creates
//     the conversation row, and sends one acknowledgment reply — proving the
//     whole pipe end to end without building the state machine early.
//   - Idempotency is the FIRST thing checked, before anything else runs —
//     the proposal's #1 flagged real-world failure mode (Meta retries a
//     delivery, a naive handler creates a duplicate ticket/lead).
import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2"
import { sendMessage } from "../_shared/whatsapp.ts"

type MetaTextMessage = {
  from: string
  id: string
  timestamp: string
  type: string
  text?: { body: string }
}

type MetaChangeValue = {
  metadata?: { phone_number_id?: string; display_phone_number?: string }
  messages?: MetaTextMessage[]
  statuses?: unknown[]
}

type MetaWebhookBody = {
  entry?: { changes?: { value?: MetaChangeValue }[] }[]
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } })
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return diff === 0
}

async function verifySignature(rawBody: string, signatureHeader: string | null, appSecret: string): Promise<boolean> {
  if (!signatureHeader?.startsWith("sha256=")) return false
  const expectedHex = signatureHeader.slice("sha256=".length)
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(appSecret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"])
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(rawBody))
  const actualHex = Array.from(new Uint8Array(mac))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("")
  return timingSafeEqual(actualHex, expectedHex)
}

/** Resolves org_id via whatsapp_business_numbers (decision #6); falls back
 * to the sole organization row when that mapping table is still empty —
 * true until Phase 0's Meta verification produces a real phone_number_id,
 * and harmless afterwards for this single-tenant deployment. */
async function resolveOrgId(admin: SupabaseClient, phoneNumberId: string | undefined): Promise<string | null> {
  if (phoneNumberId) {
    const { data } = await admin.from("whatsapp_business_numbers").select("org_id").eq("phone_number_id", phoneNumberId).maybeSingle()
    if (data?.org_id) return data.org_id
  }
  const { data: orgs } = await admin.from("organizations").select("id").limit(2)
  if (orgs?.length === 1) return orgs[0].id
  return null
}

async function handleMessage(admin: SupabaseClient, orgId: string, msg: MetaTextMessage) {
  // Idempotency FIRST — insert-or-detect-duplicate on wa_message_id before
  // any lookup, RPC, or reply happens. A unique-violation here means Meta
  // retried a delivery we already processed; stop, don't reprocess.
  const { error: dedupeError } = await admin.from("whatsapp_outbox").insert({
    org_id: orgId,
    direction: "inbound",
    to_mobile: null,
    template: "inbound.raw",
    type: msg.type ?? "text",
    payload: { from: msg.from, body: msg.text?.body ?? null, meta_timestamp: msg.timestamp },
    wa_message_id: msg.id,
    status: "received",
  })
  if (dedupeError) {
    if (dedupeError.code === "23505") return // duplicate delivery — already handled, no-op
    throw dedupeError
  }

  const { data: identity, error: identifyError } = await admin.rpc("wa_identify_customer", { p_org_id: orgId, p_phone: msg.from })
  if (identifyError) throw identifyError

  const { data: conversation, error: convError } = await admin.rpc("wa_get_conversation", { p_org_id: orgId, p_phone: msg.from })
  if (convError) throw convError

  if (identity?.found && !conversation.customer_id) {
    await admin.rpc("wa_save_conversation_step", {
      p_org_id: orgId,
      p_phone: msg.from,
      p_journey: conversation.journey,
      p_step: conversation.step,
      p_customer_id: identity.customer_id,
    })
  }

  // Phase 1 only proves the pipe end to end — journeys/menu land in Phase 2b.
  const ackBody = identity?.found
    ? `Hi ${identity.name as string}, thanks for messaging GV Mart — we've received your message and will be in touch shortly.`
    : "Thanks for messaging GV Mart — we've received your message and will be in touch shortly."

  await sendMessage(admin, {
    orgId,
    to: identity?.phone ?? msg.from,
    customerId: identity?.customer_id ?? null,
    template: "wa.phase1_ack",
    body: ackBody,
    refType: "whatsapp_conversations",
    refId: conversation.id,
  })
}

Deno.serve(async (req) => {
  const url = new URL(req.url)

  if (req.method === "GET") {
    const verifyToken = Deno.env.get("WHATSAPP_VERIFY_TOKEN")
    const mode = url.searchParams.get("hub.mode")
    const token = url.searchParams.get("hub.verify_token")
    const challenge = url.searchParams.get("hub.challenge")
    if (!verifyToken) return jsonResponse({ error: "Not configured (missing WHATSAPP_VERIFY_TOKEN)" }, 500)
    if (mode === "subscribe" && token === verifyToken && challenge) {
      return new Response(challenge, { status: 200, headers: { "Content-Type": "text/plain" } })
    }
    return jsonResponse({ error: "Verification failed" }, 403)
  }

  if (req.method !== "POST") return jsonResponse({ error: "Method not allowed" }, 405)

  const appSecret = Deno.env.get("WHATSAPP_APP_SECRET")
  const supabaseUrl = Deno.env.get("SUPABASE_URL")
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
  if (!appSecret || !supabaseUrl || !serviceRoleKey) {
    return jsonResponse({ error: "Not configured (missing WHATSAPP_APP_SECRET or Supabase service credentials)" }, 500)
  }

  const rawBody = await req.text()
  const isValid = await verifySignature(rawBody, req.headers.get("X-Hub-Signature-256"), appSecret)
  if (!isValid) return jsonResponse({ error: "Invalid signature" }, 401)

  let body: MetaWebhookBody
  try {
    body = JSON.parse(rawBody)
  } catch {
    return jsonResponse({ error: "Invalid JSON body" }, 400)
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { autoRefreshToken: false, persistSession: false } })

  for (const entry of body.entry ?? []) {
    for (const change of entry.changes ?? []) {
      const value = change.value
      if (!value?.messages?.length) continue // status/receipt payloads, nothing to do in Phase 1

      const orgId = await resolveOrgId(admin, value.metadata?.phone_number_id)
      if (!orgId) {
        console.error("whatsapp-webhook: could not resolve org_id for phone_number_id", value.metadata?.phone_number_id)
        continue
      }

      for (const msg of value.messages) {
        try {
          await handleMessage(admin, orgId, msg)
        } catch (e) {
          // Log and move on — Meta expects a fast 200 regardless of a single
          // message's processing outcome; a thrown error here would make
          // Meta retry the whole batch, re-tripping the same failure.
          console.error("whatsapp-webhook: error handling message", msg.id, e)
        }
      }
    }
  }

  // Meta requires a fast 200 to consider the delivery accepted.
  return jsonResponse({ received: true })
})
