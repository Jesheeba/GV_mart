// Extracted from wa-classify-intent/index.ts (Phase 5a) so handleMessage
// (Phase 5b) can call the classifier directly in-process instead of an
// edge-function-to-edge-function HTTP hop — same reasoning as why
// whatsapp-handle-message.ts itself lives in _shared. wa-classify-intent
// keeps its own standalone HTTP entry point (thin wrapper around this
// module) so it's still independently testable, per the plan's decision
// to review a classifier's output before anything routes on it.
//
// "The LLM classifies, deterministic code routes": this module's only job
// is {intent, confidence}. It never decides what happens next.
//
// Bounded-latency by design: Meta retries a webhook that responds slowly,
// and a classifier hanging in that synchronous path is exactly how you get
// duplicate processing. Every path through classifyWithClaude returns
// within ANTHROPIC_TIMEOUT_MS or less — a slow/erroring LLM call degrades
// to {intent:"unclear", confidence:0, fallback:true} rather than hanging
// or throwing.
export const ANTHROPIC_TIMEOUT_MS = 8_000
export const CLASSIFY_MODEL = "claude-haiku-4-5-20251001"

export const INTENTS = ["sales", "service", "spare", "amc", "support", "unclear"] as const
export type Intent = (typeof INTENTS)[number]

export type ClassifyResult = {
  intent: Intent
  confidence: number
  reasoning: string
  latencyMs: number
  fallback: boolean
  rawStopReason?: string
}

const SYSTEM_PROMPT = `You classify a single inbound WhatsApp message to a water-purifier/AC/inverter/battery sales-and-service business in Chennai, India. Messages are often Tanglish (Tamil-English code-mixed, sometimes in Tamil script, sometimes transliterated).

Classify into exactly one of: sales, service, spare, amc, support, unclear.
- sales: wants to buy or upgrade a product
- service: has a problem with an existing product, wants a repair/technician visit
- spare: wants to buy a specific part/accessory, not a full repair visit
- amc: asking about an AMC (annual maintenance contract) — status, renewal, benefits
- support: a general question, complaint, or something needing a human that doesn't fit the above
- unclear: you cannot confidently tell, OR the message is a greeting/too short/ambiguous between two categories

Be conservative. If the message could plausibly be two different categories, or is too short/vague to tell, prefer "unclear" with low confidence over guessing. A wrong confident classification routes a customer to the wrong flow — an "unclear" one safely falls back to a menu. Confidence is your genuine belief the classification is correct, not a fixed value: use the full 0-1 range.`

export async function classifyWithClaude(text: string, apiKey: string): Promise<ClassifyResult> {
  const start = performance.now()
  try {
    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-api-key": apiKey, "anthropic-version": "2023-06-01" },
      signal: AbortSignal.timeout(ANTHROPIC_TIMEOUT_MS),
      body: JSON.stringify({
        model: CLASSIFY_MODEL,
        max_tokens: 300,
        system: SYSTEM_PROMPT,
        messages: [{ role: "user", content: text }],
        tools: [
          {
            name: "classify_intent",
            description: "Report the classified intent for this message.",
            input_schema: {
              type: "object",
              properties: {
                intent: { type: "string", enum: INTENTS },
                confidence: { type: "number", description: "0 to 1" },
                reasoning: { type: "string", description: "One short sentence." },
              },
              required: ["intent", "confidence", "reasoning"],
            },
          },
        ],
        tool_choice: { type: "tool", name: "classify_intent" },
      }),
    })

    const latencyMs = Math.round(performance.now() - start)

    if (!res.ok) {
      const errText = await res.text().catch(() => "")
      console.error("whatsapp-classify-intent: Anthropic API error", res.status, errText)
      return { intent: "unclear", confidence: 0, reasoning: `api_error_${res.status}`, latencyMs, fallback: true }
    }

    const data = await res.json()
    const toolUse = data.content?.find((block: { type: string }) => block.type === "tool_use")
    if (!toolUse?.input) {
      return { intent: "unclear", confidence: 0, reasoning: "no_tool_use_in_response", latencyMs, fallback: true, rawStopReason: data.stop_reason }
    }

    const input = toolUse.input as { intent?: string; confidence?: number; reasoning?: string }
    const intent = INTENTS.includes(input.intent as Intent) ? (input.intent as Intent) : "unclear"
    const confidence = typeof input.confidence === "number" ? Math.max(0, Math.min(1, input.confidence)) : 0

    return { intent, confidence, reasoning: input.reasoning ?? "", latencyMs, fallback: false, rawStopReason: data.stop_reason }
  } catch (e) {
    const latencyMs = Math.round(performance.now() - start)
    const isTimeout = e instanceof Error && e.name === "TimeoutError"
    console.error("whatsapp-classify-intent: request failed", isTimeout ? "timeout" : e)
    return { intent: "unclear", confidence: 0, reasoning: isTimeout ? "timeout" : "request_failed", latencyMs, fallback: true }
  }
}

