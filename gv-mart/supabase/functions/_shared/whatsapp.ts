// WhatsApp transport adapter (plan decision #5, now resolved: Wasi). This is
// the one seam that choice plugs into — every caller goes through
// sendMessage() below; nothing upstream of it (journeys, handleMessage,
// wa-scheduled-tasks) knows or cares whether a send is real or stubbed.
//
// Real dispatch is gated on TWO things both being true:
//   1. WASI_API_BASE_URL is set (read directly in sendMessage below) — no
//      hardcoded guess; unset means "not configured yet", not an error.
//   2. The org has an active whatsapp_provider_credentials row for 'wasi'.
// Either being false falls back to the original stub behavior: insert-only,
// dispatched: false, nothing left this server. This keeps local/
// unconfigured environments working exactly as they did.
//
// A third gating condition — interactive messages always went through the
// stub, since Wasi's confirmed contract only documented the plain-text send
// shape — was resolved 2026-08-27: Wasi's support team supplied real
// production-verified sample payloads for their own flat interactive shape
// (NOT Meta's nested interactive object). sendViaWasi below now builds
// that shape and dispatches interactive messages for real, same as text.
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2"
import type { Reply } from "./whatsapp-journeys.ts"

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
  /** Wasi's flat interactive shape (buttons or button+sections), when this
   * reply is more than plain text — see Reply's own doc comment. Stored in
   * payload.interactive either way, so a real send has everything it needs
   * without re-deriving it even in stub mode. */
  interactive?: NonNullable<Reply["interactive"]>
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

export type RenderedTemplate = { found: true; body: string } | { found: false }

/** TS-side entry point into `_wa_render_template` (20260819170000) for
 * callers that send synchronously through sendMessage() themselves — e.g.
 * handleSupplierReply's ack messages — rather than the SQL-trigger callers
 * (_milestone_ticket_notify, _auto_draft_purchase_order, etc.) that call it
 * from within Postgres and stash the result straight into a raw
 * whatsapp_outbox insert. Same admin-overridable-via-Automation->Templates
 * contract either way: found:false (no template row yet) is the normal
 * "no override configured" case, not an error — callers fall back to
 * their own default body. */
export async function renderWaTemplate(admin: SupabaseClient, orgId: string, name: string, vars: Record<string, string>): Promise<RenderedTemplate> {
  const { data, error } = await admin
    .rpc("_wa_render_template", { p_org_id: orgId, p_name: name, p_vars: vars })
    .abortSignal(AbortSignal.timeout(DB_CALL_TIMEOUT_MS))
  if (error) {
    console.error("whatsapp: renderWaTemplate failed for", name, error)
    return { found: false }
  }
  const result = data as { found: boolean; body?: string }
  return result.found && result.body ? { found: true, body: result.body } : { found: false }
}

type WasiSendResult = { ok: true; waMessageId: string | null } | { ok: false; error: string }

// 2026-08-31 (latency): these credentials change only on a deliberate admin
// action (rotating/reconfiguring the Wasi integration) — essentially never
// mid-session — yet were being re-fetched from the DB on every single
// outbound send, which is every reply the bot ever makes. Cached per orgId
// for 5 minutes at Edge Function module scope (survives across invocations
// on the same warm instance, gone on a cold start — same "safe to be
// briefly stale" tradeoff as any short-TTL cache). Worst case after a real
// credential rotation: up to 5 minutes of failed sends with a clear
// unauthorized error in whatsapp_outbox, not a silent or permanent failure.
const wasiCredentialsCache = new Map<string, { creds: { clientId: string; apiKey: string } | null; expiresAt: number }>()
const WASI_CREDENTIALS_CACHE_TTL_MS = 5 * 60_000

async function resolveWasiCredentials(admin: SupabaseClient, orgId: string): Promise<{ clientId: string; apiKey: string } | null> {
  const cached = wasiCredentialsCache.get(orgId)
  if (cached && cached.expiresAt > Date.now()) return cached.creds

  const { data } = await admin
    .from("whatsapp_provider_credentials")
    .select("client_id, api_key")
    .eq("org_id", orgId)
    .eq("provider", "wasi")
    .eq("is_active", true)
    .maybeSingle()
  const creds = data?.client_id && data?.api_key ? { clientId: data.client_id, apiKey: data.api_key } : null
  wasiCredentialsCache.set(orgId, { creds, expiresAt: Date.now() + WASI_CREDENTIALS_CACHE_TTL_MS })
  return creds
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

async function sendViaWasi(
  baseUrl: string,
  apiKey: string,
  clientId: string,
  to: string,
  body: string,
  interactive?: NonNullable<Reply["interactive"]>
): Promise<WasiSendResult> {
  const intlTo = `${INDIA_COUNTRY_CODE}${to}`
  // Wasi's real outbound envelope: plain text is {client_id, to, type,
  // body}; interactive is the exact same envelope with type: "interactive"
  // and Reply.interactive's fields (header/footer/buttons OR
  // button+sections) spread in alongside body — confirmed against Wasi
  // support's own production-verified sample payloads, 2026-08-27.
  const payload = interactive
    ? { client_id: clientId, to: intlTo, type: "interactive", body, ...interactive }
    : { client_id: clientId, to: intlTo, type: "text", body }
  let res: Response
  try {
    res = await fetch(`${baseUrl}/api/v1/messages`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${apiKey}` },
      body: JSON.stringify(payload),
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
  const creds = baseUrl ? await resolveWasiCredentials(admin, input.orgId) : null

  let status: "sent" | "failed" = "sent"
  let waMessageId: string | null = null
  let sendError: string | null = null
  let dispatched = false

  if (baseUrl && creds) {
    const result = await sendViaWasi(baseUrl, creds.apiKey, creds.clientId, input.to, input.body, input.interactive)
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
  // else: stub fallback — no baseUrl/credentials configured for this org.
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
