// Extracted from whatsapp-webhook/index.ts so a second inbound provider
// (wasi-webhook) can share the exact same conversation-turn logic instead
// of reimplementing it. Everything below this point was already provider-
// agnostic before the extraction (see NormalizedInboundMessage) — this
// file just gives that logic a home neither webhook shell has to own.
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2"
import { DB_CALL_TIMEOUT_MS, renderWaTemplate, sendMessage } from "./whatsapp.ts"
import { runMilestoneDispatch } from "./wa-milestone-dispatch-core.ts"
import { checkFreeTextRelevance, classifyWithClaude } from "./whatsapp-classify-intent.ts"
import { extractQuoteDeterministic } from "./whatsapp-extract-quote-deterministic.ts"
import { answerCustomerQuestion } from "./whatsapp-answer-layer.ts"
import { answerStatusTrigger, matchStatusTrigger } from "./whatsapp-status-answers.ts"
import {
  buildMenuReply,
  containsPaymentRedFlag,
  matchMenuSelection,
  routeInbound,
  tryHandleMechanic,
  type ClassifiedIntent,
  type ConversationState,
  type InboundIntent,
  type RouteResult,
} from "./whatsapp-journeys.ts"
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
  routeAmc,
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

/** 2026-08-27 decision, REVISED 2026-08-28: when the menu resolves to Sales
 * from actual free text (a keyword match or a confident Phase 5b
 * classification — never a menu tap, which carries no question to answer),
 * that text is often already a specific interest statement ("how much is a
 * RO purifier"), not just a vague "I want to buy something" — so skip the
 * "what are you looking for?" round-trip and go straight to capturing it.
 *
 * This used to also try the Answer Layer here first (get_product_price)
 * and reply with a real grounded price. 2026-08-28 business decision:
 * never disclose real prices over WhatsApp — get_product_price was removed
 * from the Answer Layer's tool list entirely (whatsapp-answer-layer.ts),
 * so calling answerCustomerQuestion from here would now always resolve to
 * cannot_answer (no remaining tool is relevant to a "buy"-classified
 * message) — that round-trip is skipped rather than made pointlessly, and
 * this always acknowledges + captures the lead deterministically instead.
 * A menu tap (intent.kind !== "text") still goes to the ordinary
 * enterSalesJourney ask_interest prompt — there's no text yet to capture. */
async function enterOrAnswerSalesJourney(admin: SupabaseClient, orgId: string, phone: string, lang: WaLang, intent: InboundIntent): Promise<RouteResult> {
  if (intent.kind !== "text") return enterSalesJourney(lang)

  const { error: leadError } = await admin.rpc("wa_create_lead", { p_org_id: orgId, p_phone: phone, p_trigger: null, p_body: intent.text })
  if (leadError) console.error("whatsapp-handle-message: wa_create_lead (sales entry) failed", leadError)

  return {
    nextState: { journey: null, step: null, collected: {}, status: "completed" },
    reply: { body: t(lang, "whatsapp.sales.teamWillContact") },
  }
}

/** Phase 5b — only worth an Anthropic call when the menu is showing (or this
 * is a fresh conversation's very first message — widened 2026-08-27 so real
 * first-contact content like "how much is the Kent Grand Plus RO" gets a
 * shot at classification instead of always falling to the canned greeting,
 * see routeInbound's own journey===null/step===null branch), the message is
 * free text, and it doesn't already resolve via a tapped row or a keyword
 * match (matchMenuSelection). A bare greeting never reaches here at all —
 * tryHandleMechanic claims it first and short-circuits the rest of routing.
 * Missing/unreachable API key degrades to undefined (no classification),
 * same "never block routing on this" philosophy as classifyWithClaude's own
 * internal fallback. */
