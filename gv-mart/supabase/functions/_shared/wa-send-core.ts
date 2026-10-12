// WhatsApp dispatcher v2 — the send decision and response handling, as pure logic (no Deno, no Supabase client, no
// network imports) so vitest can exercise every branch. sendMessage() in whatsapp.ts is the thin adapter that supplies the
// real dependencies. See docs/plan-dispatcher-fix.md.
//
// What this module enforces (evidence: 55/55 production failures were Wasi 409 session_window_closed, and the real Wasi
// 201 body keeps the WhatsApp id in `meta_message_id`, not `id`):
//   - a row is inserted BEFORE the HTTP call and updated in place (one row per logical message);
//   - a template row sends { template, params } and never `body` / type "text";
//   - HTTP 201 with a meta_message_id is the only thing that makes a row 'sent';
//   - a system notification with no approved template outside the 24 h window is skipped, never sent as text;
//   - a wamid contains the recipient's number and is never logged or stored anywhere except wa_message_id.
import { buildWasiErrorDetail, redactWasiText, type HeadersLike } from "./wasi-error-detail.ts"

// ── constants ───────────────────────────────────────────────────────────────────────────────────────────────────────
export const WINDOW_MS = 24 * 3_600_000
/** Treat the window as closed 5 minutes early so a send never races the boundary. */
export const WINDOW_SAFETY_MARGIN_MS = 5 * 60_000
export const MAX_SEND_ATTEMPTS_V2 = 3
/** A row still pending this long after it was created or claimed is "stuck" and is shown to a human, never auto-resent. */
export const STUCK_CLAIM_MS = 15 * 60_000
export const MEDIA_HEADER_TYPES = ["DOCUMENT", "IMAGE", "VIDEO"] as const

/** Wasi 409 codes (Wasi API reference, 2026-10-12). 409 means nothing was sent or charged. */
export const WASI_409_CODES = [
  "session_window_closed",
  "consent_required",
  "media_resolution_failed",
  "auth_code_invalid",
  "auth_code_required",
  "plan_limit_reached",
  "waba_not_connected",
  "conflict",
] as const

export type WaOutboxStatus = "pending" | "sent" | "failed" | "received" | "skipped_no_template"

// ── small pure helpers ───────────────────────────────────────────────────────────────────────────────────────────────
/** Bare 10 digits, the form every stored mobile uses (last 10 digits of whatever was given). */
export function last10(raw: string | null | undefined): string {
  return (raw ?? "").replace(/\D/g, "").slice(-10)
}

/** Wasi wants "91" + 10 digits, always exactly that one format. */
export function toWasiNumber(raw: string): string {
  return `91${last10(raw)}`
}

export function isInsideWindow(lastInboundAtIso: string | null | undefined, nowMs: number): boolean {
  if (!lastInboundAtIso) return false
  const t = Date.parse(lastInboundAtIso)
  if (!Number.isFinite(t)) return false
  return nowMs - t < WINDOW_MS - WINDOW_SAFETY_MARGIN_MS && nowMs >= t - 60_000
}

export type SendDecision = "template" | "free_text" | "skip_no_template"

/** Rule (owner decision): system notifications always use an approved template; free text only inside the window. */
export function decideNotificationSend(input: { hasApprovedTemplate: boolean; insideWindow: boolean; hasFreeTextBody: boolean }): SendDecision {
  if (input.hasApprovedTemplate) return "template"
  if (input.insideWindow && input.hasFreeTextBody) return "free_text"
  return "skip_no_template"
}

export function isMediaHeader(headerType: string | null | undefined): boolean {
  return !!headerType && (MEDIA_HEADER_TYPES as readonly string[]).includes(headerType.toUpperCase())
}

// ── template request ─────────────────────────────────────────────────────────────────────────────────────────────────
export type TemplateMapping = {
  wasiTemplateName: string
  /** { wasi param name: variable key }. A param with no entry is read from the variable of the same name. */
  paramMap: Record<string, string>
  /** Param names Wasi expects (from the mirrored template list); falls back to paramMap's keys when unknown. */
  paramKeys: string[] | null
  headerType: string | null
}

export type TemplateRequestResult =
  | { ok: true; body: { client_id: string; to: string; type: "template"; template: string; params: Record<string, string>; headerMediaUrl?: string }; params: Record<string, string> }
  | { ok: false; error: string }

