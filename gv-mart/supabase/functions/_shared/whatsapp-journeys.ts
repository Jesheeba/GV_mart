// Phase 2b Step 1 — conversation mechanics + main menu. The state machine
// itself: routeInbound() is a pure function (no DB/network calls) so it can
// be reasoned about and tested independent of the webhook plumbing around
// it. Journey-specific step logic (Service in Step 2, Sales/Spares/AMC/
// Account in Step 3) plugs into the `journey === "..."` branch below —
// the mechanics (menu/back/cancel/handoff/timeout) never change per journey.
import { t, type WaLang } from "./i18n.ts"

export type MenuItemId = "buy" | "service" | "spares" | "amc" | "account" | "expert"
const MENU_ITEM_IDS: MenuItemId[] = ["buy", "service", "spares", "amc", "account", "expert"]

export type ConversationState = {
  journey: string | null
  step: string | null
  collected: Record<string, unknown>
  status: "active" | "completed" | "expired" | "handed_off"
}

export type Reply = {
  body: string
  interactive?: {
    type: "list"
    header?: { type: "text"; text: string }
    body: { text: string }
    footer?: { text: string }
    action: { button: string; sections: { rows: { id: string; title: string; description?: string }[] }[] }
  }
}

export type InboundIntent =
  | { kind: "list_reply"; id: string }
  | { kind: "text"; text: string }

/** `action` is how a pure journey module (e.g. whatsapp-service-journey.ts)
 * asks the impure webhook shell to perform a write and come back with the
 * real outcome — the journey module decides WHEN and with WHAT params, the
 * webhook performs it via the matching wa_* wrapper. Typed loosely here
 * (not imported from a journey module) so this file never depends on any
 * specific journey — Step 3 adds more action `type`s without this file
 * changing. */
export type RouteResult = {
  nextState: ConversationState
  reply: Reply
  /** true when this turn should also write a customer_id onto the conversation row (identity resolved but not yet linked). */
  linkCustomerId?: boolean
  action?: { type: string; params: Record<string, unknown> }
}

const MECHANIC_KEYWORDS: Record<"menu" | "cancel" | "back" | "expert" | "lang_ta" | "lang_en", string[]> = {
  menu: ["menu", "main menu", "மெனு", "முதன்மை மெனு"],
  cancel: ["cancel", "start over", "ரத்து", "மீண்டும் தொடங்கு"],
  back: ["back", "பின்", "பின்செல்"],
  expert: ["agent", "human", "talk to expert", "talk to team", "நிபுணர்", "ஆள்"],
  lang_ta: ["tamil", "தமிழ்"],
  lang_en: ["english", "ஆங்கிலம்"],
}

function detectMechanic(text: string): keyof typeof MECHANIC_KEYWORDS | null {
  const normalized = text.trim().toLowerCase()
  for (const [mechanic, keywords] of Object.entries(MECHANIC_KEYWORDS)) {
    if (keywords.some((kw) => normalized === kw.toLowerCase() || normalized.includes(kw.toLowerCase()))) {
      return mechanic as keyof typeof MECHANIC_KEYWORDS
    }
  }
  return null
}

export function buildMenuReply(lang: WaLang): Reply {
  const rows = MENU_ITEM_IDS.map((id) => ({
    id: `menu_${id}`,
    title: t(lang, `whatsapp.menu.items.${id}.title`),
    description: t(lang, `whatsapp.menu.items.${id}.description`),
  }))
  return {
    body: `${t(lang, "whatsapp.menu.body")}\n${rows.map((r) => `- ${r.title}`).join("\n")}`,
    interactive: {
      type: "list",
      header: { type: "text", text: t(lang, "whatsapp.menu.header") },
      body: { text: t(lang, "whatsapp.menu.body") },
      footer: { text: t(lang, "whatsapp.menu.footer") },
      action: { button: t(lang, "whatsapp.menu.buttonText"), sections: [{ rows }] },
    },
  }
}

function greetingReply(lang: WaLang, customerName: string | null): Reply {
  const greeting = customerName ? t(lang, "whatsapp.greeting.known", { name: customerName }) : t(lang, "whatsapp.greeting.unknown")
  const menu = buildMenuReply(lang)
  return { body: `${greeting}\n\n${menu.body}`, interactive: menu.interactive }
}

/** Journey placeholder intros — Step 2 replaces "service" with the real multi-step flow, Step 3 replaces the rest. The mechanics (back/menu/cancel) around them don't change when that happens. */
function journeyIntroReply(lang: WaLang, journey: MenuItemId): Reply {
  const title = t(lang, `whatsapp.menu.items.${journey}.title`)
  return { body: `${title}\n${t(lang, "whatsapp.mechanics.journeyComingSoon")}` }
}

/** Checked BEFORE dispatching to any journey-specific router (Service,
 * Sales, Spares — not just here) — "back"/"menu"/"cancel"/"talk to an
 * expert"/a language switch must work on every step, per the plan's own
 * requirement, not just while the generic menu is showing. Returns null
 * when nothing matched, so the caller falls through to whatever handles
 * this conversation's current step. Also handles the step-timeout case,
 * since an expired session should short-circuit before journey dispatch
 * the same way a mechanic does. */
