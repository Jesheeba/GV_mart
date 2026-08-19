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
import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2"
import { sendMessage } from "../_shared/whatsapp.ts"
import { routeInbound, tryHandleMechanic, type ConversationState, type InboundIntent } from "../_shared/whatsapp-journeys.ts"
import {
  enterServiceJourney,
  routeService,
  type AddressInfo,
  type CreateServiceTicketParams,
  type Identity,
  type SlotInfo,
} from "../_shared/whatsapp-service-journey.ts"
import {
  enterAccountJourney,
  enterAmcJourney,
  enterSalesJourney,
  enterSparesJourney,
  routeSales,
  routeSpares,
} from "../_shared/whatsapp-other-journeys.ts"
import { t, type WaLang } from "../_shared/i18n.ts"

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

type ConversationRow = {
  id: string
  org_id: string
  phone: string
  customer_id: string | null
  journey: string | null
  step: string | null
  collected: Record<string, unknown>
  status: "active" | "completed" | "expired" | "handed_off"
  expires_at: string | null
}

const STEP_TIMEOUT_MINUTES = 15

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

function addressSummary(a: { door_no: string | null; flat_no: string | null; street_cross: string | null; area: string | null; district: string | null }): string {
  return [a.flat_no, a.door_no, a.street_cross, a.area, a.district].filter(Boolean).join(", ")
}

/** Plain reads (not business-logic writes) needed to render the Service
 * journey's own steps — the customer's primary address and the org's
 * active appointment slots. No RLS concern: service_role bypasses it, and
 * these are read-only context, not the ticket write itself (that stays
 * behind wa_create_service_ticket's phone-ownership check). */
async function fetchServiceContext(admin: SupabaseClient, orgId: string, identity: Identity): Promise<{ address: AddressInfo | null; slots: SlotInfo[] }> {
  const { data: slotRows } = await admin.from("appointment_slots").select("id, name, start_time, end_time").eq("org_id", orgId).eq("is_active", true).order("sort_order")
  const slots: SlotInfo[] = slotRows ?? []

  if (!identity.customerId) return { address: null, slots }
  const { data: addr } = await admin
    .from("addresses")
    .select("id, door_no, flat_no, street_cross, area, district")
    .eq("customer_id", identity.customerId)
    .eq("is_primary", true)
    .maybeSingle()
  return { address: addr ? { id: addr.id, summary: addressSummary(addr) } : null, slots }
}

async function routeServiceTurn(
  admin: SupabaseClient,
  orgId: string,
  lang: WaLang,
  conversation: ConversationState,
  identity: Identity,
  intent: InboundIntent
) {
  const { address, slots } = await fetchServiceContext(admin, orgId, identity)
  return routeService({ lang, conversation, identity, address, slots, intent })
}

async function executeServiceAction(
  admin: SupabaseClient,
  orgId: string,
  phone: string,
  lang: WaLang,
  action: { type: string; params: Record<string, unknown> },
  identity: Identity
) {
  const params = action.params as unknown as CreateServiceTicketParams
  const { address } = await fetchServiceContext(admin, orgId, identity)
  if (!address) {
    return { nextState: { journey: "service", step: null, collected: {}, status: "handed_off" as const }, reply: { body: t(lang, "whatsapp.service.noAddress") } }
  }

  const { data, error } = await admin.rpc("wa_create_service_ticket", {
    p_org_id: orgId,
    p_phone: phone,
    p_address_id: address.id,
    p_product_id: params.productId,
    p_brand_id: null,
    p_model_id: null,
    p_name_of_complaint: params.nameOfComplaint,
    p_nature_of_complaint: params.nameOfComplaint,
    p_priority: params.priority,
    p_appointment_mode: "datetime",
    p_auto_assign: true,
    p_scheduled_date: params.scheduledDate,
    p_slot_id: params.slotId,
    p_unlisted_product_name: params.unlistedProductName,
    p_complaint_type_id: null,
  })

  if (error) {
    console.error("whatsapp-webhook: wa_create_service_ticket failed", error)
    return { nextState: { journey: "service", step: null, collected: {}, status: "handed_off" as const }, reply: { body: t(lang, "whatsapp.service.bookingFailed") } }
  }

  const ticketRef = (data.ticket_id as string).slice(0, 8)
  const body = t(lang, "whatsapp.service.confirmed", {
    ticketRef,
    date: params.scheduledDate,
    slotName: (data.slot_name as string) ?? "",
  })
  return { nextState: { journey: null, step: null, collected: {}, status: "completed" as const }, reply: { body } }
}

