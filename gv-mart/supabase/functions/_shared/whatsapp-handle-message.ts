// Extracted from whatsapp-webhook/index.ts so a second inbound provider
// (wasi-webhook) can share the exact same conversation-turn logic instead
// of reimplementing it. Everything below this point was already provider-
// agnostic before the extraction (see NormalizedInboundMessage) — this
// file just gives that logic a home neither webhook shell has to own.
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2"
import { DB_CALL_TIMEOUT_MS, sendMessage } from "./whatsapp.ts"
import { runMilestoneDispatch } from "./wa-milestone-dispatch-core.ts"
import { classifyWithClaude } from "./whatsapp-classify-intent.ts"
import { extractQuote } from "./whatsapp-extract-quote.ts"
import { matchMenuSelection, routeInbound, tryHandleMechanic, type ClassifiedIntent, type ConversationState, type InboundIntent, type RouteResult } from "./whatsapp-journeys.ts"
import {
  enterServiceJourney,
  routeService,
  type AddressInfo,
  type CreateServiceTicketParams,
  type Identity,
  type SlotInfo,
} from "./whatsapp-service-journey.ts"
import {
  enterAccountJourney,
  enterAmcJourney,
  enterSalesJourney,
  enterSparesJourney,
  routeSales,
  routeSpares,
} from "./whatsapp-other-journeys.ts"
import { t, type WaLang } from "./i18n.ts"

/** Provider-agnostic shape every inbound webhook shell (Meta's
 * whatsapp-webhook, Wasi's wasi-webhook, any future one) normalizes its
 * own wire format into before calling handleMessage. Nothing past this
 * type knows or cares which provider a message came from. */
export type NormalizedInboundMessage = {
  phone: string
  waMessageId: string
  timestamp: string
  intent: InboundIntent
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

function addressSummary(a: { door_no: string | null; flat_no: string | null; street_cross: string | null; area: string | null; district: string | null }): string {
  return [a.flat_no, a.door_no, a.street_cross, a.area, a.district].filter(Boolean).join(", ")
}

/** Which roles to alert when a customer asks for a human, based on which
 * journey they were in — mirrors the existing split elsewhere in this
 * codebase (service tickets notify operation_admin; product/spare/AMC leads
 * notify sales_admin, e.g. wa_bot_rpc_wrappers_phase2a.sql's
 * submit_customer_enquiry). Asked from the main menu or My Account (no
 * specific department implied) notifies both. */
function handoffNotifyRoles(journey: string | null): ("operation_admin" | "sales_admin")[] {
  if (journey === "service") return ["operation_admin"]
  if (journey === "sales" || journey === "spares" || journey === "amc") return ["sales_admin"]
  return ["operation_admin", "sales_admin"]
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
    console.error("whatsapp-handle-message: wa_create_service_ticket failed", error)
    return { nextState: { journey: "service", step: null, collected: {}, status: "handed_off" as const }, reply: { body: t(lang, "whatsapp.service.bookingFailed") } }
  }

  const ticketRef = (data.ticket_id as string).slice(0, 8)
  const body = t(lang, "whatsapp.service.confirmed", {
    ticketRef,
    date: params.scheduledDate,
    slotName: (data.slot_name as string) ?? "",
  })
  // Suppressed: _milestone_ticket_notify already messages the customer for
  // 'booked' (fires on insert) and 'assigned' (fires on the auto_assign
  // UPDATE right after) — this reply would be a redundant 3rd message for
  // the same booking. `body` is still computed and returned so a future
  // bug that ignores suppressReply still sends something coherent.
  //
  // Since that reply IS suppressed, runMilestoneDispatch below is the only
  // thing that actually gets those 'booked'/'assigned' messages to the
  // customer — awaited (not fire-and-forget) because this Edge Function
  // has no established pattern for background work that outlives the
  // response (no EdgeRuntime.waitUntil use anywhere in this codebase), so
  // an un-awaited call risks being killed mid-flight right when it matters
  // most: before the retried_at bookkeeping that prevents wa-milestone-
  // dispatch from double-sending the same row 5 minutes later. Caught, not
  // rethrown — a WhatsApp/Wasi hiccup here must never fail the booking
  // this function already committed; the 5-minute poller is still the
  // backstop if this fails or the function is killed before this line runs.
  try {
    await runMilestoneDispatch(admin, orgId)
  } catch (e) {
    console.error("whatsapp-handle-message: in-process runMilestoneDispatch failed, poller will retry", e)
  }
  return { nextState: { journey: null, step: null, collected: {}, status: "completed" as const }, reply: { body }, suppressReply: true }
}

