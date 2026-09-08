// Deterministic, keyword-triggered, database-backed answers — 2026-08-28,
// built after wa_answer_layer_enabled AND wa_classify_intent_enabled were
// both turned off (owner decision: zero AI in the customer bot pipeline).
// Same real wa_get_* RPCs the AI Answer Layer used to call — the data path
// is unchanged and still always live/real; only the trigger mechanism
// (whole-phrase matching instead of an LLM picking a tool) and the reply
// generation (a fixed template instead of composed prose) are different.
//
// Checked in handleMessage BEFORE matchMenuSelection's own journey-entry
// resolution — "service status"/"what did i buy" both contain a
// MENU_ITEM_IDS keyword ("service"/"buy") that would otherwise claim them
// first and route into the wrong flow (a NEW booking / NEW purchase
// interest), not a status lookup. AMC/warranty status is NOT handled
// here — "amc"/"warranty" route through matchMenuSelection's own synonym
// list straight into the existing enterAmcJourney (whatsapp-journeys.ts),
// which already gives a real, deterministic per-product answer; building a
// second parallel template for the same data risked the two drifting out
// of sync. Pricing (category 5) isn't handled here either, per the
// 2026-08-28 decision to never disclose a real price — that stays the
// Sales entry point's deterministic "team will contact you" reply
// (enterOrAnswerSalesJourney, whatsapp-handle-message.ts).
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2"
import { containsWholePhrase, containsWholePhraseFuzzy, tokenizeWords, type ConversationState, type InboundIntent, type RouteResult } from "./whatsapp-journeys.ts"
import { t, type WaLang } from "./i18n.ts"

// product_availability carries WHICH category matched (it needs a search
// term for wa_get_product_price) — everything else is a plain category tag.
export type StatusTrigger =
  | { kind: "service_ticket" }
  | { kind: "purchase_history" }
  | { kind: "business_address" }
  | { kind: "business_phone" }
  | { kind: "business_hours" }
  | { kind: "emi" }
  | { kind: "product_availability"; category: string }

type SimpleStatusTrigger = Exclude<StatusTrigger["kind"], "product_availability">

// Recall limitation, deliberately accepted (documented for the owner at
// design time): whole-phrase matching only catches the exact phrasings
// listed here, not arbitrary rephrasing an LLM would have generalized
// from. Expand this list as real customer questions surface — same
// "you review real questions, tell me what needs a template" workflow
// already used for the rest of today's keyword coverage.
const SIMPLE_TRIGGER_PHRASES: Record<SimpleStatusTrigger, string[]> = {
  service_ticket: [
    "ticket status",
    "service status",
    "repair status",
    "status of my repair",
    "status of my ticket",
    "when will the technician come",
    "when is the technician coming",
    "is my ticket done",
    "has my complaint been resolved",
    "when will my ro be fixed",
    "ticket status enna",
    "technician eppo varuvanga",
    "repair aachaa",
    "service aachaa",
    "technician vandhachaa",
    "complaint solve aachaa",
    "ro eppo fix aagum",
  ],
  purchase_history: [
    "what did i buy",
    "what have i bought",
    "my purchases",
    "purchase history",
    "when did i buy",
    "my orders",
    "what products do i have",
    "my invoice",
    "naa enna vaangunen",
    "en purchase history",
    "eppo vaangunen",
    "en products enna",
    "invoice kudunga",
  ],
  business_address: ["address", "location", "where are you located", "how do i find you", "enga irukinga"],
  business_phone: ["phone number", "contact number", "how do i reach you", "your number"],
  business_hours: ["business hours", "when are you open", "are you open now", "timing", "eppo open irukinga"],
  // "emi" alone is distinctive enough (like "amc") to be a low false-
  // positive-risk single word — it's a specific finance term, not ordinary
  // conversational vocabulary.
  emi: ["emi", "installments", "installment", "installment options", "monthly payment", "monthly installment", "emi irukka"],
}

