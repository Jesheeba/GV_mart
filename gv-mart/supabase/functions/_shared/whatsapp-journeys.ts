// Phase 2b Step 1 — conversation mechanics + main menu. The state machine
// itself: routeInbound() is a pure function (no DB/network calls) so it can
// be reasoned about and tested independent of the webhook plumbing around
// it. Journey-specific step logic (Service in Step 2, Sales/Spares/AMC/
// Account in Step 3) plugs into the `journey === "..."` branch below —
// the mechanics (menu/back/cancel/handoff/timeout) never change per journey.
import { t, type WaLang } from "./i18n.ts"
import type { Intent as ClassifiedIntentKind } from "./whatsapp-classify-intent.ts"

export type MenuItemId = "buy" | "service" | "spares" | "amc" | "account" | "expert"
const MENU_ITEM_IDS: MenuItemId[] = ["buy", "service", "spares", "amc", "account", "expert"]

/** What Phase 5b's classifier hands back to routeInbound — network call
 * already happened in handleMessage (the impure shell); routeInbound stays
 * pure and just decides what to do with the result. */
export type ClassifiedIntent = { intent: ClassifiedIntentKind; confidence: number }

// Only "clear enough to skip the menu" classifications map to a journey —
// "support"/"unclear" have no menu row of their own and fall through to the
// same generic fallback as today (this is Phase 5b: route on a confident
// classification; Phase "answer layer" is what later replaces that fallback).
const INTENT_TO_MENU_ITEM: Partial<Record<ClassifiedIntentKind, MenuItemId>> = {
  sales: "buy",
  service: "service",
  spare: "spares",
  amc: "amc",
}
const CLASSIFY_CONFIDENCE_THRESHOLD = 0.6

// 2026-08-28: script-agnostic word tokenizer, shared by matchMenuSelection
// and detectMechanic below (both used to match via plain `.includes()`,
// which false-positives on a target word appearing as a fragment of a
// longer one — "buyer"/"backup"/"accountant" all matched "buy"/"back"/
// "account"). Deliberately NOT a regex `\b...\b`: JS's `\b` is ASCII-word-
// character-based and doesn't recognize Tamil script as "word" characters,
// so a Tamil keyword flanked by other Tamil characters can silently fail
// to match at all under a naive boundary regex. Splitting on whitespace/
// punctuation and checking exact token (or token-sequence) equality works
// correctly for both English and Tamil — same technique isBareGreeting
// already uses. */
export function tokenizeWords(text: string): string[] {
  return text
    .trim()
    .toLowerCase()
    .replace(/[!.,?~]+/g, " ")
    .split(/\s+/)
    .filter(Boolean)
}

/** phrase may be one word ("back") or several ("main menu") — matches only
 * when that exact sequence of whole words appears contiguously, never as a
 * fragment inside a different word. */
export function containsWholePhrase(words: string[], phrase: string): boolean {
  const phraseWords = tokenizeWords(phrase)
  if (phraseWords.length === 0) return false
  for (let i = 0; i <= words.length - phraseWords.length; i++) {
    if (phraseWords.every((pw, j) => words[i + j] === pw)) return true
  }
  return false
}

// 2026-08-28: fuzzy/typo tolerance (spec section 5.4), scoped identically
// to the phrase-manager itself — status-answer categories + menu synonyms
// only, NEVER mechanics/greetings/red-flag phrases (containsWholePhrase
// above stays exact-only for those, deliberately untouched). A SEPARATE
// function, not a flag on containsWholePhrase, so callers can't get this
// by accident.
//
// Plain Levenshtein edit distance, length-gated: words of length <=3 are
// exact-match only — a 1-edit typo on a short word is too likely to BE a
// different real word ("ro"->"to", "ac"->"an") rather than a typo of the
// target. Longer words get 1 edit (2 for 8+ chars). Even with that gate,
// manually checking every fuzzy-eligible term against plausible unrelated
// real words at design time found two genuine collisions this heuristic
// alone doesn't catch: "expert"<->"expect" and "parts"<->"pants" (both
// distance 1, both common unrelated English words) — both hard-excluded
// below rather than relying on the length gate. This is a heuristic, not
// a guarantee — a residual false-positive-fuzzy-match risk still exists
// for less common words (e.g. "service"<->"servile"); every fuzzy (i.e.
// non-exact) match is logged so real hits can be spot-checked over time,
// same "review real evidence" discipline as the rest of this system.
const FUZZY_MATCH_EXCLUDED_WORDS = new Set(["expert", "parts"])

