// Supplier RFQ automation — free-text price extraction from a supplier's
// WhatsApp reply, WITHOUT any AI/ML call (owner decision, 2026-09-01:
// pure logic/regex only, on top of the earlier 2026-08-28 zero-AI decision
// that already disabled the Anthropic-based extractor this replaces —
// see whatsapp-extract-quote.ts, kept in the repo for reference but no
// longer called from handleSupplierReply).
//
// Same conservative contract as the extractor it replaces: any ambiguity
// (no candidate, multiple conflicting candidates, an out-of-range number)
// returns ok:false rather than guessing. The caller treats every ok:false
// the same way it always has — notify an admin to log the reply manually
// via Purchase > Quotes.
//
// Rules (all run, most-specific first if more than one would apply):
//   1. Labeled — "price: 4500", "rate - Rs 4500", "cost 4500"
//   2. Currency-prefixed — "₹4500", "Rs 4500", "INR 4500" anywhere in the text
//   3. Currency-suffixed — "4500rs", "480/-" (at least as common as prefixed
//      in terse supplier replies)
//   4. Bare number — the ENTIRE trimmed message is just a number ("4500")
// If more than one rule matches with different values, or none match, or
// the matched value falls outside a sane price range, this is ambiguous —
// ok:false. Lead time ("2-3 days", "in 5 days") is parsed the same way: a
// best-effort match, never a source of ambiguity on its own.

export type QuoteExtractionResult =
  | { ok: true; price: number; leadTimeDays: number | null; confidence: number; latencyMs: number }
  | { ok: false; reason: "low_confidence" | "no_price_found" | "api_error" | "timeout"; latencyMs: number }

const MIN_PRICE = 1
const MAX_PRICE = 10_000_000

const CURRENCY_TOKENS = "₹|rs\\.?|inr"
const CURRENCY = `(?:${CURRENCY_TOKENS})`
// Must start with a digit — "[\d,]+" alone can match a lone stray comma
// (e.g. the ", " right after "4500rs, 2-3 days") and silently produce a
// bogus candidate of 0. Requiring a leading digit closes that off.
const NUM = "(\\d[\\d,]*(?:\\.\\d{1,2})?)"

const LABELED_RE = new RegExp(`(?:price|rate|cost|quote|amount)\\s*[:\\-]?\\s*${CURRENCY}?\\s*${NUM}`, "i")
const CURRENCY_PREFIXED_RE = new RegExp(`${CURRENCY}\\s*${NUM}`, "i")
// Suffix form — "4500rs", "480/-" — at least as common as prefix in terse supplier replies.
const CURRENCY_SUFFIXED_RE = new RegExp(`${NUM}\\s*(?:${CURRENCY_TOKENS}|/-)`, "i")
const BARE_NUMBER_RE = new RegExp(`^${NUM}$`)
const LEAD_TIME_RE = /(\d+)\s*(?:-\s*\d+\s*)?days?/i

function parseNumber(raw: string): number | null {
  const n = Number(raw.replace(/,/g, ""))
  return Number.isFinite(n) ? n : null
}

function inRange(n: number): boolean {
  return n >= MIN_PRICE && n <= MAX_PRICE
}

/** Synchronous, but kept async + latencyMs in the result shape to be a
 * drop-in replacement for the AI extractor's call site (handleSupplierReply
 * awaits it and logs latencyMs today) without touching that call site's
 * surrounding structure beyond swapping the import. */
export async function extractQuoteDeterministic(text: string): Promise<QuoteExtractionResult> {
  const start = performance.now()
  const trimmed = text.trim()

  const labeled = trimmed.match(LABELED_RE)
  const currencyPrefixed = trimmed.match(CURRENCY_PREFIXED_RE)
  const currencySuffixed = trimmed.match(CURRENCY_SUFFIXED_RE)
  const bare = trimmed.match(BARE_NUMBER_RE)

  const candidates = new Set<number>()
  for (const m of [labeled, currencyPrefixed, currencySuffixed, bare]) {
    if (!m) continue
    const n = parseNumber(m[1])
    if (n != null) candidates.add(n)
  }

  const latencyMs = Math.round(performance.now() - start)

  if (candidates.size === 0) {
    return { ok: false, reason: "no_price_found", latencyMs }
  }
  if (candidates.size > 1) {
    // Different rules disagreed on the price — don't pick one, flag for review.
    return { ok: false, reason: "low_confidence", latencyMs }
  }

  const price = [...candidates][0]
  if (!inRange(price)) {
    return { ok: false, reason: "low_confidence", latencyMs }
  }

  const leadMatch = trimmed.match(LEAD_TIME_RE)
  const leadTimeDays = leadMatch ? Number(leadMatch[1]) : null

  // "confidence" is kept for parity with the AI result shape (logged in the
  // ack note) — 1 for an unambiguous labeled/currency match, slightly lower
  // for a bare-number reply since that's more likely to be a typo/wrong number.
  const confidence = labeled || currencyPrefixed || currencySuffixed ? 1 : 0.8

  return { ok: true, price, leadTimeDays, confidence, latencyMs }
}
