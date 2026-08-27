// WhatsApp transport adapter (plan decision #5, now resolved: Wasi). This is
// the one seam that choice plugs into — every caller goes through
// sendMessage() below; nothing upstream of it (journeys, handleMessage,
// wa-scheduled-tasks) knows or cares whether a send is real or stubbed.
//
// Real dispatch is gated on THREE things all being true:
//   1. WASI_API_BASE_URL is set (read directly in sendMessage below) — no
//      hardcoded guess; unset means "not configured yet", not an error.
//   2. The org has an active whatsapp_provider_credentials row for 'wasi'.
//   3. The message has no `interactive` payload. Wasi's confirmed contract
//      only documents the plain-text send shape ({client_id, to, type:
//      "text", body}) — whether it accepts Meta's interactive-list JSON
//      Reply.interactive carries is still an open question (flagged
//      separately, not resolved here). Until that's answered, any reply
//      with `interactive` set — which is most menu/list prompts — keeps
//      going through the log-only stub, same as before this change.
// Any one of those being false falls back to the original stub behavior:
// insert-only, dispatched: false, nothing left this server. This keeps
// local/unconfigured environments working exactly as they did.
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2"

// 2026-08-25 incident: sendViaWasi's fetch had no timeout at all, so a single
// slow/hung Wasi request could block a whole Edge Function invocation past
// its execution window (observed as an "EarlyDrop" — the platform killing
// the isolate, not a catchable exception — so the customer got silence and
// nothing was ever logged as an error). 15s is generous for a messaging API
// round-trip while still bounding the hang. DB_CALL_TIMEOUT_MS is shorter —
// these all go to this project's own PostgREST, which should answer in low
// hundreds of ms under normal health; 5s is a defensive ceiling, not an
// expected latency.
//
// Both constants (and this fetch's own timeout below) were silently lost
// from this file at some point — a `supabase functions download` run
// against a stale deployed bundle almost certainly overwrote this file
// locally without warning — and only surfaced 2026-08-27 as a production
// BOOT_ERROR once wasi-webhook/whatsapp-webhook were next redeployed, since
// whatsapp-handle-message.ts depends on DB_CALL_TIMEOUT_MS at 6 call sites
// and was never itself out of sync. Restored here to the exact original
// values/reasoning, not just DB_CALL_TIMEOUT_MS (which only got fixed
// during that outage because it was the one actually breaking boot).
const WASI_REQUEST_TIMEOUT_MS = 15_000
export const DB_CALL_TIMEOUT_MS = 5_000

export type SendMessageInput = {
  orgId: string
  to: string // bare 10-digit, already normalized by the caller
  customerId: string | null
  template: string // e.g. "wa.menu", "wa.service.ack" — mirrors whatsapp_outbox.template
  body: string // human-readable text, logged into payload.body for now
  /** Meta interactive-message shape (list/button), when this reply is more than plain text. Stored in payload.interactive so a real send later has everything it needs without re-deriving it. */
  interactive?: unknown
  type?: "text" | "template" | "interactive" | "media"
  refType?: string | null
  refId?: string | null
}

export type SendMessageResult = {
  outboxId: string
  waMessageId: string | null
  /** Not a stored column — whatsapp_outbox has no dispatched field.
   * status ('sent' | 'failed' | 'received') is the DB-level source of
   * truth; this is purely the in-memory signal to the caller of whether
   * anything actually left this server just now. */
  dispatched: boolean
}

type WasiSendResult = { ok: true; waMessageId: string | null } | { ok: false; error: string }

async function resolveWasiCredentials(admin: SupabaseClient, orgId: string): Promise<{ clientId: string; apiKey: string } | null> {
  const { data } = await admin
    .from("whatsapp_provider_credentials")
    .select("client_id, api_key")
    .eq("org_id", orgId)
    .eq("provider", "wasi")
    .eq("is_active", true)
    .maybeSingle()
  if (!data?.client_id || !data?.api_key) return null
  return { clientId: data.client_id, apiKey: data.api_key }
}

/** Wasi's contract says "201 with created message row" but doesn't name
 * the field holding their message id — checks a few likely shapes (top
 * level and nested under data/message, matching how BSP APIs commonly
 * wrap a created resource) rather than guessing one and silently storing
 * the wrong thing. Returns null — not a thrown error — if nothing matches;
 * the send still counts as dispatched, just without a captured id. */
function extractWasiMessageId(responseBody: unknown): string | null {
  const candidates: unknown[] = [responseBody]
  if (responseBody && typeof responseBody === "object") {
    const obj = responseBody as Record<string, unknown>
    candidates.push(obj.data, obj.message)
  }
  for (const candidate of candidates) {
    if (!candidate || typeof candidate !== "object") continue
    const obj = candidate as Record<string, unknown>
    for (const key of ["message_id", "id", "wa_message_id", "wamid"]) {
      const v = obj[key]
      if (typeof v === "string" && v) return v
    }
  }
  return null
}