function levenshteinDistance(a: string, b: string): number {
  const m = a.length
  const n = b.length
  if (m === 0) return n
  if (n === 0) return m
  const prev = new Array(n + 1)
  const curr = new Array(n + 1)
  for (let j = 0; j <= n; j++) prev[j] = j
  for (let i = 1; i <= m; i++) {
    curr[0] = i
    for (let j = 1; j <= n; j++) {
      curr[j] = a[i - 1] === b[j - 1] ? prev[j - 1] : 1 + Math.min(prev[j - 1], prev[j], curr[j - 1])
    }
    for (let j = 0; j <= n; j++) prev[j] = curr[j]
  }
  return prev[n]
}

function fuzzyWordEquals(a: string, b: string): boolean {
  if (a === b) return true
  if (a.length <= 3 || b.length <= 3) return false
  if (FUZZY_MATCH_EXCLUDED_WORDS.has(a) || FUZZY_MATCH_EXCLUDED_WORDS.has(b)) return false
  const maxLen = Math.max(a.length, b.length)
  const allowedDistance = maxLen >= 8 ? 2 : 1
  return levenshteinDistance(a, b) <= allowedDistance
}

/** Same shape as containsWholePhrase, but each word may fuzzy-match rather
 * than require an exact hit — multi-word phrases are inherently much safer
 * to fuzz than a single word (an accidental collision needs every word in
 * the phrase to simultaneously land near an unrelated real word, in the
 * same message). Callers should try containsWholePhrase FIRST and only
 * fall back to this when the exact pass found nothing — a two-tier check,
 * not a replacement, so a clean exact match is never second-guessed by a
 * fuzzy one. Returns whether a fuzzy (non-exact) match was actually used,
 * so callers can log it for review. */
export function containsWholePhraseFuzzy(words: string[], phrase: string): boolean {
  const phraseWords = tokenizeWords(phrase)
  if (phraseWords.length === 0) return false
  for (let i = 0; i <= words.length - phraseWords.length; i++) {
    if (phraseWords.every((pw, j) => fuzzyWordEquals(words[i + j], pw))) return true
  }
  return false
}

// 2026-08-28 incident: a customer asked the bot to "send me the gpay number
// i have 10lakhs i want to send you" — the Answer Layer correctly declined
// (see wa_answer_layer_log), but with AI now off, the ONLY remaining
// resolution path is keyword matching, which has no concept of "this looks
// like a payment-solicitation attempt" at all. This is a floor, not a
// replacement for what the AI checks provided — a keyword list catches
// obvious phrasing, not a rephrased attempt. Used by matchMenuSelection
// below (suppresses a keyword match entirely) and by handleMessage's
// free-text capture guard (whatsapp-handle-message.ts) — one canonical
// check, two call sites.
const PAYMENT_RED_FLAG_PHRASES = [
  "gpay",
  "g-pay",
  "google pay",
  "phonepe",
  "phone pe",
  "paytm",
  "upi",
  "ifsc",
  "bank account",
  "account number",
  "a/c no",
  "acc no",
  "send money",
  "transfer money",
  "wire transfer",
  "bitcoin",
  "crypto",
  "otp",
  "credit card",
  "debit card",
  "cvv",
  "netbanking",
]

export function containsPaymentRedFlag(text: string): boolean {
  const normalized = text.toLowerCase()
  if (PAYMENT_RED_FLAG_PHRASES.some((p) => normalized.includes(p))) return true
  if (/\b\d{6,}\b/.test(text)) return true // a long digit run (account/phone number) has no business in a spare-part/problem description
  return false
}

// 2026-08-28: "warranty" added as a synonym for "amc" — every category-1
// status-answer trigger phrase reviewed ("amc status", "amc expiry", "when
// does my amc expire") already contains the whole word "amc" and so
// already routes here unchanged; the only gap was a phrasing that means
// AMC/warranty coverage without ever saying "amc" ("warranty status", "am
// I still covered"). Reuses enterAmcJourney's existing real, deterministic
// per-product reply as-is rather than building a second, parallel template
// that could drift out of sync with it.
const MENU_ITEM_SYNONYMS: Record<MenuItemId, string[]> = {
  buy: ["buy"],
  service: ["service"],
  spares: ["spares", "parts"],
  amc: ["amc", "warranty"],
  account: ["account"],
  expert: ["expert"],
}

