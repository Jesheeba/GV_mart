// Supplier RFQ automation (Gap B) — free-text price/lead-time extraction
// from a supplier's WhatsApp reply. Deliberately separate from
// whatsapp-classify-intent.ts: that module's only job is sorting a message
// into one of 6 fixed buckets ({intent, confidence}); this one pulls a
// structured {price, lead_time_days} out of unpredictable free text ("500",
// "Rs 500 per unit", "480/-, can deliver in 3 days", Tanglish variants) — a
// different kind of problem, not a bigger version of the same one.
//
// Never guesses: any failure (low confidence, no price found, API error,
// timeout) returns ok:false. The caller (handleSupplierReply in
// whatsapp-handle-message.ts) treats every ok:false the same way — notify
// an admin to log the reply manually via the pre-existing
// log_purchase_quote_reply path (Purchase > Quotes) — per the owner's
// explicit instruction not to let a wrong parse silently pick a supplier.
export const EXTRACT_TIMEOUT_MS = 8_000
export const EXTRACT_MODEL = "claude-haiku-4-5-20251001"
const MIN_CONFIDENCE = 0.6

export type QuoteExtractionResult =
  | { ok: true; price: number; leadTimeDays: number | null; confidence: number; latencyMs: number }
  | { ok: false; reason: "low_confidence" | "no_price_found" | "api_error" | "timeout"; latencyMs: number }

const SYSTEM_PROMPT = `A supplier to a water-purifier/AC/inverter/battery sales-and-service business in Chennai, India was asked over WhatsApp to quote a price for a spare part or product. This is their reply. Extract the price they quoted, in Indian Rupees, and the delivery/lead time in days if they mentioned one.

Replies are often terse and inconsistent: "500", "Rs 500 per unit", "480/-, can deliver in 3 days", "500rs, 2-3 days", or Tanglish (Tamil-English code-mixed, sometimes in Tamil script). Assume any bare number is a price in rupees unless it's clearly something else (a quantity, a phone number, a date). If the supplier gives a range instead of a single price ("450-480", "around 450 to 480"), they have not committed to one number — set found to false rather than picking either end of the range. If no lead time is mentioned, leave it null - do not guess a default.

If the message does not contain a usable price at all (a question, a greeting, an unrelated reply, or genuinely too ambiguous to tell which number is the price), set found to false. Confidence is your genuine belief the extracted price is what the supplier meant - be conservative: a wrong extracted price could route a real purchase order to the wrong number, so prefer found:false or low confidence over a guess.`

export async function extractQuote(text: string, apiKey: string): Promise<QuoteExtractionResult> {
  const start = performance.now()
  try {
    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-api-key": apiKey, "anthropic-version": "2023-06-01" },
      signal: AbortSignal.timeout(EXTRACT_TIMEOUT_MS),
      body: JSON.stringify({
        model: EXTRACT_MODEL,
        max_tokens: 300,
        system: SYSTEM_PROMPT,
        messages: [{ role: "user", content: text }],
        tools: [
          {
            name: "extract_quote",
            description: "Report the extracted price quote for this supplier reply.",
            input_schema: {
              type: "object",
              properties: {
                found: { type: "boolean", description: "true if a usable price was found in the message" },
                price: { type: "number", description: "Quoted price in INR. 0 if not found." },
                lead_time_days: { type: ["number", "null"], description: "Delivery time in days, or null if not mentioned." },
                confidence: { type: "number", description: "0 to 1 - genuine belief the extracted price is what the supplier meant." },
              },
              required: ["found", "price", "lead_time_days", "confidence"],
            },
          },
        ],
        tool_choice: { type: "tool", name: "extract_quote" },
      }),
    })

    const latencyMs = Math.round(performance.now() - start)

    if (!res.ok) {
      const errText = await res.text().catch(() => "")
      console.error("whatsapp-extract-quote: Anthropic API error", res.status, errText)
      return { ok: false, reason: "api_error", latencyMs }
    }

    const data = await res.json()
    const toolUse = data.content?.find((block: { type: string }) => block.type === "tool_use")
    if (!toolUse?.input) {
      return { ok: false, reason: "api_error", latencyMs }
    }

    const input = toolUse.input as { found?: boolean; price?: number; lead_time_days?: number | null; confidence?: number }
    const confidence = typeof input.confidence === "number" ? Math.max(0, Math.min(1, input.confidence)) : 0

    if (!input.found || typeof input.price !== "number" || input.price <= 0) {
      return { ok: false, reason: "no_price_found", latencyMs }
    }
    if (confidence < MIN_CONFIDENCE) {
      return { ok: false, reason: "low_confidence", latencyMs }
    }

    return {
      ok: true,
      price: input.price,
      leadTimeDays: typeof input.lead_time_days === "number" ? input.lead_time_days : null,
      confidence,
      latencyMs,
    }
  } catch (e) {
    const latencyMs = Math.round(performance.now() - start)
    const isTimeout = e instanceof Error && e.name === "TimeoutError"
    console.error("whatsapp-extract-quote: request failed", isTimeout ? "timeout" : e)
    return { ok: false, reason: isTimeout ? "timeout" : "api_error", latencyMs }
  }
}
