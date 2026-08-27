// AI/CRM Answer Layer, Phase 2 — the orchestration function itself. Given a
// customer's free-text question, decides whether one of the 4 read-only
// wa_get_* RPCs (20260827090000) can answer it, and if so, answers ONLY
// from that RPC's real data. See GV_MART_AI_CRM_ANSWER_LAYER_SPEC.md and
// the design reviewed/approved with the user before this was written.
//
// STANDALONE PHASE — deliberately NOT called from handleMessage yet (see
// test-answer-layer/index.ts, same "build it, test it directly, wire it in
// later" pattern as test-send-ping). Wiring into the live webhook is a
// separate, later step the user explicitly wants to review a real test set
// against first.
//
// The core anti-hallucination guardrail is structural, not just prompt
// wording: the model is NEVER allowed to respond with plain text. Every
// turn forces exactly one tool call (tool_choice: "any" in round 1,
// tool_choice: a specific tool in round 2) — same forced-tool-call
// discipline whatsapp-classify-intent.ts already uses, extended to two
// rounds. org_id/phone are bound server-side from already-resolved
// identity and are NEVER exposed as a model-fillable tool parameter — the
// model cannot ask to look up a different customer's data even if the
// question text tried to say so, because there's no field for it.
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2"

export const ANSWER_MODEL = "claude-haiku-4-5-20251001"
const ANTHROPIC_TIMEOUT_MS = 10_000

const SYSTEM_PROMPT = `You are answering ONE customer's question for GV Mart, a water-purifier / AC /
inverter / battery sales-and-service business in Chennai, India, over WhatsApp.
The customer already went through the bot's menu and asked something free-form
that didn't match a menu option.

You do not know anything about this customer, GV Mart's prices, stock, tickets,
or coverage from your own training — only the tools below can tell you that.
Never answer from general knowledge, never guess, never estimate, and never
say something is "probably" true. If a tool doesn't return the specific fact
the customer asked for, you do not have that fact — full stop.

You will work in two steps, each requiring exactly one tool call:

STEP 1 — pick a tool. Call the ONE tool whose description matches what the
customer is actually asking. If nothing matches, or the question is too
ambiguous to confidently pick one (e.g. "is it good?" with no clear subject,
or a question mixing two different topics), or the customer is asking you to
DO something — book, cancel, change, buy — rather than look something up,
call cannot_answer. This bot's menus handle actions; you only answer
questions here. When genuinely unsure, call cannot_answer rather than
guessing — a wrong tool choice is worse than admitting you can't help.

STEP 2 — after you receive the tool's real result, call respond_to_customer.
Base your answer ONLY on the data in that result. If the result is empty, has
no match, or doesn't actually contain what the customer asked for, set
can_answer to false — do not fill the gap with a plausible-sounding guess,
and do not soften an empty result into something that sounds like an answer.

If the customer's message asked about more than this one tool's result can
cover — a second topic, a different product, an action request alongside the
question — set fully_addresses_question to false. Do this even when you could
technically add a generic, true-sounding suggestion for the rest ("check with
our team", "visit our showroom") — don't put that in the answer at all. Answer
only the part the tool result actually covers, or don't answer at all; never
pad a grounded answer with an ungrounded one.

Messages may be in English, Tamil, or Tanglish (Tamil-English code-mixed).
Reply in the same language/mix the customer used. Keep the answer short —
2-3 sentences at most, plain text, no markdown, no bullet lists, this is a
WhatsApp chat message, not a report.`