/** Does this inbound message resolve to a menu row without any AI call —
 * a tapped list row, or typed text containing a menu item's id (e.g.
 * "service")? Exported so handleMessage can check this FIRST and only pay
 * for a classify-intent call when it's actually needed. A payment red flag
 * suppresses this entirely — the 2026-08-28 incident's "...to thag
 * account" false-matched "account" (My GV Mart Account) purely because
 * that word happened to also appear in an unrelated, suspicious sentence;
 * whole-word matching alone wouldn't have caught that (it's a genuine
 * standalone word, not a substring fragment), so this closes it directly:
 * a red-flagged message never resolves to any menu item, whole-word or not.
 *
 * customSynonyms (2026-08-28, phrase manager) — staff-added extras per
 * MenuItemId, merged with the hardcoded baseline; passed down from
 * handleMessage's own DB read so this function stays pure (no DB access
 * here). Checked exact-first across ALL synonyms (baseline + custom), THEN
 * fuzzy across all of them if nothing matched exactly — never lets a fuzzy
 * hit on one item pre-empt an exact hit on another. */
export function matchMenuSelection(intent: InboundIntent, customSynonyms?: Partial<Record<MenuItemId, string[]>>): MenuItemId | undefined {
  if (intent.kind === "list_reply") return intent.id.replace(/^menu_/, "") as MenuItemId
  if (containsPaymentRedFlag(intent.text)) return undefined
  const words = tokenizeWords(intent.text)

  const synonymsFor = (id: MenuItemId) => [...MENU_ITEM_SYNONYMS[id], ...(customSynonyms?.[id] ?? [])]

  const exact = MENU_ITEM_IDS.find((id) => synonymsFor(id).some((syn) => words.includes(syn)))
  if (exact) return exact

  const fuzzy = MENU_ITEM_IDS.find((id) => synonymsFor(id).some((syn) => containsWholePhraseFuzzy(words, syn)))
  if (fuzzy) console.error("whatsapp-journeys: matchMenuSelection resolved via FUZZY match", JSON.stringify(intent.text), "->", fuzzy)
  return fuzzy
}

function matchClassifiedIntent(classified: ClassifiedIntent | undefined): MenuItemId | undefined {
  if (!classified || classified.confidence < CLASSIFY_CONFIDENCE_THRESHOLD) return undefined
  return INTENT_TO_MENU_ITEM[classified.intent]
}

export type ConversationState = {
  journey: string | null
  step: string | null
  collected: Record<string, unknown>
  status: "active" | "completed" | "expired" | "handed_off"
}

// Wasi's own flat outbound shape (production-confirmed by Wasi support,
// 2026-08-27) — NOT Meta's native nested interactive object this used to
// mirror. `buttons` and `button`+`sections` are mutually exclusive per
// Wasi's contract (sending both is a 400); `body` stays on Reply itself,
// reused for both the human-readable outbox log and the "body" field sent
// to Wasi. Constraints (enforced where these are built, not here):
// buttons max 1-3 (id <=256 bytes, title <=20 chars), list max 10 rows
// total across sections (row id <=200 bytes, title <=24 chars, description
// <=72 chars), header/footer optional <=60 chars.
export type Reply = {
  body: string
  interactive?:
    | { header?: string; footer?: string; buttons: { id: string; title: string }[] }
    | { header?: string; footer?: string; button: string; sections: { title?: string; rows: { id: string; title: string; description?: string }[] }[] }
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
  /** Set only when this handoff is the customer explicitly asking for a
   * human (the "expert" mechanic keyword, or the menu's "Talk to an Expert"
   * row) — NOT the several other places a journey hands off after a bot-side
   * failure (unidentified caller, booking failed, action failed, etc). The
   * webhook uses this to decide whether to alert staff; those other
   * handoffs stay silent as before. */
  handoffReason?: "expert_requested"
  /** Set when this turn's outcome is already being communicated to the
   * customer through some other channel (a DB milestone trigger writing
   * its own whatsapp_outbox row), so the webhook's own trailing
   * sendMessage() at the end of handleMessage should NOT also send
   * `reply`. `reply.body` is still populated with sensible text (not
   * left blank) as a fallback in case a future caller forgets to check
   * this flag. */
  suppressReply?: boolean
  /** Set ONLY at the one "menu showing, nothing matched" fallback return
   * below — lets handleMessage try the AI/CRM Answer Layer before settling
   * for this generic non-answer, without the impure shell having to
   * pattern-match on reply.body text to detect the same case. */
  isGenericFallback?: boolean
}

