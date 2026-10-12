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
import { buildWasiErrorDetail } from "./wasi-error-detail.ts"
import { evaluateTestMode, logBlockedSend } from "./wa-test-mode.ts"
import { executeSend, last10, type CoreSendInput, type SendDeps } from "./wa-send-core.ts"
import { redactWasiText } from "./wasi-error-detail.ts"

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
  /** A Meta-approved WhatsApp template send with a document header — e.g.
   * the supplier quote-request PDF flow. UNCONFIRMED FIELD NAMES (2026-09-08):
   * Wasi's support team has never supplied a real sample payload for this
   * shape, unlike the plain-text and interactive shapes below (both
   * confirmed against real production payloads). `templateName`/
   * `headerMediaUrl`/`params` are this codebase's own best guess at Wasi's
   * contract, modeled on how other BSPs typically expose a template send —
   * NOT verified. See sendViaWasi's own comment on this. */
  templateSend?: {
    templateName: string
    headerMediaUrl: string
    params: Record<string, string>
  }
  /** How many send attempts already happened for this logical message
   * before this one — 0 (the default) for a genuinely first attempt.
   * Callers that are RESENDING a previous failed/pending row (the
   * milestone dispatcher, the daily failed-send retry pass) pass the prior
   * row's own retry_count + 1, so the bounded-retry safeguard in each of
   * those callers can tell how many attempts a given logical message has
   * already had, across however many outbox rows that history spans. */
  retryCount?: number
  /** Dispatcher v2 (settings.wa_dispatch_v2_enabled). 'reply' answers something the customer just sent (free text, always
   * inside the window). 'notification' is system-initiated: an approved template, or free text only inside the 24 h
   * window; otherwise the row is recorded as skipped_no_template and nothing is sent. Default 'reply'. */
  purpose?: "reply" | "notification"
  language?: "en" | "ta"
  /** Variables available to the event's template mapping (name, ticket_ref, ...). */
  vars?: Record<string, string | null | undefined>
  headerMediaUrl?: string | null
  /** The dispatcher already inserted and claimed this row: update it in place instead of inserting a new one. */
  outboxId?: string
}

export type SendMessageResult = {
  outboxId: string
  waMessageId: string | null
  /** Not a stored column — whatsapp_outbox has no dispatched field.
   * status ('sent' | 'failed' | 'received') is the DB-level source of
   * truth; this is purely the in-memory signal to the caller of whether
   * anything actually left this server just now. */
  dispatched: boolean
  /** Wasi's full raw response body from the actual send attempt, if one was
   * made (undefined in stub mode). Not persisted — whatsapp_outbox.error
   * keeps the existing short formatted summary — exists purely so a caller
   * debugging an unconfirmed payload shape (see templateSend above) can see
   * everything the provider said back, not just a summarized string. */
  rawResponse?: string
  /** v2 only: the row's final status ('sent' | 'pending' | 'failed' | 'skipped_no_template') and its error text. */
  status?: string
  error?: string | null
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

type WasiSendResult = { ok: true; waMessageId: string | null; rawBody: string } | { ok: false; error: string; rawBody: string }

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
  interactive?: NonNullable<Reply["interactive"]>,
  templateSend?: NonNullable<SendMessageInput["templateSend"]>
): Promise<WasiSendResult> {
  const intlTo = `${INDIA_COUNTRY_CODE}${to}`
  // Wasi's real outbound envelope: plain text is {client_id, to, type,
  // body}; interactive is the exact same envelope with type: "interactive"
  // and Reply.interactive's fields (header/footer/buttons OR
  // button+sections) spread in alongside body — confirmed against Wasi
  // support's own production-verified sample payloads, 2026-08-27.
  //
  // The `templateSend` branch is NOT confirmed the same way — see its own
  // doc comment on SendMessageInput. `template`/`headerMediaUrl`/`params`
  // as top-level fields (no `body`, since an approved template's own text
  // carries the message content) is this codebase's best guess, not a
  // verified Wasi contract. Whatever Wasi's real response says back — a
  // clean 201, or a 4xx naming the actual expected field — is the real
  // signal here, not this comment.
  const payload = templateSend
    ? { client_id: clientId, to: intlTo, type: "template", template: templateSend.templateName, headerMediaUrl: templateSend.headerMediaUrl, params: templateSend.params }
    : interactive
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
    return { ok: false, error: isTimeout ? message : `network_error: ${message}`, rawBody: "" }
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
    console.log("whatsapp.ts: wasi send succeeded, raw response:", redactWasiText(rawText))
    return { ok: true, waMessageId: extractWasiMessageId(parsed), rawBody: rawText }
  }

  console.error("whatsapp.ts: wasi send failed", res.status, redactWasiText(rawText))
  // The stored error keeps the short summary first, then a cleaned (tokens stripped, phone numbers
  // masked, ~500 chars) copy of Wasi's own response and a few safe headers — so a rejection can be
  // diagnosed from the outbox row without digging through function logs.
  return { ok: false, error: buildWasiErrorDetail(formatWasiError(res.status, parsed ?? rawText), rawText, res.headers), rawBody: rawText }
}