/** Phase 5b — only worth an Anthropic call when the menu is showing, the
 * message is free text, and it doesn't already resolve via a tapped row or
 * a keyword match (matchMenuSelection). Missing/unreachable API key
 * degrades to undefined (no classification), same "never block routing on
 * this" philosophy as classifyWithClaude's own internal fallback. */
async function maybeClassifyIntent(conversation: ConversationState, intent: InboundIntent): Promise<ClassifiedIntent | undefined> {
  if (conversation.journey !== null || conversation.step !== "menu_shown") return undefined
  if (intent.kind !== "text") return undefined
  if (matchMenuSelection(intent)) return undefined

  const apiKey = Deno.env.get("ANTHROPIC_API_KEY")
  if (!apiKey) return undefined

  const result = await classifyWithClaude(intent.text, apiKey)
  if (result.fallback) return undefined
  return { intent: result.intent, confidence: result.confidence }
}

type SupplierIdentity = { supplier_id: string; name: string }
type OpenSupplierQuoteRequest = { request_id: string; item_name: string | null }

/** Gap A/B: a supplier's WhatsApp reply is never a conversation (no menu, no
 * journey/step, nothing that belongs in whatsapp_conversations, which is
 * schematically customer-only — see wa_identify_supplier's migration
 * comment). This is a single-shot side path: identify which open quote
 * request the reply is for, try to extract a price, log it or fall back to
 * asking an admin. Never touches whatsapp_conversations/wa_save_
 * conversation_step at all. */
async function notifyAdminAboutUnprocessedSupplierReply(
  admin: SupabaseClient,
  orgId: string,
  supplierName: string,
  rawText: string,
  reason: string
) {
  const { error } = await admin.from("notifications").insert({
    org_id: orgId,
    role: "operation_admin",
    type: "quote_reply_needs_review",
    title: "Supplier WhatsApp reply needs manual review",
    body: `${supplierName}'s reply could not be processed automatically (${reason}): "${rawText}". Log it from Purchase > Quotes.`,
    ref_id: null,
  })
  if (error) console.error("whatsapp-handle-message: failed to insert quote_reply_needs_review notification", error)
}