export function buildTemplateRequest(input: {
  clientId: string
  to: string
  mapping: TemplateMapping
  vars: Record<string, string | null | undefined>
  headerMediaUrl?: string | null
}): TemplateRequestResult {
  const keys = input.mapping.paramKeys && input.mapping.paramKeys.length > 0 ? input.mapping.paramKeys : Object.keys(input.mapping.paramMap)
  const params: Record<string, string> = {}
  for (const key of keys) {
    const varKey = input.mapping.paramMap[key] ?? key
    const value = input.vars[varKey]
    if (value == null || String(value).trim() === "") return { ok: false, error: `missing_param:${key}` }
    params[key] = String(value)
  }
  const body: { client_id: string; to: string; type: "template"; template: string; params: Record<string, string>; headerMediaUrl?: string } = {
    client_id: input.clientId,
    to: toWasiNumber(input.to),
    type: "template",
    template: input.mapping.wasiTemplateName,
    params,
  }
  if (isMediaHeader(input.mapping.headerType)) {
    if (!input.headerMediaUrl) return { ok: false, error: "missing_header_media" }
    body.headerMediaUrl = input.headerMediaUrl
  }
  return { ok: true, body, params }
}

// ── response handling ────────────────────────────────────────────────────────────────────────────────────────────────
export type SendOutcome =
  | { kind: "sent"; metaMessageId: string; wasiMessageId: string | null; wasiResponse: Record<string, unknown> }
  | { kind: "accepted_no_message_id"; wasiMessageId: string | null; wasiResponse: Record<string, unknown> }
  | { kind: "rejected"; httpStatus: number; code: string; retryable: boolean; error: string; wasiResponse: Record<string, unknown> | null }
  | { kind: "network_error"; message: string; unknownOutcome: boolean }

/** True only for errors that prove the request never left this machine (DNS / TCP connect). Anything else that is not a
 * timeout (a reset, a TLS or protocol error mid-request, an unknown exception) may have reached Wasi, so it is treated as an
 * unknown outcome and never resent automatically: Wasi has no idempotency key. */
export function isPreSendNetworkError(e: unknown): boolean {
  const text = e instanceof Error ? `${e.name} ${e.message} ${String((e as { cause?: unknown }).cause ?? "")}` : String(e)
  return /dns error|tcp connect error|client error \(Connect\)|ENOTFOUND|ECONNREFUSED|EAI_AGAIN|Name or service not known|connection refused/i.test(text)
}

function asRecord(v: unknown): Record<string, unknown> | null {
  return v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : null
}

function str(v: unknown): string | null {
  return typeof v === "string" && v.trim() !== "" ? v : null
}

/** Deep-clean an object for storage: every string goes through redactWasiText (numbers masked, wamids and secrets
 * redacted), and the fields that identify the recipient or carry credentials are dropped. */
export function sanitizeForStorage(value: unknown, depth = 0): unknown {
  if (depth > 6) return null
  if (typeof value === "string") return redactWasiText(value)
  if (Array.isArray(value)) return value.slice(0, 20).map((v) => sanitizeForStorage(v, depth + 1))
  const rec = asRecord(value)
  if (!rec) return value
  const out: Record<string, unknown> = {}
  for (const [k, v] of Object.entries(rec)) {
    if (/^(meta_message_id|wa_message_id|wamid|to|from|wa_id|client_id|api_key|authorization)$/i.test(k)) continue
    out[k] = sanitizeForStorage(v, depth + 1)
  }
  return out
}

