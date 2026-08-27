// WhatsApp Integration — the real webhook the existing ADM-23 simulation
// never had (see InboundTestTab.tsx's own comment: "this is a Vite SPA
// with no server to host a real HTTP route on"). Follows the same shape as
// geocode/admin-create-technician: JWT verification is off for this one
// function only (see supabase/config.toml — Meta can't send a Supabase
// session), and authenticity is instead enforced by verifying Meta's own
// X-Hub-Signature-256 HMAC against WHATSAPP_APP_SECRET.
//
// Idempotency is the FIRST thing checked, before anything else runs — the
// proposal's #1 flagged real-world failure mode (Meta retries a delivery,
// a naive handler creates a duplicate ticket/lead).
//
// Phase 2b Step 1 adds the conversation state machine + main menu
// (routeInbound, in _shared/whatsapp-journeys.ts). Journey-specific step
// logic (Service in Step 2, Sales/Spares/AMC/Account in Step 3) extends
// that module without this file changing shape.
//
// The conversation-turn logic itself (handleMessage and everything it
// calls) now lives in _shared/whatsapp-handle-message.ts, shared with
// wasi-webhook/index.ts — this file's only job is Meta's specific wire
// format: signature verification, envelope parsing, org resolution, and
// normalizing a MetaInboundMessage into the provider-agnostic shape
// handleMessage expects.
import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2"
import { handleMessage, type NormalizedInboundMessage } from "../_shared/whatsapp-handle-message.ts"
import type { InboundIntent } from "../_shared/whatsapp-journeys.ts"

type MetaInboundMessage = {
  from: string
  id: string
  timestamp: string
  type: string
  text?: { body: string }
  interactive?: { type: string; list_reply?: { id: string; title: string }; button_reply?: { id: string; title: string } }
}

type MetaChangeValue = {
  metadata?: { phone_number_id?: string; display_phone_number?: string }
  messages?: MetaInboundMessage[]
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

function toIntent(msg: MetaInboundMessage): InboundIntent {
  if (msg.type === "interactive" && msg.interactive?.list_reply) return { kind: "list_reply", id: msg.interactive.list_reply.id }
  if (msg.type === "interactive" && msg.interactive?.button_reply) return { kind: "list_reply", id: msg.interactive.button_reply.id }
  return { kind: "text", text: msg.text?.body ?? "" }
}

function toNormalized(msg: MetaInboundMessage): NormalizedInboundMessage {
  return { phone: msg.from, waMessageId: msg.id, timestamp: msg.timestamp, intent: toIntent(msg) }
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
      if (!value?.messages?.length) continue // status/receipt payloads, nothing to do

      const orgId = await resolveOrgId(admin, value.metadata?.phone_number_id)
      if (!orgId) {
        console.error("whatsapp-webhook: could not resolve org_id for phone_number_id", value.metadata?.phone_number_id)
        continue
      }

      for (const msg of value.messages) {
        try {
          await handleMessage(admin, orgId, toNormalized(msg))
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