async function handleSupplierReply(admin: SupabaseClient, orgId: string, msg: NormalizedInboundMessage, supplier: SupplierIdentity) {
  if (msg.intent.kind !== "text") {
    await notifyAdminAboutUnprocessedSupplierReply(admin, orgId, supplier.name, "(non-text reply)", "reply was not plain text")
    return
  }
  const rawText = msg.intent.text

  // Gap A2: count-based disambiguation only for v1 (reply-context/swipe-to-
  // reply matching deferred — depends on the outbound send actually
  // capturing a real wa_message_id, and on confirming Wasi's inbound
  // webhook even carries a reply-to field; revisit only if the >1 case
  // turns out to be frequent once this is live).
  const { data: openRaw, error: openError } = await admin.rpc("wa_supplier_open_quote_requests", {
    p_org_id: orgId,
    p_supplier_id: supplier.supplier_id,
  })
  if (openError) throw openError
  const open = (openRaw ?? []) as OpenSupplierQuoteRequest[]

  if (open.length === 0) {
    await notifyAdminAboutUnprocessedSupplierReply(admin, orgId, supplier.name, rawText, "no open quote request from this supplier")
    return
  }
  if (open.length > 1) {
    await notifyAdminAboutUnprocessedSupplierReply(
      admin,
      orgId,
      supplier.name,
      rawText,
      `${open.length} open quote requests from this supplier - could not determine which one this reply answers`
    )
    return
  }
  const request = open[0]

  const apiKey = Deno.env.get("ANTHROPIC_API_KEY")
  if (!apiKey) {
    await notifyAdminAboutUnprocessedSupplierReply(admin, orgId, supplier.name, rawText, "extraction not configured")
    return
  }

  const extracted = await extractQuote(rawText, apiKey)
  if (!extracted.ok) {
    await notifyAdminAboutUnprocessedSupplierReply(admin, orgId, supplier.name, rawText, `could not extract a price (${extracted.reason})`)
    return
  }

  const { error: logError } = await admin.rpc("wa_log_quote_reply", {
    p_org_id: orgId,
    p_request_id: request.request_id,
    p_supplier_id: supplier.supplier_id,
    p_price: extracted.price,
    p_note: `Auto-extracted from WhatsApp (confidence ${extracted.confidence.toFixed(2)}${
      extracted.leadTimeDays != null ? `, lead time ${extracted.leadTimeDays}d` : ""
    })`,
  })
  if (logError) {
    console.error("whatsapp-handle-message: wa_log_quote_reply failed", logError)
    await notifyAdminAboutUnprocessedSupplierReply(admin, orgId, supplier.name, rawText, "internal error while logging the extracted reply")
    return
  }

  await sendMessage(admin, {
    orgId,
    to: msg.phone,
    customerId: null,
    template: "po.quote_reply_ack",
    body: `Thanks, got your quote for ${request.item_name ?? "the item"} - ₹${extracted.price}${
      extracted.leadTimeDays != null ? ` (${extracted.leadTimeDays} day delivery)` : ""
    }. We'll confirm the order shortly.`,
    refType: "purchase_quote_request",
    refId: request.request_id,
  })
}