export function classifyWasiResponse(httpStatus: number, rawText: string, headers?: HeadersLike | null): SendOutcome {
  let parsed: unknown = null
  try {
    parsed = rawText ? JSON.parse(rawText) : null
  } catch {
    parsed = null
  }
  const body = asRecord(parsed)
  const errObj = asRecord(body?.error)

  if (httpStatus === 201) {
    const metaId = str(body?.meta_message_id)
    const wasiId = str(body?.id)
    const cleaned = (sanitizeForStorage(body ?? {}) as Record<string, unknown>) ?? {}
    // A 201 whose own status says failed is a rejection, not a send.
    if (str(body?.status) === "failed") {
      return { kind: "rejected", httpStatus, code: "accepted_failed", retryable: false, error: buildWasiErrorDetail("201: accepted_failed", rawText, headers), wasiResponse: cleaned }
    }
    if (metaId) return { kind: "sent", metaMessageId: metaId, wasiMessageId: wasiId, wasiResponse: cleaned }
    return { kind: "accepted_no_message_id", wasiMessageId: wasiId, wasiResponse: cleaned }
  }

  const code = str(errObj?.code) ?? (str(body?.code) as string | null) ?? `http_${httpStatus}`
  const cleaned = parsed == null ? null : (sanitizeForStorage(body ?? { raw: String(parsed) }) as Record<string, unknown>)

  if (httpStatus === 409) {
    return { kind: "rejected", httpStatus, code, retryable: code === "conflict", error: buildWasiErrorDetail(`409: ${code}`, rawText, headers), wasiResponse: cleaned }
  }
  if (httpStatus === 502) {
    // WhatsApp itself rejected it: keep the whole metaError object and fbtrace_id for the support ticket.
    const metaError = body?.metaError ?? errObj?.metaError ?? null
    const fbtrace = str(body?.fbtrace_id) ?? str(errObj?.fbtrace_id) ?? null
    const kept: Record<string, unknown> = { ...(cleaned ?? {}) }
    if (metaError != null) kept.metaError = sanitizeForStorage(metaError)
    if (fbtrace) kept.fbtrace_id = fbtrace
    return { kind: "rejected", httpStatus, code: "whatsapp_rejected", retryable: false, error: buildWasiErrorDetail("502: whatsapp_rejected", rawText, headers), wasiResponse: kept }
  }
  return { kind: "rejected", httpStatus, code, retryable: false, error: buildWasiErrorDetail(`${httpStatus}: ${code}`, rawText, headers), wasiResponse: cleaned }
}

/** The columns to write back onto the (already inserted) row for an outcome. */
export function patchForOutcome(outcome: SendOutcome, nowIso: string, ctx: { retryCount: number }): Record<string, unknown> {
  switch (outcome.kind) {
    case "sent":
      return {
        status: "sent",
        wa_message_id: outcome.metaMessageId,
        wasi_message_id: outcome.wasiMessageId,
        delivery_status: "sent",
        error: null,
        wasi_response: outcome.wasiResponse,
        retry_count: ctx.retryCount,
        retried_at: nowIso,
      }
    case "accepted_no_message_id":
      // Wasi accepted it but gave us no WhatsApp id: it may well have been sent, so it is NOT retried; a human looks.
      return {
        status: "pending",
        wasi_message_id: outcome.wasiMessageId,
        error: "accepted_no_message_id",
        wasi_response: outcome.wasiResponse,
        retry_count: ctx.retryCount,
        retried_at: nowIso,
      }
    case "rejected":
      return {
        status: "failed",
        error: outcome.error,
        wasi_response: outcome.wasiResponse,
        retry_count: ctx.retryCount,
        // Terminal failures are closed out so no legacy loop re-picks them; retryable ones stay open.
        retried_at: outcome.retryable && ctx.retryCount < (outcome.code === "conflict" ? 1 : MAX_SEND_ATTEMPTS_V2) ? null : nowIso,
      }
    case "network_error":
      return outcome.unknownOutcome
        ? { status: "pending", error: "timeout_unknown_outcome", retry_count: ctx.retryCount, retried_at: nowIso }
        : { status: "failed", error: `network_error: ${redactWasiText(outcome.message)}`, retry_count: ctx.retryCount, retried_at: ctx.retryCount < MAX_SEND_ATTEMPTS_V2 ? null : nowIso }
  }
}

// ── the orchestrated send ────────────────────────────────────────────────────────────────────────────────────────────
export type TestModeVerdict = { blocked: false } | { blocked: true; reason: string }

export type CoreSendInput = {
  orgId: string
  to: string
  customerId: string | null
  /** The outbox `template` label (e.g. milestone.booked, wa.menu.menu_shown). For notifications it is also the event key. */
  template: string
  body: string
  interactive?: Record<string, unknown>
  type?: "text" | "template" | "interactive" | "media"
  refType?: string | null
  refId?: string | null
  retryCount?: number
  /** reply = answering something the customer just sent (always in-window, free text);
   *  notification = a system-initiated message: template, or free text only inside the window. */
  purpose?: "reply" | "notification"
  language?: "en" | "ta"
  vars?: Record<string, string | null | undefined>
  headerMediaUrl?: string | null
  /** The dispatcher already inserted + claimed this row; update it in place instead of inserting. */
  outboxId?: string
  /** Caller supplied template request (supplier quote PDF flow). Bypasses the mapping lookup. */
  templateSend?: { templateName: string; headerMediaUrl?: string | null; params: Record<string, string> }
}

export type CoreSendResult = {
  outboxId: string
  status: WaOutboxStatus
  waMessageId: string | null
  dispatched: boolean
  error: string | null
}