const ROUND1_TOOLS = [
  {
    name: "get_amc_status",
    description:
      "Look up this customer's AMC (annual maintenance contract) and warranty coverage for their products — expiry dates, active/due-soon/expired status, plan name. Use for questions like 'what's my AMC status', 'when does my warranty expire', 'am I still covered'.",
    input_schema: { type: "object", properties: {}, required: [] },
  },
  {
    name: "get_product_price",
    description:
      "Look up current pricing for a GV Mart product by name or category (RO purifier, AC, inverter, battery). Use for questions like 'how much is a 25 LPH RO', 'what's the price of an inverter', 'do you have LG ACs'.",
    input_schema: {
      type: "object",
      properties: {
        search: {
          type: "string",
          description:
            "The product name, model, or category the customer mentioned, extracted from their question — e.g. 'RO', '25 LPH RO purifier', 'LG AC'. Not the full question text.",
        },
      },
      required: ["search"],
    },
  },
  {
    name: "get_service_ticket_status",
    description:
      "Look up the status of this customer's service/repair ticket. If they mentioned a specific reference code (a short code from a booking confirmation message, e.g. '439a9162'), pass it — otherwise this returns their single most recent ticket. Use for questions like 'what's the status of my repair', 'when is the technician coming', 'is ticket 439a9162 done yet'.",
    input_schema: {
      type: "object",
      properties: {
        ticket_ref: {
          type: "string",
          description:
            "A ticket reference code the customer explicitly mentioned, if any. Omit this field entirely if they didn't mention one — do not invent one.",
        },
      },
      required: [],
    },
  },
  {
    name: "get_purchase_history",
    description:
      "Look up what products this customer has bought from GV Mart, when, and their current coverage status. Use for questions like 'what have I bought', 'when did I buy my RO', 'is my AC still covered' when tied to a specific past purchase rather than AMC status in general.",
    input_schema: { type: "object", properties: {}, required: [] },
  },
  {
    name: "cannot_answer",
    description:
      "Call this when none of the other tools can resolve the customer's question, the question is too ambiguous to pick a tool confidently, or the customer is asking for an action (book/cancel/change) rather than information.",
    input_schema: {
      type: "object",
      properties: {
        reason: {
          type: "string",
          description: "One short internal note on why no tool applies — for our own review logs, never shown to the customer.",
        },
      },
      required: ["reason"],
    },
  },
] as const

const RESPOND_TOOL = {
  name: "respond_to_customer",
  description: "Give your final answer after seeing the tool result.",
  input_schema: {
    type: "object",
    properties: {
      can_answer: {
        type: "boolean",
        description:
          "True only if the tool result actually contains the specific fact the customer asked for. False if the result is empty, has no match, or doesn't cover what they asked — even if you could technically say something plausible.",
      },
      fully_addresses_question: {
        type: "boolean",
        description:
          "True only if your answer covers EVERYTHING the customer asked in their message. False if their message contained anything beyond what this tool's result can address — a second topic, a different product, an action request — even if you could technically add a generic suggestion for the rest. When false, do not include that generic suggestion in `answer` at all; the whole reply gets discarded and the customer is handed off instead.",
      },
      answer: {
        type: "string",
        description:
          "The reply to send the customer, 2-3 sentences max, plain text. Only meaningful when can_answer AND fully_addresses_question are both true — leave empty otherwise.",
      },
    },
    required: ["can_answer", "fully_addresses_question", "answer"],
  },
} as const

type AnthropicToolUseBlock = { type: "tool_use"; id: string; name: string; input: Record<string, unknown> }
type AnthropicResponse = { content?: Array<{ type: string } & Record<string, unknown>>; stop_reason?: string }

export type AnswerLayerResult =
  | {
      outcome: "answered"
      answer: string
      toolUsed: string
      toolInput: unknown
      toolResult: unknown
      latencyMs: number
      modelCanAnswer?: boolean
      modelFullyAddresses?: boolean
    }
  | {
      outcome: "handoff"
      reason: string
      toolUsed: string | null
      toolInput?: unknown
      toolResult?: unknown
      latencyMs: number
      modelCanAnswer?: boolean
      modelFullyAddresses?: boolean
    }

async function callAnthropic(
  apiKey: string,
  messages: unknown[],
  tools: unknown[],
  toolChoice: unknown
): Promise<AnthropicResponse | null> {
  try {
    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-api-key": apiKey, "anthropic-version": "2023-06-01" },
      signal: AbortSignal.timeout(ANTHROPIC_TIMEOUT_MS),
      body: JSON.stringify({
        model: ANSWER_MODEL,
        max_tokens: 500,
        system: SYSTEM_PROMPT,
        messages,
        tools,
        tool_choice: toolChoice,
      }),
    })
    if (!res.ok) {
      const errText = await res.text().catch(() => "")
      console.error("whatsapp-answer-layer: Anthropic API error", res.status, errText)
      return null
    }
    return (await res.json()) as AnthropicResponse
  } catch (e) {
    const isTimeout = e instanceof Error && e.name === "TimeoutError"
    console.error("whatsapp-answer-layer: request failed", isTimeout ? "timeout" : e)
    return null
  }
}

function findToolUse(res: AnthropicResponse | null): AnthropicToolUseBlock | null {
  const block = res?.content?.find((b) => b.type === "tool_use")
  return (block as AnthropicToolUseBlock | undefined) ?? null
}

// Tool name -> the wa_get_* RPC it calls. cannot_answer has no RPC — handled
// separately in the orchestration loop below, before this map is consulted.
const TOOL_TO_RPC: Record<string, string> = {
  get_amc_status: "wa_get_amc_status",
  get_product_price: "wa_get_product_price",
  get_service_ticket_status: "wa_get_service_ticket_status",
  get_purchase_history: "wa_get_purchase_history",
}