// 2026-08-28: "do you have [brand]" was flagged as a real, common question
// distinct from pricing — but pure phrase matching can't extract an
// arbitrary brand/product name the way an LLM could. Scoped instead to the
// same 4 categories wa_get_product_price ITSELF already falls back to
// (ro/ac/inverter/battery) when a name search finds nothing — a message
// needs BOTH a generic availability phrase AND one of these category words
// to match; "LG AC" isn't recognized as a specific brand today, only "AC"
// as a category. Deliberately narrower than the AI path was — expand to
// real brand-name matching later if this scope proves too narrow.
const AVAILABILITY_PHRASES = [
  "do you have",
  "in stock",
  "is available",
  "is it available",
  "do you sell",
  "stock available",
  "do you stock",
  "stock irukka",
  "available ah irukka",
]
const PRODUCT_CATEGORY_WORDS: Record<string, string[]> = {
  ro: ["ro", "ros"],
  ac: ["ac", "acs"],
  inverter: ["inverter", "inverters"],
  battery: ["battery", "batteries"],
}

function extractProductCategory(words: string[]): string | null {
  for (const [category, forms] of Object.entries(PRODUCT_CATEGORY_WORDS)) {
    if (forms.some((f) => words.includes(f))) return category
  }
  return null
}

/** customSimplePhrases/customAvailabilityPhrases (2026-08-28, phrase
 * manager) — staff-added extras merged with the hardcoded baseline;
 * fetched once in handleMessage and passed down so this stays a pure
 * function (no DB access here). Two-tier: exact match across baseline +
 * custom phrases for EVERY category first, THEN fuzzy across all of them
 * — never lets a fuzzy hit on one category pre-empt an exact hit on
 * another. Object key order is only a tie-break within one tier if a
 * message somehow matched two categories at once (not expected — the
 * phrase sets don't overlap). Safe to call unconditionally on every
 * inbound text message. */
export function matchStatusTrigger(
  intent: InboundIntent,
  customSimplePhrases?: Record<string, string[]>,
  customAvailabilityPhrases?: string[]
): StatusTrigger | null {
  if (intent.kind !== "text") return null
  const words = tokenizeWords(intent.text)

  const simplePhrasesFor = (trigger: SimpleStatusTrigger) => [...SIMPLE_TRIGGER_PHRASES[trigger], ...(customSimplePhrases?.[trigger] ?? [])]
  const availabilityPhrases = [...AVAILABILITY_PHRASES, ...(customAvailabilityPhrases ?? [])]

  for (const trigger of Object.keys(SIMPLE_TRIGGER_PHRASES) as SimpleStatusTrigger[]) {
    if (simplePhrasesFor(trigger).some((p) => containsWholePhrase(words, p))) return { kind: trigger }
  }
  if (availabilityPhrases.some((p) => containsWholePhrase(words, p))) {
    const category = extractProductCategory(words)
    if (category) return { kind: "product_availability", category }
  }

  for (const trigger of Object.keys(SIMPLE_TRIGGER_PHRASES) as SimpleStatusTrigger[]) {
    if (simplePhrasesFor(trigger).some((p) => containsWholePhraseFuzzy(words, p))) {
      console.error("whatsapp-status-answers: matchStatusTrigger resolved via FUZZY match", JSON.stringify(intent.text), "->", trigger)
      return { kind: trigger }
    }
  }
  if (availabilityPhrases.some((p) => containsWholePhraseFuzzy(words, p))) {
    const category = extractProductCategory(words)
    if (category) {
      console.error("whatsapp-status-answers: matchStatusTrigger resolved via FUZZY match", JSON.stringify(intent.text), "-> product_availability", category)
      return { kind: "product_availability", category }
    }
  }

  return null
}

function dateOnly(iso: string | null | undefined): string {
  return iso ? iso.slice(0, 10) : ""
}