async function maybeClassifyIntent(conversation: ConversationState, intent: InboundIntent): Promise<ClassifiedIntent | undefined> {
  const menuActive = conversation.journey === null && (conversation.step === "menu_shown" || conversation.step === null)
  if (!menuActive) return undefined
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

/** Phase 4 deterministic "did it arrive" trigger — a supplier reply with no
 * open RFQ to interpret it against, but WITH a PO still `status='sent'`, is
 * treated as a cue to ask the admin. Never classifies what the reply
 * actually says (dispatch vs. delivery vs. anything else) — see
 * wa_supplier_latest_sent_po's own migration comment for why; presence of
 * ANY reply while a PO is outstanding is the entire signal, matching the
 * "no AI, logic only" constraint this whole feature was built under.
 * Deduped so a chatty supplier doesn't spawn a fresh prompt per message —
 * only inserted if no unread one already exists for this PO. */
async function notifyAboutPoReceiptCheck(admin: SupabaseClient, orgId: string, supplier: SupplierIdentity, msg: NormalizedInboundMessage, poId: string) {
  const { data: existing } = await admin
    .from("notifications")
    .select("id")
    .eq("org_id", orgId)
    .eq("type", "po_receipt_check_prompt")
    .eq("ref_id", poId)
    .eq("is_read", false)
    .limit(1)
    .maybeSingle()

  if (!existing) {
    const body = `${supplier.name} replied on WhatsApp — did this order arrive? Confirm from Purchase > Purchase Orders.`
    // One row per role (notifications.role is a single value, not an
    // array) — same shape as Phase 3's po_approval_pending notification.
    const { error } = await admin.from("notifications").insert([
      { org_id: orgId, role: "master", type: "po_receipt_check_prompt", title: "Did this order arrive?", body, ref_id: poId },
      { org_id: orgId, role: "operation_admin", type: "po_receipt_check_prompt", title: "Did this order arrive?", body, ref_id: poId },
    ])
    if (error) console.error("whatsapp-handle-message: failed to insert po_receipt_check_prompt notification", error)
  }

  // Admin-overridable via Automation > Templates (row name "po.receipt_check_ack",
  // {{1}} -> supplier_name in variable_map) — same pattern as po.quote_request.
  // found:false (no override configured yet) is the normal state, not an
  // error; falls back to this default wording.
  const rendered = await renderWaTemplate(admin, orgId, "po.receipt_check_ack", { supplier_name: supplier.name })
  const ackBody = rendered.found ? rendered.body : "Thanks, we've notified our team."

  await sendMessage(admin, {
    orgId,
    to: msg.phone,
    customerId: null,
    template: "po.receipt_check_ack",
    type: rendered.found ? "template" : "text",
    body: ackBody,
    refType: "purchase_order",
    refId: poId,
  })
}

async function handleSupplierReply(admin: SupabaseClient, orgId: string, msg: NormalizedInboundMessage, supplier: SupplierIdentity) {
  // Gap A2: count-based disambiguation only for v1 (reply-context/swipe-to-
  // reply matching deferred — depends on the outbound send actually
  // capturing a real wa_message_id, and on confirming Wasi's inbound
  // webhook even carries a reply-to field; revisit only if the >1 case
  // turns out to be frequent once this is live).
  //
  // Checked before the text/non-text split (unlike the extraction path
  // below, which only ever makes sense for text) so a delivery-photo reply
  // — not just a text one — can still surface the receipt-check prompt.
  const { data: openRaw, error: openError } = await admin.rpc("wa_supplier_open_quote_requests", {
    p_org_id: orgId,
    p_supplier_id: supplier.supplier_id,
  })
  if (openError) throw openError
  const open = (openRaw ?? []) as OpenSupplierQuoteRequest[]

  if (open.length === 0) {
    const { data: latestSentPoId, error: poLookupError } = await admin.rpc("wa_supplier_latest_sent_po", {
      p_org_id: orgId,
      p_supplier_id: supplier.supplier_id,
    })
    if (poLookupError) throw poLookupError
    if (latestSentPoId) {
      await notifyAboutPoReceiptCheck(admin, orgId, supplier, msg, latestSentPoId as string)
      return
    }
    await notifyAdminAboutUnprocessedSupplierReply(
      admin,
      orgId,
      supplier.name,
      msg.intent.kind === "text" ? msg.intent.text : "(non-text reply)",
      "no open quote request from this supplier"
    )
    return
  }

  if (msg.intent.kind !== "text") {
    await notifyAdminAboutUnprocessedSupplierReply(admin, orgId, supplier.name, "(non-text reply)", "reply was not plain text")
    return
  }
  const rawText = msg.intent.text

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

  // wa_quote_extraction_enabled originally gated a live Anthropic call; the
  // owner's 2026-08-28 zero-AI decision disabled that call org-wide, and on
  // 2026-09-01 the extractor itself was replaced with pure regex logic (see
  // whatsapp-extract-quote-deterministic.ts) — no AI involved at all, so
  // this flag is repurposed (same column, same admin toggle in
  // AutomationPage.tsx) to simply turn automatic parsing on/off. Off means
  // every supplier reply falls through to the SAME existing manual-review
  // notification this function already used for every other failure case
  // below (ambiguous quote request, extraction failure) — reused as-is:
  // staff already had "Log it from Purchase > Quotes" for those.
  const { data: quoteSettingsRow } = await admin.from("settings").select("wa_quote_extraction_enabled").eq("org_id", orgId).maybeSingle()
  const quoteExtractionEnabled = quoteSettingsRow?.wa_quote_extraction_enabled === true
  if (!quoteExtractionEnabled) {
    await notifyAdminAboutUnprocessedSupplierReply(admin, orgId, supplier.name, rawText, "automatic quote parsing is disabled — needs manual entry")
    return
  }

  const extracted = await extractQuoteDeterministic(rawText)
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

/** TS mirror of _wa_normalize_phone (SQL, 20260819120000) — same digits-only
 * + strip-leading-91 logic, kept in sync deliberately rather than an RPC
 * round trip just for this. Only the 10-digit and 91-prefixed-10-digit
 * cases are resolved (matching every phone value this codebase actually
 * sees); anything else is returned unchanged rather than nulled out, since
 * NormalizedInboundMessage.phone is non-nullable and downstream wa_* RPCs
 * already handle an unresolvable phone as their own "not found" case. */
function _wa_normalizeInboundPhone(raw: string): string {
  const digits = raw.replace(/\D/g, "")
  if (/^\d{10}$/.test(digits)) return digits
  if (/^91\d{10}$/.test(digits)) return digits.slice(2)
  return raw
}

// 2026-08-28: routeSales/routeSpares/routeService's free-text capture steps
// used to accept ANY non-empty text verbatim as a real lead/enquiry/ticket
// field — typing "food" at "which spare part do you need" silently became
// a real spare enquiry. journey -> step -> a short description of what's
// being asked, fed to checkFreeTextRelevance below. Add an entry here for
// any future free-text capture step so it gets the same guard by default.
const FREE_TEXT_CAPTURE_STEPS: Record<string, Record<string, string>> = {
  sales: { ask_interest: "what product or upgrade they're interested in buying" },
  spares: { ask_spare: "which spare part or accessory they need, and for which product" },
  service: {
    ask_unlisted_product: "what product needs service",
    ask_problem: "what problem or issue they're facing with their product",
  },
}

/** Checked in the impure shell, BEFORE the journey routers (which stay
 * pure, no network calls) ever see the text — same reasoning as
 * maybeClassifyIntent/answerCustomerQuestion living here instead of inside
 * routeInbound. Returns null (no-op) for every case except a block.
 *
 * Two independent checks, in order:
 * 1. containsPaymentRedFlag — deterministic, non-AI, ALWAYS runs regardless
 *    of classifyIntentEnabled (it isn't AI, so it doesn't go dark with the
 *    rest). Added 2026-08-28 after a customer asked the bot for a GPay
 *    number; with AI Routing off there was otherwise zero protection left
 *    on these free-text fields at all.
 * 2. checkFreeTextRelevance — the AI relevance check, only when
 *    classifyIntentEnabled; fails open on any classifier error/timeout. */
async function checkOffTopicCapture(
  lang: WaLang,
  conversation: ConversationState,
  intent: InboundIntent,
  classifyIntentEnabled: boolean
): Promise<RouteResult | null> {
  if (intent.kind !== "text" || !conversation.journey) return null
  const question = FREE_TEXT_CAPTURE_STEPS[conversation.journey]?.[conversation.step ?? ""]
  if (!question) return null

  if (containsPaymentRedFlag(intent.text)) {
    console.error("whatsapp-handle-message: blocked free-text capture — payment red flag", conversation.journey, conversation.step)
    const menu = buildMenuReply(lang)
    return {
      nextState: conversation,
      reply: { body: `${t(lang, "whatsapp.mechanics.casualChitchat")}\n\n${menu.body}`, interactive: menu.interactive },
    }
  }

  if (!classifyIntentEnabled) return null
  const apiKey = Deno.env.get("ANTHROPIC_API_KEY")
  if (!apiKey) return null

  const relevance = await checkFreeTextRelevance(question, intent.text, apiKey)
  if (relevance.fallback || relevance.relevant) return null

  const menu = buildMenuReply(lang)
  return {
    nextState: conversation,
    reply: { body: `${t(lang, "whatsapp.mechanics.casualChitchat")}\n\n${menu.body}`, interactive: menu.interactive },
  }
}

// 2026-08-28 (phrase manager, spec section 5.2) — staff-added trigger
// phrases, additive on top of the hardcoded TRIGGER_PHRASES/
// MENU_ITEM_SYNONYMS baseline (never a replacement for it). Deliberately
// scoped to the same categories the DB CHECK enum allows — mechanics/
// greetings/red-flag phrases have no row shape here at all, so there's no
// way to extend those from this table even by mistake. Fails open (empty
// maps) on any read error — never block routing on this table being
// briefly unreachable.
const CUSTOM_CATEGORY_TO_MENU_ITEM: Record<string, string> = {
  menu_buy: "buy",
  menu_service: "service",
  menu_spares: "spares",
  menu_amc: "amc",
  menu_account: "account",
  menu_expert: "expert",
}

type CustomTriggerPhrases = { statusPhrases: Record<string, string[]>; availabilityPhrases: string[]; menuSynonyms: Record<string, string[]> }
const customTriggerPhrasesCache = new Map<string, { value: CustomTriggerPhrases; expiresAt: number }>()
const CUSTOM_TRIGGER_PHRASES_CACHE_TTL_MS = 30_000

async function fetchCustomTriggerPhrases(
  admin: SupabaseClient,
  orgId: string
): Promise<{ statusPhrases: Record<string, string[]>; availabilityPhrases: string[]; menuSynonyms: Record<string, string[]> }> {
  // 2026-08-31 (latency): staff edit this table rarely (Bot Phrases tab),
  // but it was being re-fetched on every single text message regardless.
  // Cached per orgId for 30s at module scope — a newly-added phrase taking
  // up to 30s to go live is a reasonable trade for cutting a DB round trip
  // off most messages; nothing here is safety-critical the way the kill
  // switch below is, so unlike settings this one IS cached.
  const cached = customTriggerPhrasesCache.get(orgId)
  if (cached && cached.expiresAt > Date.now()) return cached.value

  const empty = { statusPhrases: {}, availabilityPhrases: [], menuSynonyms: {} }
  const { data, error } = await admin
    .from("wa_custom_trigger_phrases")
    .select("category, phrase")
    .eq("org_id", orgId)
    .eq("is_active", true)
    .abortSignal(AbortSignal.timeout(DB_CALL_TIMEOUT_MS))
  if (error) {
    console.error("whatsapp-handle-message: failed to read custom trigger phrases, continuing without them", error)
    return empty
  }

  const statusPhrases: Record<string, string[]> = {}
  const availabilityPhrases: string[] = []
  const menuSynonyms: Record<string, string[]> = {}
  for (const row of data ?? []) {
    if (row.category === "product_availability") {
      availabilityPhrases.push(row.phrase)
    } else if (row.category in CUSTOM_CATEGORY_TO_MENU_ITEM) {
      const menuItem = CUSTOM_CATEGORY_TO_MENU_ITEM[row.category]
      menuSynonyms[menuItem] = [...(menuSynonyms[menuItem] ?? []), row.phrase]
    } else {
      statusPhrases[row.category] = [...(statusPhrases[row.category] ?? []), row.phrase]
    }
  }
  const value = { statusPhrases, availabilityPhrases, menuSynonyms }
  customTriggerPhrasesCache.set(orgId, { value, expiresAt: Date.now() + CUSTOM_TRIGGER_PHRASES_CACHE_TTL_MS })
  return value
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

  // 2026-08-27 incident: every webhook shell's toNormalized() hands back
  // whatever raw phone format that provider's payload used (Wasi's wa_id,
  // Meta's `from` — both country-code-prefixed, e.g. "917806966124"), but
  // customers.mobile and every other phone value in this codebase is bare
  // 10-digit. The one place that raw value used to reach sendMessage
  // directly (line ~535 below: `to: identity?.found ? identity.phone :
  // msg.phone` — the fallback for an UNIDENTIFIED customer) fed straight
  // into sendViaWasi's `${INDIA_COUNTRY_CODE}${to}` prepend, double-
  // prefixing it ("917806966124" -> "91917806966124"). Wasi then couldn't
  // match that garbled number against the customer's own just-arrived
  // message and rejected the send as outside the 24h session window — a
  // real customer got silence, and the logged error pointed at the wrong
  // cause entirely. Normalizing once, here, in place, before ANY downstream
  // use (including handleSupplierReply's own sendMessage call, since it
  // receives this same object) fixes every call site at once rather than
  // patching each one individually. The wa_* RPCs below all normalize
  // p_phone internally too, so this is a no-op for them either way.
  msg.phone = _wa_normalizeInboundPhone(msg.phone)

  // Gap A — check supplier before the kill switch and before falling
  // through to the customer-only identify/conversation machinery below.
  // Supplier RFQ logging is independent of the customer-bot kill switch by
  // design (owner decision): it's a separate, always-on operational path,
  // not "the bot" the switch is meant to silence. A supplier reply is also
  // never a conversation (see handleSupplierReply's own comment for why it
  // never touches whatsapp_conversations), so this is a full early return,
  // not a branch inside the journey router.
  // supplier-identify and the settings/kill-switch read are independent of
  // each other's results (each only gates its OWN early return below) —
  // fired together instead of one-after-another to shave a network round
  // trip off every message's latency. The tiny bit of wasted work on the
  // rare "was actually a supplier" or "bot disabled" path is worth it for
  // the dominant "real customer, bot on" path this runs on every time.
  const [
    { data: supplierIdentity, error: supplierIdentifyError },
    { data: settingsRow, error: settingsError },
  ] = await Promise.all([
    admin.rpc("wa_identify_supplier", { p_org_id: orgId, p_phone: msg.phone }).abortSignal(AbortSignal.timeout(DB_CALL_TIMEOUT_MS)),
    admin
      .from("settings")
      .select("whatsapp_bot_enabled, wa_classify_intent_enabled, wa_answer_layer_enabled")
      .eq("org_id", orgId)
      .abortSignal(AbortSignal.timeout(DB_CALL_TIMEOUT_MS))
      .maybeSingle(),
  ])
  if (supplierIdentifyError) throw supplierIdentifyError
  if (supplierIdentity?.found) {
    await handleSupplierReply(admin, orgId, msg, { supplier_id: supplierIdentity.supplier_id as string, name: supplierIdentity.name as string })
    return
  }

  // Kill switch — everything from here down is "the bot" (customer
  // journeys). When off, it does not identify, route, or reply to a
  // customer; the caller still gets its 200 so it doesn't retry. Phase 4's
  // ops surface toggles this.
  if (settingsError) throw settingsError
  if (settingsRow && settingsRow.whatsapp_bot_enabled === false) return
  // 2026-08-28 owner decision — stop using AI entirely in the customer bot
  // pipeline, not just the Answer Layer (wa_answer_layer_enabled, checked
  // separately inside answerCustomerQuestion). Phase 5b's classifyWithClaude
  // (free-text -> menu journey) and checkFreeTextRelevance (item 3's
  // free-text-capture guard) are both Anthropic calls too — off by default
  // is `true` on the column, but explicitly false for every org today via
  // the migration that added it. Read once here, threaded to both call
  // sites below, rather than each re-reading settings independently.
  const classifyIntentEnabled = settingsRow?.wa_classify_intent_enabled !== false

  // identify_customer and get_conversation don't depend on each other's
  // result at all — fired together, same round-trip savings as the pair
  // above.
  const [
    { data: identity, error: identifyError },
    { data: conversation, error: convError },
  ] = await Promise.all([
    admin.rpc("wa_identify_customer", { p_org_id: orgId, p_phone: msg.phone }).abortSignal(AbortSignal.timeout(DB_CALL_TIMEOUT_MS)),
    admin.rpc("wa_get_conversation", { p_org_id: orgId, p_phone: msg.phone }).abortSignal(AbortSignal.timeout(DB_CALL_TIMEOUT_MS)),
  ])
  if (identifyError) throw identifyError
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
    productsWithoutAmc: identity?.found ? (identity.products_without_amc as Identity["productsWithoutAmc"]) : undefined,
    openTicket: identity?.found ? (identity.open_ticket as Identity["openTicket"]) : undefined,
    lastService: identity?.found ? (identity.last_service as Identity["lastService"]) : undefined,
  }
  const conversationState: ConversationState = { journey: conv.journey, step: conv.step, collected: conv.collected ?? {}, status: conv.status }

  // Mechanics (back/menu/cancel/talk-to-expert/language switch, plus the
  // step-timeout check) apply on EVERY step, not just while the generic
  // menu is showing — checked before any journey-specific router gets a
  // turn, so "back" typed mid-Service-booking doesn't get swallowed as a
  // literal answer to whatever question is currently being asked.
  const mechanicResult = tryHandleMechanic(lang, conversationState, isExpired, intent, identityForJourney.name ?? null)
  // 2026-08-28: checked BEFORE matchMenuSelection's own journey-entry
  // resolution (which happens inside routeInbound, in the final else
  // branch below) — "service status"/"what did i buy" both contain a
  // MENU_ITEM_IDS keyword ("service"/"buy") that would otherwise claim
  // them first and start a NEW booking / NEW purchase flow instead of
  // answering the status/history question actually asked. Same
  // "works regardless of current journey" universality as mechanics, so a
  // customer mid-way through booking a new service can still ask about an
  // existing ticket without it being misread as an answer to whatever
  // question the current step asked.
  // Phrase manager (2026-08-28) — one read, reused by both matchStatusTrigger
  // below and routeInbound's own matchMenuSelection call further down. Only
  // fetched when actually needed (not a mechanic, and there's real text to
  // match against — a menu tap never consults synonyms at all).
  const customPhrases = mechanicResult || intent.kind !== "text" ? null : await fetchCustomTriggerPhrases(admin, orgId)
  const statusTrigger = mechanicResult ? null : matchStatusTrigger(intent, customPhrases?.statusPhrases, customPhrases?.availabilityPhrases)
  const offTopicCaptureResult = mechanicResult || statusTrigger ? null : await checkOffTopicCapture(lang, conversationState, intent, classifyIntentEnabled)

  let result: RouteResult
  if (mechanicResult) {
    result = mechanicResult
  } else if (statusTrigger) {
    result = await answerStatusTrigger(admin, orgId, msg.phone, lang, conversationState, statusTrigger)
  } else if (offTopicCaptureResult) {
    result = offTopicCaptureResult
  } else if (conv.journey === "service") {
    result = await routeServiceTurn(admin, orgId, lang, conversationState, identityForJourney, intent)
  } else if (conv.journey === "sales") {
    result = routeSales(lang, conversationState, intent)
  } else if (conv.journey === "spares") {
    result = routeSpares(lang, conversationState, intent)
  } else if (conv.journey === "amc") {
    result = routeAmc(lang, conversationState, intent)
  } else {
    const classifiedIntent = classifyIntentEnabled ? await maybeClassifyIntent(conversationState, intent) : undefined
    result = routeInbound({
      lang,
      conversation: conversationState,
      customerName: identityForJourney.name ?? null,
      isExpired: false,
      intent,
      classifiedIntent,
      customMenuSynonyms: customPhrases?.menuSynonyms,
    })
  }

  // AI/CRM Answer Layer — only reached when routeInbound just landed on its
  // generic "sorry I didn't get that" fallback (menu showing, nothing a
  // keyword/tap/classification could resolve). Tries a real, grounded
  // answer before settling for that non-answer; conversation state and
  // menu are left completely untouched either way — this only ever
  // replaces reply.body, never routes anywhere. On any outcome other than
  // "answered" (handoff, no key configured, API/timeout error), today's
  // existing fallback reply computed above is left exactly as is — this
  // never introduces a new failure mode, only sometimes replaces a generic
  // non-answer with a real one.
  //
  // 2026-08-31 (latency): gated here on the settings row already fetched at
  // the top of this function, instead of always calling
  // answerCustomerQuestion and letting IT re-fetch the same settings row
  // and write a "disabled" audit log entry every single time a message
  // falls through to fallback while the switch is off (its own settled,
  // stable state per the zero-AI pivot — not an active rollout being
  // monitored). Two avoided round trips on every unmatched message; no
  // behavior change when the switch is actually on.
  if (settingsRow?.wa_answer_layer_enabled && result.isGenericFallback && intent.kind === "text") {
    const answerResult = await answerCustomerQuestion(admin, orgId, msg.phone, intent.text)
    if (answerResult.outcome === "answered") {
      result = { ...result, reply: { body: answerResult.answer } }
    } else if (answerResult.outcome === "handoff" && answerResult.toolUsed === "get_business_info") {
      // 2026-08-28: a customer asking for the address/phone is trying to
      // reach us, not asking something off-topic — distinct from the
      // generic decline below so the reply says so specifically, same
      // "reply 'expert'" shortcut whatsapp.amc.none already uses for its
      // own "don't have that, but here's a human" case.
      result = { ...result, reply: { body: t(lang, "whatsapp.mechanics.businessInfoUnavailable") } }
    } else if (answerResult.outcome === "handoff" && answerResult.toolUsed === "cannot_answer" && answerResult.category === "off_topic_chitchat") {
      // 2026-08-28: casual chit-chat ("saaptiya", "enna pandra") was
      // getting the same generic "can't help with that" decline as any
      // other unanswerable question — cannot_answer's model already
      // correctly recognized it as chit-chat (see its `reason` text), this
      // just acts on that instead of discarding it. Shows the real
      // tappable menu, not just "reply menu" text, since the goal here is
      // actively redirecting rather than just declining.
      const menu = buildMenuReply(lang)
      result = { ...result, reply: { body: `${t(lang, "whatsapp.mechanics.casualChitchat")}\n\n${menu.body}`, interactive: menu.interactive } }
    }
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
      result = await enterOrAnswerSalesJourney(admin, orgId, msg.phone, lang, intent)
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

  const saveStepPromise = admin
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
  // silent, unchanged. Independent of the state save above (neither reads
  // the other's result), so fired together instead of one-after-another.
  if (result.handoffReason === "expert_requested") {
    const customerLabel = identityForJourney.name ?? msg.phone
    const journeyLabel = result.nextState.journey ?? "main menu"
    const roles = handoffNotifyRoles(result.nextState.journey)
    const [, { error: notifyError }] = await Promise.all([
      saveStepPromise,
      admin.from("notifications").insert(
        roles.map((role) => ({
          org_id: orgId,
          role,
          type: "whatsapp_handoff",
          title: "Customer asked to talk to a person",
          body: `${customerLabel} (${msg.phone}) asked for a human on WhatsApp while in the "${journeyLabel}" flow. Reply from Automation > Conversations.`,
          ref_id: conv.id,
        }))
      ),
    ])
    if (notifyError) console.error("whatsapp-handle-message: failed to insert handoff notification", notifyError)
  } else {
    await saveStepPromise
  }
}