async function executeTool(
  admin: SupabaseClient,
  orgId: string,
  phone: string,
  toolName: string,
  toolInput: Record<string, unknown>
): Promise<{ data: unknown; error: string | null }> {
  const rpcName = TOOL_TO_RPC[toolName]
  if (!rpcName) return { data: null, error: `unknown_tool:${toolName}` }

  // org_id/phone are ALWAYS the server-resolved values passed into
  // answerCustomerQuestion — never anything derived from toolInput. This is
  // the actual enforcement of "the model can't ask for another customer's
  // data": there is no code path here that reads a phone/org_id out of
  // what the model returned. Each RPC gets exactly the params its own
  // signature declares — PostgREST resolves a function by matching the
  // given param names exactly, so passing an undeclared one (e.g. p_phone
  // to wa_get_product_price, which takes none) fails the call outright
  // rather than being silently ignored.
  let args: Record<string, unknown>
  switch (toolName) {
    case "get_product_price":
      args = { p_org_id: orgId, p_search: typeof toolInput.search === "string" ? toolInput.search : "" }
      break
    case "get_service_ticket_status":
      args = { p_org_id: orgId, p_phone: phone }
      if (typeof toolInput.ticket_ref === "string" && toolInput.ticket_ref.trim() !== "") {
        args.p_ticket_ref = toolInput.ticket_ref
      }
      break
    default:
      args = { p_org_id: orgId, p_phone: phone }
  }

  const { data, error } = await admin.rpc(rpcName, args)
  if (error) return { data: null, error: error.message }
  return { data, error: null }
}

async function logResult(
  admin: SupabaseClient,
  orgId: string,
  phone: string,
  question: string,
  result: AnswerLayerResult
) {
  const row =
    result.outcome === "answered"
      ? {
          org_id: orgId,
          phone,
          question,
          tool_used: result.toolUsed,
          tool_input: result.toolInput,
          tool_result: result.toolResult,
          can_answer: true,
          answer: result.answer,
          reason: null,
          latency_ms: result.latencyMs,
          model_can_answer: result.modelCanAnswer ?? null,
          model_fully_addresses_question: result.modelFullyAddresses ?? null,
        }
      : {
          org_id: orgId,
          phone,
          question,
          tool_used: result.toolUsed,
          tool_input: result.toolInput ?? null,
          tool_result: result.toolResult ?? null,
          can_answer: false,
          answer: null,
          reason: result.reason,
          latency_ms: result.latencyMs,
          model_can_answer: result.modelCanAnswer ?? null,
          model_fully_addresses_question: result.modelFullyAddresses ?? null,
        }

  const { error } = await admin.from("wa_answer_layer_log").insert(row)
  if (error) console.error("whatsapp-answer-layer: failed to write audit log", error)
}