function formatWasiError(status: number, body: unknown): string {
  if (body && typeof body === "object") {
    const obj = body as Record<string, unknown>
    const code = obj.code ?? status
    const errorMsg = typeof obj.error === "string" ? obj.error : "unknown_error"
    return obj.metaError ? `${code}: ${errorMsg} (meta: ${JSON.stringify(obj.metaError)})` : `${code}: ${errorMsg}`
  }
  return `${status}: ${typeof body === "string" && body ? body : "no response body"}`
}

// customers.mobile (and SendMessageInput.to, by the same convention) is
// CHECK-constrained to bare 10 digits — confirmed against the live schema
// (`mobile ~ '^\d{10}$'`), no country code ever stored internally. Wasi's
// contract requires international format with no leading '+' (e.g.
// "919092766740"), so it has to be added back on for this one outbound
// call — nowhere else in this codebase carries a country code, and this
// single-org deployment is India-only (the 10-digit constraint itself
// assumes that), so "91" is a safe constant here, not a guess.
const INDIA_COUNTRY_CODE = "91"

async function sendViaWasi(baseUrl: string, apiKey: string, clientId: string, to: string, body: string): Promise<WasiSendResult> {
  const intlTo = `${INDIA_COUNTRY_CODE}${to}`
  let res: Response
  try {
    res = await fetch(`${baseUrl}/api/v1/messages`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${apiKey}` },
      body: JSON.stringify({ client_id: clientId, to: intlTo, type: "text", body }),
      signal: AbortSignal.timeout(WASI_REQUEST_TIMEOUT_MS),
    })
  } catch (e) {
    // Same isTimeout check as classifyWithClaude's own catch — AbortSignal.timeout
    // rejects with a DOMException named "TimeoutError", distinguishable from a
    // genuine network failure so the outbox row's error text says which one happened.
    const isTimeout = e instanceof Error && e.name === "TimeoutError"
    const message = isTimeout ? "Wasi request timed out" : e instanceof Error ? e.message : String(e)
    console.error("whatsapp.ts: wasi send request threw", message)
    return { ok: false, error: isTimeout ? message : `network_error: ${message}` }
  }

  const rawText = await res.text()
  let parsed: unknown = null
  try {
    parsed = rawText ? JSON.parse(rawText) : null
  } catch {
    // Non-JSON body — formatWasiError/extractWasiMessageId both handle a
    // null `parsed` gracefully, the raw text is still logged below.
  }

  if (res.status === 201) {
    console.log("whatsapp.ts: wasi send succeeded, raw response:", rawText)
    return { ok: true, waMessageId: extractWasiMessageId(parsed) }
  }

  console.error("whatsapp.ts: wasi send failed", res.status, rawText)
  return { ok: false, error: formatWasiError(res.status, parsed ?? rawText) }
}

export async function sendMessage(admin: SupabaseClient, input: SendMessageInput): Promise<SendMessageResult> {
  const baseUrl = Deno.env.get("WASI_API_BASE_URL")
  const isPlainText = !input.interactive

  const creds = baseUrl && isPlainText ? await resolveWasiCredentials(admin, input.orgId) : null

  let status: "sent" | "failed" = "sent"
  let waMessageId: string | null = null
  let sendError: string | null = null
  let dispatched = false

  if (baseUrl && creds) {
    const result = await sendViaWasi(baseUrl, creds.apiKey, creds.clientId, input.to, input.body)
    if (result.ok) {
      status = "sent"
      waMessageId = result.waMessageId
      dispatched = true
    } else {
      status = "failed"
      sendError = result.error
      dispatched = false
    }
  }
  // else: stub fallback — no baseUrl/credentials configured, or this is an
  // interactive (menu/list) message whose Wasi format isn't confirmed yet.
  // status stays "sent" (matches pre-existing stub behavior: nothing
  // failed, it just never left this server), dispatched stays false.

  const { data, error } = await admin
    .from("whatsapp_outbox")
    .insert({
      org_id: input.orgId,
      direction: "outbound",
      to_mobile: input.to,
      customer_id: input.customerId,
      template: input.template,
      type: input.type ?? (input.interactive ? "interactive" : "text"),
      payload: input.interactive ? { body: input.body, interactive: input.interactive } : { body: input.body },
      ref_type: input.refType ?? null,
      ref_id: input.refId ?? null,
      status,
      wa_message_id: waMessageId,
      error: sendError,
    })
    .select("id")
    .single()

  if (error) throw error

  return { outboxId: data.id, waMessageId, dispatched }
}