export function tryHandleMechanic(lang: WaLang, conversation: ConversationState, isExpired: boolean, intent: InboundIntent): RouteResult | null {
  if (isExpired && conversation.status === "active") {
    const menu = buildMenuReply(lang)
    return {
      nextState: { journey: null, step: "menu_shown", collected: conversation.collected, status: "active" },
      reply: { body: `${t(lang, "whatsapp.mechanics.timeout")}\n\n${menu.body}`, interactive: menu.interactive },
    }
  }

  const text = intent.kind === "text" ? intent.text : null
  const mechanic = text ? detectMechanic(text) : null

  if (mechanic === "lang_ta" || mechanic === "lang_en") {
    const newLang = mechanic === "lang_ta" ? "ta" : "en"
    const menu = buildMenuReply(newLang)
    return {
      nextState: { ...conversation, journey: null, step: "menu_shown", collected: { ...conversation.collected, lang: newLang } },
      reply: menu,
    }
  }

  if (mechanic === "cancel") {
    const menu = buildMenuReply(lang)
    return {
      nextState: { journey: null, step: "menu_shown", collected: conversation.collected, status: "active" },
      reply: { body: `${t(lang, "whatsapp.mechanics.cancelled")}\n\n${menu.body}`, interactive: menu.interactive },
    }
  }

  if (mechanic === "menu") {
    const menu = buildMenuReply(lang)
    // First contact (journey/step both null) gets the plain menu, not "returned to" phrasing.
    const prefix = conversation.journey === null && conversation.step === null ? "" : `${t(lang, "whatsapp.mechanics.returnedToMenu")}\n\n`
    return {
      nextState: { journey: null, step: "menu_shown", collected: conversation.collected, status: "active" },
      reply: { body: `${prefix}${menu.body}`, interactive: menu.interactive },
    }
  }

  if (mechanic === "expert") {
    return {
      nextState: { ...conversation, status: "handed_off" },
      reply: { body: t(lang, "whatsapp.mechanics.handoff") },
    }
  }

  if (mechanic === "back") {
    // Every journey is one placeholder step deep right now (Step 1) — "back"
    // from a journey's first step always lands on the main menu. Once
    // Step 2/3 add real multi-step journeys, this branch gains a per-journey
    // "previous step" table instead of this blanket rule.
    if (conversation.journey === null) {
      return {
        nextState: { journey: null, step: "menu_shown", collected: conversation.collected, status: "active" },
        reply: { body: t(lang, "whatsapp.mechanics.backNotAvailable") },
      }
    }
    const menu = buildMenuReply(lang)
    return {
      nextState: { journey: null, step: "menu_shown", collected: conversation.collected, status: "active" },
      reply: { body: `${t(lang, "whatsapp.mechanics.returnedToMenu")}\n\n${menu.body}`, interactive: menu.interactive },
    }
  }

  return null
}

export function routeInbound(input: {
  lang: WaLang
  conversation: ConversationState
  customerName: string | null
  isExpired: boolean
  intent: InboundIntent
}): RouteResult {
  const { conversation, customerName, isExpired, lang } = input

  const mechanicResult = tryHandleMechanic(lang, conversation, isExpired, input.intent)
  if (mechanicResult) return mechanicResult

  // Fresh conversation, first message ever — greet + menu, regardless of content.
  if (conversation.journey === null && conversation.step === null) {
    return {
      nextState: { journey: null, step: "menu_shown", collected: conversation.collected, status: "active" },
      reply: greetingReply(lang, customerName),
    }
  }

  // Menu is showing — resolve a tapped list row or a typed item name to a journey.
  if (conversation.journey === null && conversation.step === "menu_shown") {
    const inboundText = input.intent.kind === "text" ? input.intent.text : null
    const selectedId =
      input.intent.kind === "list_reply"
        ? (input.intent.id.replace(/^menu_/, "") as MenuItemId)
        : MENU_ITEM_IDS.find((id) => inboundText?.toLowerCase().includes(id))

    if (selectedId && MENU_ITEM_IDS.includes(selectedId)) {
      if (selectedId === "expert") {
        return { nextState: { ...conversation, status: "handed_off" }, reply: { body: t(lang, "whatsapp.mechanics.handoff") } }
      }
      return {
        nextState: { journey: selectedId, step: "intro", collected: conversation.collected, status: "active" },
        reply: journeyIntroReply(lang, selectedId),
      }
    }

    return { nextState: conversation, reply: { body: t(lang, "whatsapp.mechanics.fallback") } }
  }

  // Inside a journey's placeholder step (Step 1) — anything not caught by
  // the mechanics above just re-shows this journey's intro.
  if (conversation.journey && MENU_ITEM_IDS.includes(conversation.journey as MenuItemId)) {
    return { nextState: conversation, reply: journeyIntroReply(lang, conversation.journey as MenuItemId) }
  }

  // Unknown state shape — fail safe to the menu rather than getting stuck.
  const menu = buildMenuReply(lang)
  return { nextState: { journey: null, step: "menu_shown", collected: conversation.collected, status: "active" }, reply: menu }
}