export async function handleMessage(admin: SupabaseClient, orgId: string, msg: NormalizedInboundMessage) {
  // Idempotency — insert-or-detect-duplicate on wa_message_id before any
  // lookup, RPC, or reply happens, REGARDLESS of the kill switch or which
  // party this is. A unique-violation here means the provider retried a
  // delivery we already processed; stop, don't reprocess. Moved ahead of
  // the kill switch (it used to run first) so this dedupe guard still
  // covers supplier replies once the kill switch stops gating them, below.
  const { error: dedupeError } = await admin.from("whatsapp_outbox").insert({
    org_id: orgId,
    direction: "inbound",
    to_mobile: null,
    template: "inbound.raw",
    type: msg.intent.kind === "list_reply" ? "interactive" : "text",
    payload: {
      from: msg.phone,
      body: msg.intent.kind === "text" ? msg.intent.text : null,
      interactive: msg.intent.kind === "list_reply" ? { id: msg.intent.id } : null,
      source_timestamp: msg.timestamp,
    },
    wa_message_id: msg.waMessageId,
    status: "received",
  })
  if (dedupeError) {
    if (dedupeError.code === "23505") return // duplicate delivery — already handled, no-op
    throw dedupeError
  }

  // Gap A — check supplier before the kill switch and before falling
  // through to the customer-only identify/conversation machinery below.
  // Supplier RFQ logging is independent of the customer-bot kill switch by
  // design (owner decision): it's a separate, always-on operational path,
  // not "the bot" the switch is meant to silence. A supplier reply is also
  // never a conversation (see handleSupplierReply's own comment for why it
  // never touches whatsapp_conversations), so this is a full early return,
  // not a branch inside the journey router.
  const { data: supplierIdentity, error: supplierIdentifyError } = await admin
    .rpc("wa_identify_supplier", { p_org_id: orgId, p_phone: msg.phone })
    .abortSignal(AbortSignal.timeout(DB_CALL_TIMEOUT_MS))
  if (supplierIdentifyError) throw supplierIdentifyError
  if (supplierIdentity?.found) {
    await handleSupplierReply(admin, orgId, msg, { supplier_id: supplierIdentity.supplier_id as string, name: supplierIdentity.name as string })
    return
  }

  // Kill switch — everything from here down is "the bot" (customer
  // journeys). When off, it does not identify, route, or reply to a
  // customer; the caller still gets its 200 so it doesn't retry. Phase 4's
  // ops surface toggles this.
  const { data: settingsRow, error: settingsError } = await admin
    .from("settings")
    .select("whatsapp_bot_enabled")
    .eq("org_id", orgId)
    .abortSignal(AbortSignal.timeout(DB_CALL_TIMEOUT_MS))
    .maybeSingle()
  if (settingsError) throw settingsError
  if (settingsRow && settingsRow.whatsapp_bot_enabled === false) return

  const { data: identity, error: identifyError } = await admin
    .rpc("wa_identify_customer", { p_org_id: orgId, p_phone: msg.phone })
    .abortSignal(AbortSignal.timeout(DB_CALL_TIMEOUT_MS))
  if (identifyError) throw identifyError

  const { data: conversation, error: convError } = await admin
    .rpc("wa_get_conversation", { p_org_id: orgId, p_phone: msg.phone })
    .abortSignal(AbortSignal.timeout(DB_CALL_TIMEOUT_MS))
  if (convError) throw convError
  const conv = conversation as ConversationRow

  // A handed-off conversation is out of the bot's hands until a human (or a
  // future "resume bot" action) reopens it — see Phase 4's ops surface,
  // not built yet. For now just stop routing; the message is still logged
  // above so a human can see it.
  if (conv.status === "handed_off") return

  const lang: WaLang = conv.collected?.lang === "ta" ? "ta" : "en"
  const isExpired = !!conv.expires_at && new Date(conv.expires_at).getTime() < Date.now()
  const intent = msg.intent
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

  let result: RouteResult
  if (mechanicResult) {
    result = mechanicResult
  } else if (conv.journey === "service") {
    result = await routeServiceTurn(admin, orgId, lang, conversationState, identityForJourney, intent)
  } else if (conv.journey === "sales") {
    result = routeSales(lang, conversationState, intent)
  } else if (conv.journey === "spares") {
    result = routeSpares(lang, conversationState, intent)
  } else {
    const classifiedIntent = await maybeClassifyIntent(conversationState, intent)
    result = routeInbound({ lang, conversation: conversationState, customerName: identityForJourney.name ?? null, isExpired: false, intent, classifiedIntent })
  }

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
      result = await executeServiceAction(admin, orgId, msg.phone, lang, result.action, identityForJourney)
    } else if (result.action.type === "create_lead") {
      const { error: leadError } = await admin.rpc("wa_create_lead", { p_org_id: orgId, p_phone: msg.phone, p_trigger: null, p_body: result.action.params.body })
      if (leadError) {
        console.error("whatsapp-handle-message: wa_create_lead failed", leadError)
        result = { nextState: { journey: null, step: null, collected: {}, status: "handed_off" }, reply: { body: t(lang, "whatsapp.mechanics.actionFailed") } }
      }
    } else if (result.action.type === "create_spare_enquiry") {
      const { error: enquiryError } = await admin.rpc("wa_create_spare_enquiry", {
        p_org_id: orgId,
        p_phone: msg.phone,
        p_kind: "spare",
        p_enquiry_type: null,
        p_description: result.action.params.description,
        p_photo_url: null,
        p_address_id: null,
        p_items: [],
      })
      if (enquiryError) {
        console.error("whatsapp-handle-message: wa_create_spare_enquiry failed", enquiryError)
        result = { nextState: { journey: null, step: null, collected: {}, status: "handed_off" }, reply: { body: t(lang, "whatsapp.mechanics.actionFailed") } }
      }
    }
  }

  const nextStatus = result.nextState.status

  // 2026-08-26 incident: this reply attempt used to happen AFTER
  // wa_save_conversation_step below persisted the turn's next state. Any
  // failure in between (or in the state write's own follow-up steps) left
  // the conversation silently "ahead" of what the customer actually
  // received — the bot's own state said the turn was handled, nothing was
  // ever sent, and nothing surfaced the gap (both webhook shells catch and
  // log at the top level, returning 200 regardless).
  //
  // Reply now goes first. sendMessage() unconditionally logs every attempt
  // to whatsapp_outbox — success, a provider failure, or the no-credentials
  // stub — so once it returns normally, this turn is accounted for one way
  // or another and it's safe to advance the conversation's state. If
  // sendMessage() itself throws (its own outbox insert failing is the only
  // path left that can), that's a genuine infra failure with nothing
  // logged at all — deliberately NOT caught here, so it propagates up and
  // wa_save_conversation_step below never runs. The conversation's state
  // stays exactly where it was, and the customer's next message re-enters
  // the same step fresh instead of finding the bot already "moved on."
  if (!result.suppressReply) {
    await sendMessage(admin, {
      orgId,
      to: identity?.found ? (identity.phone as string) : msg.phone,
      customerId: identity?.found ? (identity.customer_id as string) : null,
      template: `wa.${result.nextState.journey ?? "menu"}.${result.nextState.step ?? nextStatus}`,
      body: result.reply.body,
      interactive: result.reply.interactive,
      refType: "whatsapp_conversations",
      refId: conv.id,
    })
  }

  await admin
    .rpc("wa_save_conversation_step", {
      p_org_id: orgId,
      p_phone: msg.phone,
      p_journey: result.nextState.journey,
      p_step: result.nextState.step,
      p_collected: result.nextState.collected,
      p_customer_id: identity?.found ? identity.customer_id : null,
      p_status: nextStatus,
    })
    .abortSignal(AbortSignal.timeout(DB_CALL_TIMEOUT_MS))

  // Staff currently have no other way to learn a customer asked for a human
  // (the conversation just goes quiet on the bot's end) — alert whichever
  // department owns the journey the customer was in. Only the two explicit
  // "talk to a person" triggers set handoffReason; the several other
  // bot-failure handoffs (unidentified caller, booking failed, etc.) stay
  // silent, unchanged.
  if (result.handoffReason === "expert_requested") {
    const customerLabel = identityForJourney.name ?? msg.phone
    const journeyLabel = result.nextState.journey ?? "main menu"
    const roles = handoffNotifyRoles(result.nextState.journey)
    const { error: notifyError } = await admin.from("notifications").insert(
      roles.map((role) => ({
        org_id: orgId,
        role,
        type: "whatsapp_handoff",
        title: "Customer asked to talk to a person",
        body: `${customerLabel} (${msg.phone}) asked for a human on WhatsApp while in the "${journeyLabel}" flow. Reply from Automation > Conversations.`,
        ref_id: conv.id,
      }))
    )
    if (notifyError) console.error("whatsapp-handle-message: failed to insert handoff notification", notifyError)
  }

  // Refresh the timeout window on every turn except a terminal one — a
  // handed-off or completed conversation has nothing left to time out of.
  if (nextStatus === "active") {
    await admin
      .from("whatsapp_conversations")
      .update({ expires_at: new Date(Date.now() + STEP_TIMEOUT_MINUTES * 60_000).toISOString() })
      .eq("id", conv.id)
      .abortSignal(AbortSignal.timeout(DB_CALL_TIMEOUT_MS))
  }
}
