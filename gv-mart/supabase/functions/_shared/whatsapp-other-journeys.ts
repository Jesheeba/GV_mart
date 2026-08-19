// Phase 2b Step 3 — Sales, Spares (write via wa_create_lead / wa_create_
// spare_enquiry), AMC & My Account (read-only, straight from the identity
// wa_identify_customer already resolved — no new query, no new business
// logic). Same pure-function/`action`-request shape as the Service journey.
import { t, type WaLang } from "./i18n.ts"
import type { ConversationState, InboundIntent, Reply, RouteResult } from "./whatsapp-journeys.ts"
import type { Identity } from "./whatsapp-service-journey.ts"

function handoff(lang: WaLang, key: string): RouteResult {
  return { nextState: { journey: null, step: null, collected: {}, status: "handed_off" }, reply: { body: t(lang, key) } }
}

// ── Sales ───────────────────────────────────────────────────────────────
// wa_create_lead works even for an unidentified phone (_whatsapp_lead_upsert
// creates a customer-less lead keyed by mobile) — a sales enquiry from a
// prospect who isn't a customer yet is the normal case, not an edge case.
export function enterSalesJourney(lang: WaLang): RouteResult {
  return {
    nextState: { journey: "sales", step: "ask_interest", collected: {}, status: "active" },
    reply: { body: t(lang, "whatsapp.sales.askInterest") },
  }
}

export function routeSales(lang: WaLang, conversation: ConversationState, intent: InboundIntent): RouteResult {
  const text = intent.kind === "text" ? intent.text.trim() : null
  if (conversation.step === "ask_interest") {
    if (!text) return { nextState: conversation, reply: { body: t(lang, "whatsapp.sales.askInterest") } }
    return {
      nextState: { journey: null, step: null, collected: {}, status: "completed" },
      reply: { body: t(lang, "whatsapp.sales.confirmed") },
      action: { type: "create_lead", params: { body: text } },
    }
  }
  return enterSalesJourney(lang)
}

// ── Spares ──────────────────────────────────────────────────────────────
export function enterSparesJourney(lang: WaLang, identity: Identity): RouteResult {
  if (!identity.found) return handoff(lang, "whatsapp.spares.notIdentified")
  return {
    nextState: { journey: "spares", step: "ask_spare", collected: {}, status: "active" },
    reply: { body: t(lang, "whatsapp.spares.askSpare") },
  }
}

export function routeSpares(lang: WaLang, conversation: ConversationState, intent: InboundIntent): RouteResult {
  const text = intent.kind === "text" ? intent.text.trim() : null
  if (conversation.step === "ask_spare") {
    if (!text) return { nextState: conversation, reply: { body: t(lang, "whatsapp.spares.askSpare") } }
    return {
      nextState: { journey: null, step: null, collected: {}, status: "completed" },
      reply: { body: t(lang, "whatsapp.spares.confirmed") },
      action: { type: "create_spare_enquiry", params: { description: text } },
    }
  }
  return { nextState: conversation, reply: { body: t(lang, "whatsapp.spares.askSpare") } }
}

// ── AMC (read-only — no action, no write) ──────────────────────────────
export function enterAmcJourney(lang: WaLang, identity: Identity): RouteResult {
  if (!identity.found) return handoff(lang, "whatsapp.amc.notIdentified")
  const amcProducts = (identity.products ?? []).filter((p) => p.coverage === "amc")
  const lines = amcProducts.map((p) =>
    t(lang, "whatsapp.amc.productLine", {
      name: p.product_name,
      status: p.amc_status ?? "",
      expiry: p.expiry_date ? t(lang, "whatsapp.amc.expirySuffix", { date: p.expiry_date }) : "",
    })
  )
  const body = amcProducts.length === 0
    ? t(lang, "whatsapp.amc.none")
    : `${t(lang, "whatsapp.amc.header")}\n${lines.join("\n")}\n\n${t(lang, "whatsapp.amc.footer")}`
  return { nextState: { journey: null, step: null, collected: {}, status: "completed" }, reply: { body } }
}

// ── My Account (read-only — no action, no write) ────────────────────────
export function enterAccountJourney(lang: WaLang, identity: Identity): RouteResult {
  if (!identity.found) return handoff(lang, "whatsapp.account.notIdentified")

  const products = identity.products ?? []
  const productLines = products.length
    ? products
        .map((p) =>
          t(lang, "whatsapp.account.productLine", {
            name: p.product_name,
            coverage: p.coverage ?? "-",
            expiry: p.expiry_date ? t(lang, "whatsapp.account.expirySuffix", { date: p.expiry_date }) : "",
          })
        )
        .join("\n")
    : t(lang, "whatsapp.account.noProducts")

  const ticketLine = identity.openTicket
    ? t(lang, "whatsapp.account.openTicket", { complaint: identity.openTicket.name_of_complaint, status: identity.openTicket.status ?? "" })
    : t(lang, "whatsapp.account.noOpenTicket")

  const lastServiceLine = identity.lastService
    ? t(lang, "whatsapp.account.lastService", { complaint: identity.lastService.name_of_complaint })
    : t(lang, "whatsapp.account.noLastService")

  const body = [
    t(lang, "whatsapp.account.header"),
    "",
    t(lang, "whatsapp.account.productsHeader"),
    productLines,
    "",
    ticketLine,
    lastServiceLine,
    "",
    t(lang, "whatsapp.account.footer"),
  ].join("\n")

  return { nextState: { journey: null, step: null, collected: {}, status: "completed" }, reply: { body } }
}