const MECHANIC_KEYWORDS: Record<"menu" | "cancel" | "back" | "expert" | "lang_ta" | "lang_en", string[]> = {
  menu: ["menu", "main menu", "மெனு", "முதன்மை மெனு"],
  cancel: ["cancel", "start over", "ரத்து", "மீண்டும் தொடங்கு"],
  back: ["back", "பின்", "பின்செல்"],
  expert: ["agent", "human", "talk to expert", "talk to team", "நிபுணர்", "ஆள்"],
  lang_ta: ["tamil", "தமிழ்"],
  lang_en: ["english", "ஆங்கிலம்"],
}

// 2026-08-28: same substring-fragment fragility as matchMenuSelection had
// ("backup" matching "back", "call the agentcy" matching "agent") — fixed
// the same way, via containsWholePhrase/tokenizeWords above, so a keyword
// only fires when it appears as whole word(s), not a fragment of a longer one.
const BACK_KEYWORDS_LOWER = MECHANIC_KEYWORDS.back.map((k) => k.toLowerCase())

function detectMechanic(text: string): keyof typeof MECHANIC_KEYWORDS | null {
  const words = tokenizeWords(text)

  // "back" is a common ordinary word ("back panel", "call me back") as well
  // as a navigation command — unlike the other mechanic keywords, matching
  // it as a whole word ANYWHERE in the message still false-positives on
  // real free-text content (a Spares/Service capture step answer). Require
  // the WHOLE message to be just "back" (or its Tamil equivalents), same
  // "entire message, not a fragment of it" discipline isBareGreeting
  // already uses for greetings, rather than containsWholePhrase's
  // appears-anywhere matching every other mechanic keyword still uses.
  if (words.length === 1 && BACK_KEYWORDS_LOWER.includes(words[0])) return "back"

  for (const [mechanic, keywords] of Object.entries(MECHANIC_KEYWORDS)) {
    if (mechanic === "back") continue
    if (keywords.some((kw) => containsWholePhrase(words, kw))) {
      return mechanic as keyof typeof MECHANIC_KEYWORDS
    }
  }
  return null
}

// 2026-08-27: a bare "hi"/"hello"/"vanakkam" was hitting classifyWithClaude
// and then the Answer Layer, burning two Anthropic round-trips just to land
// on "cannot_answer, greeting, no question" and a generic non-answer — while
// a real question ("how much is the Kent Grand Plus RO") sent as literally
// the first message got the OPPOSITE problem, silently swallowed by
// routeInbound's unconditional fresh-contact greeting (see that branch's own
// comment). Two different bugs, same underlying cause: neither path checked
// "is this actually just a greeting" before deciding what to do with it.
// Deliberately NOT reusing detectMechanic's substring `.includes()` matching
// here — "hi" as a substring false-positives on real words ("which", "this"),
// so this checks the WHOLE trimmed/punctuation-stripped message is made of
// nothing but greeting words, never a fragment of a longer one.
const GREETING_WORDS = new Set(["hi", "hii", "hiii", "hello", "helo", "hlo", "hey", "heyy", "yo", "hai", "vanakkam", "vanakam", "வணக்கம்"])