// ── dispatcher v2 plumbing (docs/plan-dispatcher-fix.md) ──────────────────────────────────────────────────────────────
const v2FlagCache = new Map<string, { value: boolean; expiresAt: number }>()
const V2_FLAG_TTL_MS = 30_000

/** settings.wa_dispatch_v2_enabled, cached 30 s. Any read problem falls back to the legacy path (today's behaviour). */
export async function isDispatchV2Enabled(admin: SupabaseClient, orgId: string): Promise<boolean> {
  const cached = v2FlagCache.get(orgId)
  if (cached && cached.expiresAt > Date.now()) return cached.value
  const { data, error } = await admin
    .from("settings")
    .select("wa_dispatch_v2_enabled")
    .eq("org_id", orgId)
    .abortSignal(AbortSignal.timeout(DB_CALL_TIMEOUT_MS))
    .maybeSingle()
  const value = !error && (data as { wa_dispatch_v2_enabled?: boolean } | null)?.wa_dispatch_v2_enabled === true
  v2FlagCache.set(orgId, { value, expiresAt: Date.now() + V2_FLAG_TTL_MS })
  return value
}

/** base URL + credentials for an org, or null when this environment is not configured to send (stub mode). */
export async function resolveWasiTransport(admin: SupabaseClient, orgId: string): Promise<{ baseUrl: string; apiKey: string; clientId: string } | null> {
  const baseUrl = Deno.env.get("WASI_API_BASE_URL")
  if (!baseUrl) return null
  const creds = await resolveWasiCredentials(admin, orgId)
  return creds ? { baseUrl, apiKey: creds.apiKey, clientId: creds.clientId } : null
}

/** Test seam, and how a flag flip takes effect immediately inside one warm instance. */
export function resetDispatchV2FlagCache() {
  v2FlagCache.clear()
}