async function handleMessage(admin: SupabaseClient, orgId: string, msg: MetaInboundMessage) {
  // Kill switch — checked FIRST, before anything else, including the
  // idempotency log below. When off, the bot does not log, identify, route,
  // or reply to anything; Meta still gets its 200 from the caller so it
  // doesn't retry. Phase 4's ops surface toggles this.
  const { data: settingsRow, error: settingsError } = await admin.from("settings").select("whatsapp_bot_enabled").eq("org_id", orgId).maybeSingle()
  if (settingsError) throw settingsError
  if (settingsRow && settingsRow.whatsapp_bot_enabled === false) return

  // Idempotency — insert-or-detect-duplicate on wa_message_id before any
  // lookup, RPC, or reply happens. A unique-violation here means Meta
  // retried a delivery we already processed; stop, don't reprocess.
  const { error: dedupeError } = await admin.from("whatsapp_outbox").insert({
    org_id: orgId,
    direction: "inbound",
    to_mobile: null,
    template: "inbound.raw",
    type: msg.type ?? "text",
    payload: { from: msg.from, body: msg.text?.body ?? null, interactive: msg.interactive ?? null, meta_timestamp: msg.timestamp },
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
  const conv = conversation as ConversationRow

  // A handed-off conversation is out of the bot's hands until a human (or a
  // future "resume bot" action) reopens it — see Phase 4's ops surface,
  // not built yet. For now just stop routing; the message is still logged
  // above so a human can see it.
  if (conv.status === "handed_off") return

  const lang: WaLang = conv.collected?.lang === "ta" ? "ta" : "en"
  const isExpired = !!conv.expires_at && new Date(conv.expires_at).getTime() < Date.now()
  const intent = toIntent(msg)
  const identityForJourney: Identity = {
    found: !!identity?.found,
    customerId: identity?.found ? identity.customer_id : undefined,
    name: identity?.found ? (identity.name as string) : undefined,
    products: identity?.found ? (identity.products as Identity["products"]) : undefined,
    openTicket: identity?.found ? (identity.open_ticket as Identity["openTicket"]) : undefined,
    lastService: identity?.found ? (identity.last_service as Identity["lastService"]) : undefined,
  }
  const conversationState: ConversationState = { journey: conv.journey, step: conv.step, collected: conv.collected ?? {}, status: conv.status }

  // Mechanics (back/menu/cancel/talk-to-expert/language switch, plus the
  // step-timeout check) apply on EVERY step, not just while the generic
  // menu is showing — checked before any journey-specific router gets a
  // turn, so "back" typed mid-Service-booking doesn't get swallowed as a
  // literal answer to whatever question is currently being asked.
  const mechanicResult = tryHandleMechanic(lang, conversationState, isExpired, intent)

  let result = mechanicResult
    ? mechanicResult
    : conv.journey === "service"
      ? await routeServiceTurn(admin, orgId, lang, conversationState, identityForJourney, intent)
      : conv.journey === "sales"
        ? routeSales(lang, conversationState, intent)
        : conv.journey === "spares"
          ? routeSpares(lang, conversationState, intent)
          : routeInbound({ lang, conversation: conversationState, customerName: identityForJourney.name ?? null, isExpired: false, intent })

  // Menu just resolved to a journey — hand off from the generic placeholder
  // routeInbound picked to that journey's real entry point. Note: the menu
  // ROW is "Buy / Upgrade" (id "buy", matching its i18n label), but the
  // journey it starts is Sales, per the plan's own journey list — the menu
  // button text and the internal journey name are deliberately different.
  if (result.nextState.step === "intro") {
    if (result.nextState.journey === "service") {
      const { address, slots } = await fetchServiceContext(admin, orgId, identityForJourney)
      result = enterServiceJourney(lang, identityForJourney, address, slots)
    } else if (result.nextState.journey === "buy") {
      result = enterSalesJourney(lang)
    } else if (result.nextState.journey === "spares") {
      result = enterSparesJourney(lang, identityForJourney)
    } else if (result.nextState.journey === "amc") {
      result = enterAmcJourney(lang, identityForJourney)
    } else if (result.nextState.journey === "account") {
      result = enterAccountJourney(lang, identityForJourney)
    }
  }

  // A journey step asked for a write (action present) — perform it via the
  // matching phone-ownership-checked wa_* wrapper, then render the real
  // outcome instead of the placeholder reply the journey module returned.
  if (result.action) {
    if (result.action.type === "create_service_ticket") {
      result = await executeServiceAction(admin, orgId, msg.from, lang, result.action, identityForJourney)
    } else if (result.action.type === "create_lead") {
      const { error: leadError } = await admin.rpc("wa_create_lead", { p_org_id: orgId, p_phone: msg.from, p_trigger: null, p_body: result.action.params.body })
      if (leadError) {
        console.error("whatsapp-webhook: wa_create_lead failed", leadError)
        result = { nextState: { journey: null, step: null, collected: {}, status: "handed_off" }, reply: { body: t(lang, "whatsapp.mechanics.actionFailed") } }
      }
    } else if (result.action.type === "create_spare_enquiry") {
      const { error: enquiryError } = await admin.rpc("wa_create_spare_enquiry", {
        p_org_id: orgId,
        p_phone: msg.from,
        p_kind: "spare",
        p_enquiry_type: null,
        p_description: result.action.params.description,
        p_photo_url: null,
        p_address_id: null,
        p_items: [],
      })
      if (enquiryError) {
        console.error("whatsapp-webhook: wa_create_spare_enquiry failed", enquiryError)
        result = { nextState: { journey: null, step: null, collected: {}, status: "handed_off" }, reply: { body: t(lang, "whatsapp.mechanics.actionFailed") } }
      }
    }
  }

  const nextStatus = result.nextState.status
  await admin.rpc("wa_save_conversation_step", {
    p_org_id: orgId,
    p_phone: msg.from,
    p_journey: result.nextState.journey,
    p_step: result.nextState.step,
    p_collected: result.nextState.collected,
    p_customer_id: identity?.found ? identity.customer_id : null,
    p_status: nextStatus,
  })

  // Refresh the timeout window on every turn except a terminal one — a
  // handed-off or completed conversation has nothing left to time out of.
  if (nextStatus === "active") {
    await admin
      .from("whatsapp_conversations")
      .update({ expires_at: new Date(Date.now() + STEP_TIMEOUT_MINUTES * 60_000).toISOString() })
      .eq("id", conv.id)
  }

  await sendMessage(admin, {
    orgId,
    to: identity?.found ? (identity.phone as string) : msg.from,
    customerId: identity?.found ? (identity.customer_id as string) : null,
    template: `wa.${result.nextState.journey ?? "menu"}.${result.nextState.step ?? nextStatus}`,
    body: result.reply.body,
    interactive: result.reply.interactive,
    refType: "whatsapp_conversations",
    refId: conv.id,
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
      if (!value?.messages?.length) continue // status/receipt payloads, nothing to do

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