// Same silent-handoff shape whatsapp-other-journeys.ts's own handoff()
// helper uses for a not-identified caller (status: "handed_off", no
// handoffReason — that field is reserved for the explicit "talk to a
// human" mechanic/menu row, not a bot-side failure like this one).
function handoff(lang: WaLang, conversation: ConversationState, key: string): RouteResult {
  return { nextState: { ...conversation, status: "handed_off" }, reply: { body: t(lang, key) } }
}

// A missing business-info FIELD is different from a not-identified
// customer — the conversation stays active (matches today's earlier
// businessInfoUnavailable decision), it's just one field we haven't
// filled in yet, not a reason to hand off to a human.
function stayActive(conversation: ConversationState, body: string): RouteResult {
  return { nextState: conversation, reply: { body } }
}

async function answerServiceTicketStatus(
  admin: SupabaseClient,
  orgId: string,
  phone: string,
  lang: WaLang,
  conversation: ConversationState
): Promise<RouteResult> {
  const { data, error } = await admin.rpc("wa_get_service_ticket_status", { p_org_id: orgId, p_phone: phone })
  if (error) {
    console.error("whatsapp-status-answers: wa_get_service_ticket_status failed", error)
    return handoff(lang, conversation, "whatsapp.statusAnswers.serviceTicket.notIdentified")
  }
  if (!data?.found) return handoff(lang, conversation, "whatsapp.statusAnswers.serviceTicket.notIdentified")

  const ticket = data.ticket
  if (!ticket) return stayActive(conversation, t(lang, "whatsapp.statusAnswers.serviceTicket.none"))

  const complaint = ticket.name_of_complaint || ticket.nature_of_complaint || ""
  if (!ticket.technician_name) {
    return stayActive(conversation, t(lang, "whatsapp.statusAnswers.serviceTicket.noTechnician", { complaint, status: ticket.status }))
  }

  const schedule =
    ticket.scheduled_at || ticket.slot_name
      ? t(lang, "whatsapp.statusAnswers.serviceTicket.scheduleSuffix", { date: dateOnly(ticket.scheduled_at), slotName: ticket.slot_name ?? "" })
      : ""
  const body = t(lang, "whatsapp.statusAnswers.serviceTicket.withTechnician", { complaint, status: ticket.status, technician: ticket.technician_name }) + schedule
  return stayActive(conversation, body)
}

async function answerPurchaseHistory(
  admin: SupabaseClient,
  orgId: string,
  phone: string,
  lang: WaLang,
  conversation: ConversationState
): Promise<RouteResult> {
  const { data, error } = await admin.rpc("wa_get_purchase_history", { p_org_id: orgId, p_phone: phone })
  if (error) {
    console.error("whatsapp-status-answers: wa_get_purchase_history failed", error)
    return handoff(lang, conversation, "whatsapp.statusAnswers.purchaseHistory.notIdentified")
  }
  if (!data?.found) return handoff(lang, conversation, "whatsapp.statusAnswers.purchaseHistory.notIdentified")

  const purchases = (data.purchases ?? []) as { product_name: string; price_paid: number; qty: number; purchase_date: string }[]
  if (purchases.length === 0) return stayActive(conversation, t(lang, "whatsapp.statusAnswers.purchaseHistory.none"))

  const lines = purchases
    .map((p) =>
      t(lang, "whatsapp.statusAnswers.purchaseHistory.line", { name: p.product_name, price: String(p.price_paid), qty: String(p.qty), date: dateOnly(p.purchase_date) })
    )
    .join("\n")
  const body = `${t(lang, "whatsapp.statusAnswers.purchaseHistory.header")}\n${lines}\n\n${t(lang, "whatsapp.statusAnswers.purchaseHistory.footer")}`
  return stayActive(conversation, body)
}