function buildSendDeps(admin: SupabaseClient): SendDeps {
  return {
    nowMs: () => Date.now(),
    async getLastInboundAt(orgId, phone10) {
      const { data } = await admin
        .from("whatsapp_contacts")
        .select("last_inbound_at")
        .eq("org_id", orgId)
        .eq("phone", phone10)
        .abortSignal(AbortSignal.timeout(DB_CALL_TIMEOUT_MS))
        .maybeSingle()
      return (data as { last_inbound_at?: string } | null)?.last_inbound_at ?? null
    },
    async findApprovedMapping(orgId, eventKey, language) {
      const { data: m } = await admin
        .from("whatsapp_event_templates")
        .select("wasi_template_name, param_map")
        .eq("org_id", orgId)
        .eq("event_key", eventKey)
        .eq("language", language)
        .eq("is_active", true)
        .abortSignal(AbortSignal.timeout(DB_CALL_TIMEOUT_MS))
        .maybeSingle()
      const mapping = m as { wasi_template_name: string; param_map: Record<string, string> | null } | null
      if (!mapping) return null
      const { data: t } = await admin
        .from("whatsapp_wasi_templates")
        .select("status, header_type, param_keys")
        .eq("org_id", orgId)
        .eq("wasi_name", mapping.wasi_template_name)
        .abortSignal(AbortSignal.timeout(DB_CALL_TIMEOUT_MS))
      const copies = (t ?? []) as { status: string; header_type: string | null; param_keys: string[] | null }[]
      // Wasi picks arbitrarily when one name exists in several languages (their known bug), so a duplicated name is
      // never used; a name that is not approved behaves exactly like "no template".
      if (copies.length !== 1) return null
      const mirror = copies[0].status === "approved" ? copies[0] : null
      if (!mirror) return null
      return {
        wasiTemplateName: mapping.wasi_template_name,
        paramMap: mapping.param_map ?? {},
        paramKeys: mirror.param_keys ?? null,
        headerType: mirror.header_type ?? null,
      }
    },
    async insertRow(row) {
      const { data, error } = await admin.from("whatsapp_outbox").insert(row).select("id").single()
      if (error) throw error
      return (data as { id: string }).id
    },
    async updateRow(id, patch) {
      const { error } = await admin.from("whatsapp_outbox").update(patch).eq("id", id)
      if (error) throw error
    },
    evaluateTestMode: (orgId, to) => evaluateTestMode(admin, orgId, to),
    logBlocked: (info) => logBlockedSend(admin, info),
    async getTransport(orgId) {
      const baseUrl = Deno.env.get("WASI_API_BASE_URL")
      if (!baseUrl) return null
      const creds = await resolveWasiCredentials(admin, orgId)
      return creds ? { baseUrl, apiKey: creds.apiKey, clientId: creds.clientId } : null
    },
    async post(url, apiKey, body) {
      const res = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${apiKey}` },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(WASI_REQUEST_TIMEOUT_MS),
      })
      return { status: res.status, text: await res.text(), headers: res.headers }
    },
  }
}

async function sendMessageV2(admin: SupabaseClient, input: SendMessageInput): Promise<SendMessageResult> {
  const core: CoreSendInput = {
    orgId: input.orgId,
    to: last10(input.to),
    customerId: input.customerId,
    template: input.template,
    body: input.body,
    interactive: input.interactive as Record<string, unknown> | undefined,
    type: input.type,
    refType: input.refType ?? null,
    refId: input.refId ?? null,
    retryCount: input.retryCount ?? 0,
    purpose: input.purpose ?? "reply",
    language: input.language,
    vars: input.vars,
    headerMediaUrl: input.headerMediaUrl ?? null,
    outboxId: input.outboxId,
    templateSend: input.templateSend
      ? { templateName: input.templateSend.templateName, headerMediaUrl: input.templateSend.headerMediaUrl, params: input.templateSend.params }
      : undefined,
  }
  const r = await executeSend(buildSendDeps(admin), core)
  return { outboxId: r.outboxId, waMessageId: r.waMessageId, dispatched: r.dispatched, status: r.status, error: r.error }
}

export async function sendMessage(admin: SupabaseClient, input: SendMessageInput): Promise<SendMessageResult> {
  if (await isDispatchV2Enabled(admin, input.orgId)) return sendMessageV2(admin, input)
  return sendMessageLegacy(admin, input)
}

/** The pre-v2 path, unchanged: insert after the send, optimistic stub 'sent'. Kept so the flag can be switched off. */
async function sendMessageLegacy(admin: SupabaseClient, input: SendMessageInput): Promise<SendMessageResult> {
  // Test-mode allow-list (review F-08, settings.wa_test_mode_enabled, ships OFF): the one place every real send passes
  // through. A blocked message is recorded as a failed row that no retry loop will pick up (retried_at set) and logged.
  const verdict = await evaluateTestMode(admin, input.orgId, input.to)
  if (verdict.blocked) {
    const { data: blockedRow, error: blockedError } = await admin
      .from("whatsapp_outbox")
      .insert({
        org_id: input.orgId,
        direction: "outbound",
        to_mobile: input.to,
        customer_id: input.customerId,
        template: input.template,
        type: input.type ?? "text",
        payload: { body: input.body },
        ref_type: input.refType ?? null,
        ref_id: input.refId ?? null,
        status: "failed",
        wa_message_id: null,
        error: `blocked: ${verdict.reason}`,
        retried_at: new Date().toISOString(),
        retry_count: input.retryCount ?? 0,
      })
      .select("id")
      .single()
    if (blockedError) throw blockedError
    await logBlockedSend(admin, {
      orgId: input.orgId,
      to: input.to,
      template: input.template,
      refType: input.refType ?? null,
      refId: input.refId ?? null,
      reason: verdict.reason,
      outboxId: blockedRow.id,
    })
    return { outboxId: blockedRow.id, waMessageId: null, dispatched: false }
  }

  const baseUrl = Deno.env.get("WASI_API_BASE_URL")
  const creds = baseUrl ? await resolveWasiCredentials(admin, input.orgId) : null

  let status: "sent" | "failed" = "sent"
  let waMessageId: string | null = null
  let sendError: string | null = null
  let dispatched = false
  let rawResponse: string | undefined

  if (baseUrl && creds) {
    const result = await sendViaWasi(baseUrl, creds.apiKey, creds.clientId, input.to, input.body, input.interactive, input.templateSend)
    rawResponse = result.rawBody
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
      type: input.type ?? (input.templateSend ? "template" : input.interactive ? "interactive" : "text"),
      payload: input.templateSend
        ? { body: input.body, template_send: input.templateSend }
        : input.interactive
          ? { body: input.body, interactive: input.interactive }
          : { body: input.body },
      ref_type: input.refType ?? null,
      ref_id: input.refId ?? null,
      status,
      wa_message_id: waMessageId,
      error: sendError,
      retry_count: input.retryCount ?? 0,
    })
    .select("id")
    .single()

  if (error) throw error

  return { outboxId: data.id, waMessageId, dispatched, rawResponse }
}
