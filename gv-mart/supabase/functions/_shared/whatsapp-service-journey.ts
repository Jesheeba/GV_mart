// Phase 2b Step 2 — Service journey: problem -> urgency -> slot -> address
// confirm -> ticket. No capacity/model question (looked up via
// wa_identify_customer's product list, per the plan). Pure function, same
// shape/reasoning as routeInbound in whatsapp-journeys.ts: this module
// decides WHAT to do, including when a write is needed, but never performs
// the write itself — it returns an `action` the caller (whatsapp-webhook)
// executes via wa_create_service_ticket (the phone-ownership-checked
// wrapper from Phase 2a), then re-enters this module to render the result.
// No business logic lives here beyond conversation flow: type detection,
// SLA, and assignment all still happen inside _create_complaint_ticket_
// internal, unchanged.
import { t, type WaLang } from "./i18n.ts"
import type { ConversationState, InboundIntent, Reply, RouteResult } from "./whatsapp-journeys.ts"

export type IdentifiedProduct = { product_id: string; product_name: string; coverage?: "amc" | "warranty"; amc_status?: string; expiry_date?: string }
export type IdentifiedTicketSummary = { id: string; name_of_complaint: string; status?: string }
export type Identity = {
  found: boolean
  customerId?: string
  name?: string
  products?: IdentifiedProduct[]
  /** Purchased products with NO amc_contracts row for this customer (warranty-only
   * still counts as "not in an AMC") — used to build the AMC "add a plan?" offer. */
  productsWithoutAmc?: { product_id: string; product_name: string }[]
  openTicket?: IdentifiedTicketSummary | null
  lastService?: IdentifiedTicketSummary | null
}
export type AddressInfo = { id: string; summary: string }
export type SlotInfo = { id: string; name: string; start_time: string; end_time: string }

export type CreateServiceTicketParams = {
  productId: string | null
  unlistedProductName: string | null
  nameOfComplaint: string
  priority: "normal" | "urgent" | "very_urgent"
  scheduledDate: string
  slotId: string
}

// Same shape as whatsapp-journeys.ts's RouteResult — reused, not
// redeclared, so a value can flow through either module's return path
// without a type mismatch at the call site in whatsapp-webhook/index.ts.
export type ServiceRouteResult = RouteResult

function daysFromNow(n: number): string {
  return new Date(Date.now() + n * 86_400_000).toISOString().slice(0, 10)
}
function dayLabel(lang: WaLang, n: number): string {
  return n === 0 ? t(lang, "common.today") : n === 1 ? "Tomorrow" : daysFromNow(n)
}

function slotListReply(lang: WaLang, slots: SlotInfo[]): { reply: Reply; options: { id: string; date: string; slotId: string; slotName: string }[] } {
  const options: { id: string; date: string; slotId: string; slotName: string }[] = []
  for (let day = 1; day <= 2 && options.length < 10; day++) {
    for (const slot of slots) {
      if (options.length >= 10) break
      options.push({ id: `slot_${options.length}`, date: daysFromNow(day), slotId: slot.id, slotName: slot.name })
    }
  }
  const rows = options.map((o, i) => ({ id: o.id, title: `${dayLabel(lang, i < slots.length ? 1 : 2)} — ${o.slotName}` }))
  return {
    reply: {
      body: `${t(lang, "whatsapp.service.askSlot.body")}\n${rows.map((r) => `- ${r.title}`).join("\n")}`,
      interactive: {
        header: t(lang, "whatsapp.service.askSlot.header"),
        button: t(lang, "whatsapp.menu.buttonText"),
        sections: [{ rows }],
      },
    },
    options,
  }
}

function productListReply(lang: WaLang, products: IdentifiedProduct[]): Reply {
  // Wasi's 10-row total cap (across all sections) — products is a
  // customer's real product list with no upper bound of its own, so this
  // wasn't safe even under Meta's identical 10-row limit; just never
  // exercised until real dispatch existed to hit it. Cap to 9 so the
  // always-appended "other" row still fits within 10.
  const rows = products.slice(0, 9).map((p) => ({ id: `product_${p.product_id}`, title: p.product_name }))
  rows.push({ id: "product_other", title: t(lang, "whatsapp.service.unlistedProductPrompt").slice(0, 24) })
  return {
    body: `${t(lang, "whatsapp.service.askProduct.body")}\n${rows.map((r) => `- ${r.title}`).join("\n")}`,
    interactive: {
      header: t(lang, "whatsapp.service.askProduct.header"),
      button: t(lang, "whatsapp.menu.buttonText"),
      sections: [{ rows }],
    },
  }
}

function urgencyReply(lang: WaLang): Reply {
  const rows = [
    { id: "urgency_normal", title: t(lang, "whatsapp.service.askUrgency.normal") },
    { id: "urgency_urgent", title: t(lang, "whatsapp.service.askUrgency.urgent") },
    { id: "urgency_very_urgent", title: t(lang, "whatsapp.service.askUrgency.veryUrgent") },
  ]
  return {
    body: `${t(lang, "whatsapp.service.askUrgency.body")}\n${rows.map((r) => `- ${r.title}`).join("\n")}`,
    interactive: {
      header: t(lang, "whatsapp.service.askUrgency.header"),
      button: t(lang, "whatsapp.menu.buttonText"),
      sections: [{ rows }],
    },
  }
}

function addressConfirmReply(lang: WaLang, address: AddressInfo): Reply {
  const rows = [
    { id: "address_confirm_yes", title: t(lang, "whatsapp.service.askAddressConfirm.yes") },
    { id: "address_confirm_no", title: t(lang, "whatsapp.service.askAddressConfirm.no") },
  ]
  const body = t(lang, "whatsapp.service.askAddressConfirm.body", { address: address.summary })
  return {
    body: `${body}\n${rows.map((r) => `- ${r.title}`).join("\n")}`,
    interactive: { button: t(lang, "whatsapp.menu.buttonText"), sections: [{ rows }] },
  }
}