function isBareGreeting(text: string): boolean {
  const normalized = text.trim().toLowerCase().replace(/[!.,?~]+/g, " ").trim()
  if (!normalized) return false
  const words = normalized.split(/\s+/)
  return words.length <= 3 && words.every((w) => GREETING_WORDS.has(w))
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
      header: t(lang, "whatsapp.menu.header"),
      footer: t(lang, "whatsapp.menu.footer"),
      button: t(lang, "whatsapp.menu.buttonText"),
      sections: [{ rows }],
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
 * the same way a mechanic does.
 *
 * customerName is used ONLY by the bare-greeting case below, to give a
 * genuinely fresh contact the same personalized welcome routeInbound's own
 * greetingReply gives it — everything else here is name-independent. */
export function tryHandleMechanic(lang: WaLang, conversation: ConversationState, isExpired: boolean, intent: InboundIntent, customerName: string | null): RouteResult | null {
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

  // Deliberately its own block, not folded into the "menu" branch above —
  // that branch's existing fresh-contact behavior (plain menu, no prefix)
  // is a separate, already-reviewed decision this isn't meant to touch.
  // Only fires when nothing else matched (mechanic === null), so a message
  // like "hi menu" still resolves via the ordinary "menu" keyword above.
  if (mechanic === null && text !== null && isBareGreeting(text)) {
    const menu = buildMenuReply(lang)
    const isFreshContact = conversation.journey === null && conversation.step === null
    const body = isFreshContact
      ? `${customerName ? t(lang, "whatsapp.greeting.known", { name: customerName }) : t(lang, "whatsapp.greeting.unknown")}\n\n${menu.body}`
      : `${t(lang, "whatsapp.mechanics.returnedToMenu")}\n\n${menu.body}`
    return {
      nextState: { journey: null, step: "menu_shown", collected: conversation.collected, status: "active" },
      reply: { body, interactive: menu.interactive },
    }
  }

  if (mechanic === "expert") {
    return {
      nextState: { ...conversation, status: "handed_off" },
      reply: { body: t(lang, "whatsapp.mechanics.handoff") },
      handoffReason: "expert_requested",
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
  /** Phase 5b — set only when handleMessage decided a classify-intent call
   * was worth making (menu showing, free text, no direct keyword match).
   * Undefined whenever matchMenuSelection() already resolved a row, or the
   * classifier wasn't confident/reachable — routing behaves exactly as
   * before 5b in either case. */
  classifiedIntent?: ClassifiedIntent
  /** Phrase-manager custom synonyms (2026-08-28), keyed by MenuItemId — see matchMenuSelection's own doc comment. */
  customMenuSynonyms?: Partial<Record<MenuItemId, string[]>>
}): RouteResult {
  const { conversation, customerName, isExpired, lang } = input

  const mechanicResult = tryHandleMechanic(lang, conversation, isExpired, input.intent, customerName)
  if (mechanicResult) return mechanicResult

  // Fresh conversation, first message ever. 2026-08-27: this used to greet +
  // menu regardless of content, which silently swallowed a real first
  // message ("how much is the Kent Grand Plus RO") into a canned welcome.
  // Bare greetings are already fully handled above by tryHandleMechanic, so
  // anything reaching here is real content — give it the same resolution
  // chance the menu_shown branch below gives it (tapped row / typed keyword
  // / confident classification) before falling back to the warm welcome.
  if (conversation.journey === null && conversation.step === null) {
    const selectedId = matchMenuSelection(input.intent, input.customMenuSynonyms) ?? matchClassifiedIntent(input.classifiedIntent)

    if (selectedId && MENU_ITEM_IDS.includes(selectedId)) {
      if (selectedId === "expert") {
        return {
          nextState: { ...conversation, status: "handed_off" },
          reply: { body: t(lang, "whatsapp.mechanics.handoff") },
          handoffReason: "expert_requested",
        }
      }
      return {
        nextState: { journey: selectedId, step: "intro", collected: conversation.collected, status: "active" },
        reply: journeyIntroReply(lang, selectedId),
      }
    }

    // Nothing resolved — still the same warm welcome as before, but now
    // marked isGenericFallback so the Answer Layer gets a shot at real,
    // unclassifiable content first; only replaces this text on a genuine
    // answer, so a truly fresh/unclear first message looks exactly as it
    // did before this change.
    return {
      nextState: { journey: null, step: "menu_shown", collected: conversation.collected, status: "active" },
      reply: greetingReply(lang, customerName),
      isGenericFallback: true,
    }
  }

  // Menu is showing — resolve a tapped list row or a typed item name to a
  // journey; if neither matched, fall back to a confident Phase 5b
  // classification (handleMessage only supplies one when this branch would
  // otherwise be reached, so no ordering surprise here).
  if (conversation.journey === null && conversation.step === "menu_shown") {
    const selectedId = matchMenuSelection(input.intent, input.customMenuSynonyms) ?? matchClassifiedIntent(input.classifiedIntent)

    if (selectedId && MENU_ITEM_IDS.includes(selectedId)) {
      if (selectedId === "expert") {
        return {
          nextState: { ...conversation, status: "handed_off" },
          reply: { body: t(lang, "whatsapp.mechanics.handoff") },
          handoffReason: "expert_requested",
        }
      }
      return {
        nextState: { journey: selectedId, step: "intro", collected: conversation.collected, status: "active" },
        reply: journeyIntroReply(lang, selectedId),
      }
    }

    return { nextState: conversation, reply: { body: t(lang, "whatsapp.mechanics.fallback") }, isGenericFallback: true }
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