export type MappingLookup = TemplateMapping | null

export interface SendDeps {
  nowMs(): number
  getLastInboundAt(orgId: string, phone10: string): Promise<string | null>
  /** Active mapping whose Wasi template is approved in the mirror, for this event; null when none. */
  findApprovedMapping(orgId: string, eventKey: string, language: "en" | "ta"): Promise<MappingLookup>
  insertRow(row: Record<string, unknown>): Promise<string>
  updateRow(id: string, patch: Record<string, unknown>): Promise<void>
  evaluateTestMode(orgId: string, to: string): Promise<TestModeVerdict>
  logBlocked(info: { orgId: string; to: string; template: string; refType: string | null; refId: string | null; reason: string; outboxId: string }): Promise<void>
  getTransport(orgId: string): Promise<{ baseUrl: string; apiKey: string; clientId: string } | null>
  post(url: string, apiKey: string, body: unknown): Promise<{ status: number; text: string; headers: HeadersLike }>
}

function payloadFor(input: CoreSendInput, requestKind: "template" | "text" | "interactive", templateInfo?: { name: string; params: Record<string, string> }): Record<string, unknown> {
  if (requestKind === "template") return { template: templateInfo?.name, params: templateInfo?.params }
  if (requestKind === "interactive") return { body: input.body, interactive: input.interactive }
  return { body: input.body }
}