function handoff(lang: WaLang, key: string): ServiceRouteResult {
  return {
    nextState: { journey: "service", step: null, collected: {}, status: "handed_off" },
    reply: { body: t(lang, key) },
  }
}

/** Called when "Book Service" is first selected from the menu. */
export function enterServiceJourney(lang: WaLang, identity: Identity, address: AddressInfo | null, slots: SlotInfo[]): ServiceRouteResult {
  if (!identity.found) return handoff(lang, "whatsapp.service.notIdentified")
  if (!address) return handoff(lang, "whatsapp.service.noAddress")
  if (slots.length === 0) return handoff(lang, "whatsapp.service.askSlot.noSlotsHandoff")

  const products = identity.products ?? []
  if (products.length >= 2) {
    return {
      nextState: { journey: "service", step: "ask_product", collected: { productOptions: products }, status: "active" },
      reply: productListReply(lang, products),
    }
  }
  const collected = products.length === 1 ? { productId: products[0].product_id, productName: products[0].product_name } : {}
  return {
    nextState: { journey: "service", step: "ask_problem", collected, status: "active" },
    reply: { body: t(lang, "whatsapp.service.askProblem") },
  }
}

export function routeService(input: {
  lang: WaLang
  conversation: ConversationState
  identity: Identity
  address: AddressInfo | null
  slots: SlotInfo[]
  intent: InboundIntent
}): ServiceRouteResult {
  const { lang, conversation, intent } = input
  const collected = conversation.collected ?? {}
  const text = intent.kind === "text" ? intent.text.trim() : null
  const listId = intent.kind === "list_reply" ? intent.id : null

  switch (conversation.step) {
    case "ask_product": {
      if (!listId) return { nextState: conversation, reply: { body: t(lang, "whatsapp.service.askProduct.body") } }
      if (listId === "product_other") {
        return {
          nextState: { journey: "service", step: "ask_unlisted_product", collected, status: "active" },
          reply: { body: t(lang, "whatsapp.service.unlistedProductPrompt") },
        }
      }
      const productId = listId.replace(/^product_/, "")
      const options = (collected.productOptions as IdentifiedProduct[] | undefined) ?? []
      const matched = options.find((p) => p.product_id === productId)
      return {
        nextState: {
          journey: "service",
          step: "ask_problem",
          collected: { productId: matched?.product_id ?? productId, productName: matched?.product_name ?? null },
          status: "active",
        },
        reply: { body: t(lang, "whatsapp.service.askProblem") },
      }
    }

    case "ask_unlisted_product": {
      if (!text) return { nextState: conversation, reply: { body: t(lang, "whatsapp.service.unlistedProductPrompt") } }
      return {
        nextState: { journey: "service", step: "ask_problem", collected: { ...collected, unlistedProductName: text }, status: "active" },
        reply: { body: t(lang, "whatsapp.service.askProblem") },
      }
    }

    case "ask_problem": {
      if (!text) return { nextState: conversation, reply: { body: t(lang, "whatsapp.service.askProblem") } }
      return {
        nextState: { journey: "service", step: "ask_urgency", collected: { ...collected, problemText: text }, status: "active" },
        reply: urgencyReply(lang),
      }
    }

    case "ask_urgency": {
      const priority = listId === "urgency_normal" ? "normal" : listId === "urgency_urgent" ? "urgent" : listId === "urgency_very_urgent" ? "very_urgent" : null
      if (!priority) return { nextState: conversation, reply: urgencyReply(lang) }
      const { reply, options } = slotListReply(lang, input.slots)
      return {
        nextState: { journey: "service", step: "ask_slot", collected: { ...collected, priority, slotOptions: options }, status: "active" },
        reply,
      }
    }

    case "ask_slot": {
      const options = (collected.slotOptions as { id: string; date: string; slotId: string; slotName: string }[] | undefined) ?? []
      const matched = options.find((o) => o.id === listId)
      if (!matched) {
        const { reply } = slotListReply(lang, input.slots)
        return { nextState: conversation, reply }
      }
      if (!input.address) return handoff(lang, "whatsapp.service.noAddress")
      return {
        nextState: {
          journey: "service",
          step: "ask_address_confirm",
          collected: { ...collected, scheduledDate: matched.date, slotId: matched.slotId, slotName: matched.slotName },
          status: "active",
        },
        reply: addressConfirmReply(lang, input.address),
      }
    }

    case "ask_address_confirm": {
      if (listId === "address_confirm_no") return handoff(lang, "whatsapp.service.differentAddressHandoff")
      if (listId !== "address_confirm_yes") {
        if (!input.address) return handoff(lang, "whatsapp.service.noAddress")
        return { nextState: conversation, reply: addressConfirmReply(lang, input.address) }
      }
      return {
        nextState: conversation, // real next state decided after the action runs
        reply: { body: "…" },
        action: {
          type: "create_service_ticket",
          params: {
            productId: (collected.productId as string | undefined) ?? null,
            unlistedProductName: (collected.unlistedProductName as string | undefined) ?? null,
            nameOfComplaint: (collected.problemText as string | undefined) ?? "Reported via WhatsApp",
            priority: (collected.priority as "normal" | "urgent" | "very_urgent" | undefined) ?? "normal",
            scheduledDate: collected.scheduledDate as string,
            slotId: collected.slotId as string,
          },
        },
      }
    }

    default:
      // Shouldn't happen (step should always be one of the above once
      // inside the service journey) — fail safe by restarting the journey.
      return enterServiceJourney(lang, input.identity, input.address, input.slots)
  }
}