// 2026-08-28 — a separate, narrower classifier from classifyWithClaude
// above: that one answers "which menu category" from a cold start (its
// prompt is calibrated for that), this one answers "is this free text a
// genuine attempt to answer THE SPECIFIC QUESTION we just asked" at one of
// routeSales/routeSpares/routeService's free-text capture steps
// (ask_interest, ask_spare, ask_unlisted_product, ask_problem) — those used
// to accept ANY non-empty text verbatim as a real lead/enquiry/ticket
// field. Deliberately fails OPEN (relevant: true) on every error path —
// this is a new guardrail added on top of existing behavior; an infra
// hiccup here must never block a real customer's legitimate answer.
export type FreeTextRelevanceResult = { relevant: boolean; latencyMs: number; fallback: boolean }

const RELEVANCE_SYSTEM_PROMPT = `You check whether a customer's WhatsApp reply is a genuine,
on-topic attempt to answer a specific question a water-purifier/AC/inverter/battery
sales-and-service business in Chennai, India just asked them — not whether it's complete,
well-worded, or grammatically correct, just whether they're actually trying to answer THIS
question rather than chit-chatting, joking, or saying something unrelated. Messages may be
in English, Tamil, or Tanglish (Tamil-English code-mixed).

Be generous: a short, vague, or oddly-phrased answer still counts as relevant if it's a real
attempt to answer. Only mark irrelevant when the text is clearly NOT trying to answer at
all — casual chit-chat ("saaptiya" / did you eat), a greeting, a joke, or a plainly unrelated
topic ("food") when asked what spare part or problem they have.`

export async function checkFreeTextRelevance(question: string, text: string, apiKey: string): Promise<FreeTextRelevanceResult> {
  const start = performance.now()
  try {
    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-api-key": apiKey, "anthropic-version": "2023-06-01" },
      signal: AbortSignal.timeout(ANTHROPIC_TIMEOUT_MS),
      body: JSON.stringify({
        model: CLASSIFY_MODEL,
        max_tokens: 200,
        system: RELEVANCE_SYSTEM_PROMPT,
        messages: [{ role: "user", content: `The business just asked the customer: "${question}"\n\nThe customer replied: "${text}"` }],
        tools: [
          {
            name: "assess_relevance",
            description: "Report whether the reply is a genuine attempt to answer the question asked.",
            input_schema: { type: "object", properties: { relevant: { type: "boolean" } }, required: ["relevant"] },
          },
        ],
        tool_choice: { type: "tool", name: "assess_relevance" },
      }),
    })

    const latencyMs = Math.round(performance.now() - start)

    if (!res.ok) {
      const errText = await res.text().catch(() => "")
      console.error("whatsapp-classify-intent: relevance check API error", res.status, errText)
      return { relevant: true, latencyMs, fallback: true }
    }

    const data = await res.json()
    const toolUse = data.content?.find((block: { type: string }) => block.type === "tool_use")
    if (!toolUse?.input || typeof toolUse.input.relevant !== "boolean") {
      return { relevant: true, latencyMs, fallback: true }
    }

    return { relevant: toolUse.input.relevant, latencyMs, fallback: false }
  } catch (e) {
    const latencyMs = Math.round(performance.now() - start)
    const isTimeout = e instanceof Error && e.name === "TimeoutError"
    console.error("whatsapp-classify-intent: relevance check request failed", isTimeout ? "timeout" : e)
    return { relevant: true, latencyMs, fallback: true }
  }
}