export async function executeSend(deps: SendDeps, input: CoreSendInput): Promise<CoreSendResult> {
  const retryCount = input.retryCount ?? 0
  const phone10 = last10(input.to)
  const nowIso = () => new Date(deps.nowMs()).toISOString()

  type Plan =
    | { kind: "skip"; reason: string }
    | { kind: "template"; mapping: TemplateMapping; eventName: string }
    | { kind: "direct_template"; mapping: TemplateMapping; headerMediaUrl: string | null }
    | { kind: "free_text" }

  let plan: Plan
  if (input.templateSend) {
    plan = {
      kind: "direct_template",
      mapping: { wasiTemplateName: input.templateSend.templateName, paramMap: {}, paramKeys: Object.keys(input.templateSend.params), headerType: input.templateSend.headerMediaUrl ? "DOCUMENT" : null },
      headerMediaUrl: input.templateSend.headerMediaUrl ?? null,
    }
  } else if ((input.purpose ?? "reply") === "notification") {
    const language = input.language ?? "en"
    let mapping = await deps.findApprovedMapping(input.orgId, input.template, language)
    if (!mapping && language !== "en") mapping = await deps.findApprovedMapping(input.orgId, input.template, "en")
    const inside = isInsideWindow(await deps.getLastInboundAt(input.orgId, phone10), deps.nowMs())
    const decision = decideNotificationSend({ hasApprovedTemplate: !!mapping, insideWindow: inside, hasFreeTextBody: input.body.trim() !== "" })
    if (decision === "skip_no_template") plan = { kind: "skip", reason: `no_approved_template:${input.template}_${language}` }
    else if (decision === "template" && mapping) plan = { kind: "template", mapping, eventName: input.template }
    else plan = { kind: "free_text" }
  } else {
    plan = { kind: "free_text" }
  }

  const requestKind: "template" | "text" | "interactive" =
    plan.kind === "template" || plan.kind === "direct_template" ? "template" : input.interactive ? "interactive" : "text"

  // 1. nothing may leave: record why, on the dispatcher's row if there is one.
  if (plan.kind === "skip") {
    const skipPatch = { status: "skipped_no_template", error: plan.reason, retry_count: retryCount, retried_at: nowIso(), type: "text" }
    if (input.outboxId) {
      await deps.updateRow(input.outboxId, skipPatch)
      return { outboxId: input.outboxId, status: "skipped_no_template", waMessageId: null, dispatched: false, error: plan.reason }
    }
    const id = await deps.insertRow(baseRow(input, "skipped_no_template", requestKind, payloadFor(input, "text"), nowIso, plan.reason))
    return { outboxId: id, status: "skipped_no_template", waMessageId: null, dispatched: false, error: plan.reason }
  }

  // 2. build the request before touching the table, so a bad param never leaves a pending row behind.
  const transport = await deps.getTransport(input.orgId)
  let templateRequest: Extract<TemplateRequestResult, { ok: true }> | null = null
  let templateError: string | null = null
  if (plan.kind === "template" || plan.kind === "direct_template") {
    const vars: Record<string, string | null | undefined> =
      plan.kind === "direct_template" ? { ...(input.templateSend?.params ?? {}) } : { ...(input.vars ?? {}) }
    const r = buildTemplateRequest({
      clientId: transport?.clientId ?? "",
      to: input.to,
      mapping: plan.mapping,
      vars,
      headerMediaUrl: plan.kind === "direct_template" ? plan.headerMediaUrl : (input.headerMediaUrl ?? input.vars?.pdf_url ?? null),
    })
    if (r.ok) templateRequest = r
    else templateError = r.error
  }

  // 3. insert-first: the row exists before the HTTP call, so a crash can never lose the attempt.
  const templateInfo = templateRequest ? { name: templateRequest.body.template, params: templateRequest.params } : undefined
  const claimedPayload = payloadFor(input, requestKind, templateInfo)
  let outboxId = input.outboxId
  if (!outboxId) {
    outboxId = await deps.insertRow(baseRow(input, "pending", requestKind, claimedPayload, nowIso, null))
  } else {
    await deps.updateRow(outboxId, { type: requestKind, template_name: templateInfo?.name ?? null, template_params: templateInfo?.params ?? null })
  }

  if (templateError) {
    await deps.updateRow(outboxId, { status: "failed", error: templateError, retry_count: retryCount, retried_at: nowIso() })
    return { outboxId, status: "failed", waMessageId: null, dispatched: false, error: templateError }
  }

  // 4. F-08 test-mode gate: after the row exists, before any HTTP; terminal (retried_at set), same single row.
  const verdict = await deps.evaluateTestMode(input.orgId, input.to)
  if (verdict.blocked) {
    const error = `blocked: ${verdict.reason}`
    await deps.updateRow(outboxId, { status: "failed", error, retry_count: retryCount, retried_at: nowIso() })
    await deps.logBlocked({ orgId: input.orgId, to: input.to, template: input.template, refType: input.refType ?? null, refId: input.refId ?? null, reason: verdict.reason, outboxId })
    return { outboxId, status: "failed", waMessageId: null, dispatched: false, error }
  }

  // 5. stub mode: nothing is configured to send. The row stays pending (never 'sent').
  if (!transport) {
    const error = "not_dispatched_stub"
    await deps.updateRow(outboxId, { error, retry_count: retryCount })
    return { outboxId, status: "pending", waMessageId: null, dispatched: false, error }
  }

  // 6. the request
  let requestBody: unknown
  if (templateRequest) {
    requestBody = templateRequest.body
  } else {
    const base = { client_id: transport.clientId, to: toWasiNumber(input.to), type: input.interactive ? "interactive" : "text", body: input.body }
    requestBody = input.interactive ? { ...base, ...input.interactive } : base
  }

  let outcome: SendOutcome
  try {
    const res = await deps.post(`${transport.baseUrl}/api/v1/messages`, transport.apiKey, requestBody)
    outcome = classifyWasiResponse(res.status, res.text, res.headers)
  } catch (e) {
    const name = e instanceof Error ? e.name : ""
    const message = e instanceof Error ? e.message : String(e)
    // A timeout, or any error that does not PROVE the request never left, may have reached Wasi: outcome unknown, never auto-resent.
    outcome = { kind: "network_error", message, unknownOutcome: name === "TimeoutError" || name === "AbortError" || !isPreSendNetworkError(e) }
  }

  const patch = patchForOutcome(outcome, nowIso(), { retryCount })
  await deps.updateRow(outboxId, patch)

  const status = patch.status as WaOutboxStatus
  return {
    outboxId,
    status,
    waMessageId: outcome.kind === "sent" ? outcome.metaMessageId : null,
    dispatched: outcome.kind === "sent",
    error: (patch.error as string | null) ?? null,
  }
}

function baseRow(
  input: CoreSendInput,
  status: WaOutboxStatus,
  requestKind: "template" | "text" | "interactive",
  payload: Record<string, unknown>,
  nowIso: () => string,
  error: string | null
): Record<string, unknown> {
  return {
    org_id: input.orgId,
    direction: "outbound",
    to_mobile: input.to,
    customer_id: input.customerId,
    template: input.template,
    type: requestKind,
    payload,
    ref_type: input.refType ?? null,
    ref_id: input.refId ?? null,
    status,
    error,
    retry_count: input.retryCount ?? 0,
    claimed_at: status === "pending" ? nowIso() : null,
    retried_at: status === "skipped_no_template" ? nowIso() : null,
  }
}