export async function answerCustomerQuestion(
  admin: SupabaseClient,
  orgId: string,
  phone: string,
  question: string
): Promise<AnswerLayerResult> {
  const start = performance.now()

  // Independent kill switch — separate from settings.whatsapp_bot_enabled
  // (the whole-bot switch, checked earlier in handleMessage before this
  // function is ever reached). This lets the Answer Layer specifically be
  // turned off during early rollout review without silencing journeys or
  // needing a redeploy — same "compute-on-call, no auth.uid() available"
  // constraint as every other settings read in this codebase's service-
  // role context, so this is a plain read, not an RLS-gated one.
  const { data: settingsRow, error: settingsError } = await admin
    .from("settings")
    .select("wa_answer_layer_enabled")
    .eq("org_id", orgId)
    .maybeSingle()
  if (settingsError) console.error("whatsapp-answer-layer: failed to read settings, defaulting to disabled", settingsError)
  if (settingsError || !settingsRow?.wa_answer_layer_enabled) {
    const result: AnswerLayerResult = { outcome: "handoff", reason: "answer_layer_disabled", toolUsed: null, latencyMs: Math.round(performance.now() - start) }
    await logResult(admin, orgId, phone, question, result)
    return result
  }

  const apiKey = Deno.env.get("ANTHROPIC_API_KEY")

  if (!apiKey) {
    const result: AnswerLayerResult = { outcome: "handoff", reason: "not_configured", toolUsed: null, latencyMs: Math.round(performance.now() - start) }
    await logResult(admin, orgId, phone, question, result)
    return result
  }

  // ── Round 1: force exactly one tool call, never plain text ──────────────
  const round1 = await callAnthropic(apiKey, [{ role: "user", content: question }], ROUND1_TOOLS, {
    type: "any",
    disable_parallel_tool_use: true,
  })
  const round1Tool = findToolUse(round1)

  if (!round1Tool) {
    const result: AnswerLayerResult = {
      outcome: "handoff",
      reason: round1 ? "no_tool_use_in_response" : "api_error_or_timeout",
      toolUsed: null,
      latencyMs: Math.round(performance.now() - start),
    }
    await logResult(admin, orgId, phone, question, result)
    return result
  }

  if (round1Tool.name === "cannot_answer") {
    const result: AnswerLayerResult = {
      outcome: "handoff",
      reason: typeof round1Tool.input.reason === "string" ? round1Tool.input.reason : "cannot_answer",
      toolUsed: "cannot_answer",
      toolInput: round1Tool.input,
      latencyMs: Math.round(performance.now() - start),
    }
    await logResult(admin, orgId, phone, question, result)
    return result
  }

  // ── Execute the real RPC — the only place actual customer data enters ───
  const { data: toolResult, error: toolError } = await executeTool(admin, orgId, phone, round1Tool.name, round1Tool.input)
  if (toolError) {
    const result: AnswerLayerResult = {
      outcome: "handoff",
      reason: `tool_execution_error:${toolError}`,
      toolUsed: round1Tool.name,
      toolInput: round1Tool.input,
      latencyMs: Math.round(performance.now() - start),
    }
    await logResult(admin, orgId, phone, question, result)
    return result
  }

  // ── Round 2: force respond_to_customer, feed back the REAL data ─────────
  const round2 = await callAnthropic(
    apiKey,
    [
      { role: "user", content: question },
      { role: "assistant", content: [{ type: "tool_use", id: round1Tool.id, name: round1Tool.name, input: round1Tool.input }] },
      { role: "user", content: [{ type: "tool_result", tool_use_id: round1Tool.id, content: JSON.stringify(toolResult) }] },
    ],
    [RESPOND_TOOL],
    { type: "tool", name: "respond_to_customer", disable_parallel_tool_use: true }
  )
  const round2Tool = findToolUse(round2)

  if (!round2Tool) {
    const result: AnswerLayerResult = {
      outcome: "handoff",
      reason: round2 ? "no_tool_use_in_round2_response" : "api_error_or_timeout_round2",
      toolUsed: round1Tool.name,
      toolInput: round1Tool.input,
      toolResult,
      latencyMs: Math.round(performance.now() - start),
    }
    await logResult(admin, orgId, phone, question, result)
    return result
  }

  const canAnswer = round2Tool.input.can_answer === true
  const fullyAddresses = round2Tool.input.fully_addresses_question === true
  const answerText = typeof round2Tool.input.answer === "string" ? round2Tool.input.answer.trim() : ""

  // Both booleans required — same enforced-field pattern can_answer already
  // used, extended to a second, independent dimension: "did the tool have
  // the fact" vs. "does the answer cover the WHOLE question." The derived
  // `reason` string (can_answer_false vs. partial_coverage_only) is a
  // best-effort label, not fully reliable on its own — observed in testing
  // that the model doesn't always keep the two dimensions cleanly separate
  // (it sometimes reports can_answer:false for a genuinely incomplete-but-
  // partially-grounded case rather than using fully_addresses_question for
  // that). modelCanAnswer/modelFullyAddresses below are the RAW booleans
  // exactly as the model set them, logged alongside the derived reason so
  // review isn't dependent on the model's own labeling discipline — the
  // enforced outcome gate above (both must be true to answer) doesn't
  // depend on this distinction being clean; only the audit trail's
  // diagnostic precision does.
  const result: AnswerLayerResult =
    canAnswer && fullyAddresses && answerText.length > 0
      ? {
          outcome: "answered",
          answer: answerText,
          toolUsed: round1Tool.name,
          toolInput: round1Tool.input,
          toolResult,
          latencyMs: Math.round(performance.now() - start),
          modelCanAnswer: canAnswer,
          modelFullyAddresses: fullyAddresses,
        }
      : {
          outcome: "handoff",
          reason: !canAnswer ? "can_answer_false" : "partial_coverage_only",
          toolUsed: round1Tool.name,
          toolInput: round1Tool.input,
          toolResult,
          latencyMs: Math.round(performance.now() - start),
          modelCanAnswer: canAnswer,
          modelFullyAddresses: fullyAddresses,
        }

  await logResult(admin, orgId, phone, question, result)
  return result
}