async function answerBusinessInfoField(
  admin: SupabaseClient,
  orgId: string,
  lang: WaLang,
  conversation: ConversationState,
  field: "address" | "phone" | "business_hours",
  keyPrefix: "businessAddress" | "businessPhone" | "businessHours"
): Promise<RouteResult> {
  const { data, error } = await admin.rpc("wa_get_business_info", { p_org_id: orgId })
  if (error) {
    console.error("whatsapp-status-answers: wa_get_business_info failed", error)
    return stayActive(conversation, t(lang, `whatsapp.statusAnswers.${keyPrefix}.unavailable`))
  }
  const value = data?.[field]
  if (!value) return stayActive(conversation, t(lang, `whatsapp.statusAnswers.${keyPrefix}.unavailable`))
  return stayActive(conversation, t(lang, `whatsapp.statusAnswers.${keyPrefix}.present`, { value }))
}

async function answerEmiInfo(admin: SupabaseClient, orgId: string, lang: WaLang, conversation: ConversationState): Promise<RouteResult> {
  const { data, error } = await admin.rpc("wa_get_emi_info", { p_org_id: orgId })
  if (error) {
    console.error("whatsapp-status-answers: wa_get_emi_info failed", error)
    return stayActive(conversation, t(lang, "whatsapp.statusAnswers.emi.unavailable"))
  }
  if (!data?.emi_enabled) return stayActive(conversation, t(lang, "whatsapp.statusAnswers.emi.unavailable"))

  const tenures = (data.emi_tenure_months ?? []) as number[]
  const tenureText = tenures.join(", ")
  const disclaimer = data.emi_disclaimer ? t(lang, "whatsapp.statusAnswers.emi.disclaimerSuffix", { disclaimer: data.emi_disclaimer }) : ""
  return stayActive(conversation, t(lang, "whatsapp.statusAnswers.emi.present", { tenures: tenureText }) + disclaimer)
}

async function answerProductAvailability(admin: SupabaseClient, orgId: string, lang: WaLang, conversation: ConversationState, category: string): Promise<RouteResult> {
  // wa_get_products_by_category (not wa_get_product_price) — deliberately:
  // 2026-08-28 live test found wa_get_product_price's name-substring-match
  // phase pulled "Amaron Current 150Ah Battery" into a "do you have RO in
  // stock" answer, since "Amaron" contains "ro" as a substring. This RPC
  // does ONLY an exact category match, no name substring phase, so that
  // class of collision can't happen. It also never SELECTs price at all —
  // not just "the template doesn't show it," the field isn't fetched.
  const { data, error } = await admin.rpc("wa_get_products_by_category", { p_org_id: orgId, p_category: category })
  if (error) {
    console.error("whatsapp-status-answers: wa_get_products_by_category failed", error)
    return stayActive(conversation, t(lang, "whatsapp.statusAnswers.productAvailability.none", { category }))
  }
  const results = (data ?? []) as { name: string }[]
  if (results.length === 0) return stayActive(conversation, t(lang, "whatsapp.statusAnswers.productAvailability.none", { category }))

  const names = results.map((r) => r.name).join(", ")
  return stayActive(conversation, t(lang, "whatsapp.statusAnswers.productAvailability.present", { names }))
}

export async function answerStatusTrigger(
  admin: SupabaseClient,
  orgId: string,
  phone: string,
  lang: WaLang,
  conversation: ConversationState,
  trigger: StatusTrigger
): Promise<RouteResult> {
  switch (trigger.kind) {
    case "service_ticket":
      return answerServiceTicketStatus(admin, orgId, phone, lang, conversation)
    case "purchase_history":
      return answerPurchaseHistory(admin, orgId, phone, lang, conversation)
    case "business_address":
      return answerBusinessInfoField(admin, orgId, lang, conversation, "address", "businessAddress")
    case "business_phone":
      return answerBusinessInfoField(admin, orgId, lang, conversation, "phone", "businessPhone")
    case "business_hours":
      return answerBusinessInfoField(admin, orgId, lang, conversation, "business_hours", "businessHours")
    case "emi":
      return answerEmiInfo(admin, orgId, lang, conversation)
    case "product_availability":
      return answerProductAvailability(admin, orgId, lang, conversation, trigger.category)
  }
}
