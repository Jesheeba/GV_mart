import { describe, expect, it } from "vitest"
import {
  WINDOW_MS,
  WINDOW_SAFETY_MARGIN_MS,
  buildTemplateRequest,
  classifyWasiResponse,
  decideNotificationSend,
  executeSend,
  isInsideWindow,
  last10,
  patchForOutcome,
  sanitizeForStorage,
  toWasiNumber,
  type CoreSendInput,
  type SendDeps,
  type TemplateMapping,
} from "./wa-send-core"

// Synthetic values only: no real number, no real wamid (a wamid is base64 of the recipient's number).
const FAKE_WAMID = "wamid.SYNTHETICxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
const WASI_UUID = "675663a5-4200-4056-940f-ebc52e2b6fde"
const NOW = Date.parse("2026-10-12T12:00:00Z")

const headers = { get: (n: string) => (n.toLowerCase() === "content-type" ? "application/json" : null) }

const mappingShipping: TemplateMapping = { wasiTemplateName: "shipping_update", paramMap: { name: "name" }, paramKeys: ["name"], headerType: null }
const mappingDoc: TemplateMapping = { wasiTemplateName: "invoice_document", paramMap: {}, paramKeys: ["customer_name", "invoice_date", "invoice_number"], headerType: "DOCUMENT" }

describe("number and window helpers", () => {
  it("normalises to the last ten digits and to Wasi's 91 format", () => {
    expect(last10("+91 90000-00001")).toBe("9000000001")
    expect(last10("919000000001")).toBe("9000000001")
    expect(toWasiNumber("9000000001")).toBe("919000000001")
    expect(toWasiNumber("919000000001")).toBe("919000000001")
  })

  it("is inside the window only before 24h minus the safety margin", () => {
    const at = (msAgo: number) => new Date(NOW - msAgo).toISOString()
    expect(isInsideWindow(at(60_000), NOW)).toBe(true)
    expect(isInsideWindow(at(WINDOW_MS - WINDOW_SAFETY_MARGIN_MS - 1_000), NOW)).toBe(true)
    expect(isInsideWindow(at(WINDOW_MS - WINDOW_SAFETY_MARGIN_MS + 1_000), NOW)).toBe(false)
    expect(isInsideWindow(at(WINDOW_MS + 1), NOW)).toBe(false)
    expect(isInsideWindow(null, NOW)).toBe(false)
    expect(isInsideWindow("not a date", NOW)).toBe(false)
  })
})

describe("decideNotificationSend (system notifications: template, or free text only inside the window)", () => {
  it("uses an approved template whether or not the window is open", () => {
    expect(decideNotificationSend({ hasApprovedTemplate: true, insideWindow: false, hasFreeTextBody: false })).toBe("template")
    expect(decideNotificationSend({ hasApprovedTemplate: true, insideWindow: true, hasFreeTextBody: true })).toBe("template")
  })
  it("allows free text only inside the window", () => {
    expect(decideNotificationSend({ hasApprovedTemplate: false, insideWindow: true, hasFreeTextBody: true })).toBe("free_text")
    expect(decideNotificationSend({ hasApprovedTemplate: false, insideWindow: false, hasFreeTextBody: true })).toBe("skip_no_template")
  })
  it("skips when there is nothing sendable at all", () => {
    expect(decideNotificationSend({ hasApprovedTemplate: false, insideWindow: true, hasFreeTextBody: false })).toBe("skip_no_template")
  })
})

describe("buildTemplateRequest", () => {
  it("sends template + params and never body or type text", () => {
    const r = buildTemplateRequest({ clientId: "client-x", to: "9000000001", mapping: mappingShipping, vars: { name: "GV Mart Test" } })
    expect(r.ok).toBe(true)
    if (!r.ok) return
    expect(r.body).toEqual({ client_id: "client-x", to: "919000000001", type: "template", template: "shipping_update", params: { name: "GV Mart Test" } })
    expect("body" in r.body).toBe(false)
    expect("headerMediaUrl" in r.body).toBe(false)
  })

  it("maps wasi param names to variable keys", () => {
    const mapping: TemplateMapping = { wasiTemplateName: "appointment_reminder", paramMap: { customer_name: "name", appointment_time: "slot" }, paramKeys: ["customer_name", "appointment_time"], headerType: null }
    const r = buildTemplateRequest({ clientId: "c", to: "9000000001", mapping, vars: { name: "A", slot: "12 Oct, 3:30 PM" } })
    expect(r.ok && r.body.params).toEqual({ customer_name: "A", appointment_time: "12 Oct, 3:30 PM" })
  })

  it("fails locally on a missing or blank param instead of calling Wasi", () => {
    expect(buildTemplateRequest({ clientId: "c", to: "9000000001", mapping: mappingShipping, vars: {} })).toEqual({ ok: false, error: "missing_param:name" })
    expect(buildTemplateRequest({ clientId: "c", to: "9000000001", mapping: mappingShipping, vars: { name: "  " } })).toEqual({ ok: false, error: "missing_param:name" })
    expect(buildTemplateRequest({ clientId: "c", to: "9000000001", mapping: mappingShipping, vars: { name: null } })).toEqual({ ok: false, error: "missing_param:name" })
  })

  it("adds headerMediaUrl only for a media-header template, and requires it then", () => {
    const vars = { customer_name: "A", invoice_date: "12 Oct 2026", invoice_number: "AB12CD34" }
    const noMedia = buildTemplateRequest({ clientId: "c", to: "9000000001", mapping: mappingDoc, vars })
    expect(noMedia).toEqual({ ok: false, error: "missing_header_media" })
    const withMedia = buildTemplateRequest({ clientId: "c", to: "9000000001", mapping: mappingDoc, vars, headerMediaUrl: "https://example.invalid/a.pdf" })
    expect(withMedia.ok && withMedia.body.headerMediaUrl).toBe("https://example.invalid/a.pdf")
    const textHeader: TemplateMapping = { ...mappingShipping, headerType: "TEXT" }
    const r = buildTemplateRequest({ clientId: "c", to: "9000000001", mapping: textHeader, vars: { name: "A" }, headerMediaUrl: "https://example.invalid/a.pdf" })
    expect(r.ok && "headerMediaUrl" in r.body).toBe(false)
  })
})

describe("classifyWasiResponse", () => {
  it("201 with meta_message_id is the send confirmation; the WhatsApp id is meta_message_id, not id", () => {
    const o = classifyWasiResponse(201, JSON.stringify({ id: WASI_UUID, chat_id: "chat-1", client_id: "c", status: "sent", meta_message_id: FAKE_WAMID, delivered_at: null }), headers)
    expect(o.kind).toBe("sent")
    if (o.kind !== "sent") return
    expect(o.metaMessageId).toBe(FAKE_WAMID)
    expect(o.wasiMessageId).toBe(WASI_UUID)
    // the stored copy has no wamid and no client id
    expect(JSON.stringify(o.wasiResponse)).not.toContain("wamid")
    expect(JSON.stringify(o.wasiResponse)).not.toContain("SYNTHETIC")
    expect(o.wasiResponse).not.toHaveProperty("client_id")
  })

  it("201 without meta_message_id is accepted_no_message_id (stays pending, a human looks)", () => {
    const o = classifyWasiResponse(201, JSON.stringify({ id: WASI_UUID, status: "sent" }), headers)
    expect(o.kind).toBe("accepted_no_message_id")
    const patch = patchForOutcome(o, "2026-10-12T12:00:00.000Z", { retryCount: 0 })
    expect(patch.status).toBe("pending")
    expect(patch.error).toBe("accepted_no_message_id")
    expect(patch.wasi_message_id).toBe(WASI_UUID)
    expect(patch).not.toHaveProperty("wa_message_id")
  })

  it("201 whose own status is failed is a rejection", () => {
    const o = classifyWasiResponse(201, JSON.stringify({ id: WASI_UUID, status: "failed", meta_message_id: FAKE_WAMID }), headers)
    expect(o.kind).toBe("rejected")
  })

  for (const code of ["session_window_closed", "consent_required", "media_resolution_failed", "auth_code_invalid", "auth_code_required", "plan_limit_reached", "waba_not_connected", "conflict"]) {
    it(`409 ${code}: classified, nothing sent, ${code === "conflict" ? "retryable once" : "terminal"}`, () => {
      const o = classifyWasiResponse(409, JSON.stringify({ error: { code, message: "x" } }), headers)
      expect(o.kind).toBe("rejected")
      if (o.kind !== "rejected") return
      expect(o.code).toBe(code)
      expect(o.httpStatus).toBe(409)
      expect(o.retryable).toBe(code === "conflict")
      expect(o.error.startsWith(`409: ${code}`)).toBe(true)
      const patch = patchForOutcome(o, "2026-10-12T12:00:00.000Z", { retryCount: 0 })
      expect(patch.status).toBe("failed")
      // terminal failures are closed out (retried_at set) so no loop re-picks them; conflict stays open for its one retry
      expect(patch.retried_at === null).toBe(code === "conflict")
    })
  }

  it("conflict is not retried a second time", () => {
    const o = classifyWasiResponse(409, JSON.stringify({ error: { code: "conflict" } }), headers)
    expect(patchForOutcome(o, "2026-10-12T12:00:00.000Z", { retryCount: 1 }).retried_at).toBe("2026-10-12T12:00:00.000Z")
  })

  it("502 keeps the whole metaError object and the fbtrace_id", () => {
    const meta = { message: "Message undeliverable", type: "OAuthException", code: 131026, error_data: { details: "recipient unavailable" } }
    const o = classifyWasiResponse(502, JSON.stringify({ error: { code: "whatsapp_error" }, metaError: meta, fbtrace_id: "ABCtrace123" }), headers)
    expect(o.kind).toBe("rejected")
    if (o.kind !== "rejected") return
    expect(o.code).toBe("whatsapp_rejected")
    expect(o.retryable).toBe(false)
    expect(o.wasiResponse?.fbtrace_id).toBe("ABCtrace123")
    expect(o.wasiResponse?.metaError).toMatchObject({ code: 131026, type: "OAuthException", message: "Message undeliverable" })
  })

  it("other statuses are terminal failures with the cleaned body in the error", () => {
    const o = classifyWasiResponse(403, JSON.stringify({ error: { code: "client_id_mismatch" } }), headers)
    expect(o.kind === "rejected" && o.code).toBe("client_id_mismatch")
    const odd = classifyWasiResponse(500, "<html>boom</html>", headers)
    expect(odd.kind === "rejected" && odd.code).toBe("http_500")
  })

  it("never leaks a wamid or a full phone number into the stored error", () => {
    const raw = JSON.stringify({ error: { code: "conflict", message: `to 919000000001 ref ${FAKE_WAMID}` } })
    const o = classifyWasiResponse(409, raw, headers)
    expect(o.kind === "rejected" && o.error).not.toContain("919000000001")
    expect(o.kind === "rejected" && o.error).not.toContain("SYNTHETIC")
  })
})

describe("sanitizeForStorage", () => {
  it("drops recipient/credential fields and masks strings", () => {
    const out = sanitizeForStorage({ id: WASI_UUID, to: "919000000001", meta_message_id: FAKE_WAMID, note: `call 919000000001 about ${FAKE_WAMID}`, nested: { wa_id: "x", ok: 1 } }) as Record<string, unknown>
    expect(out).toHaveProperty("id", WASI_UUID)
    expect(out).not.toHaveProperty("to")
    expect(out).not.toHaveProperty("meta_message_id")
    expect(JSON.stringify(out)).not.toContain("919000000001")
    expect(JSON.stringify(out)).not.toContain("SYNTHETIC")
    expect(out.nested).toEqual({ ok: 1 })
  })
})

describe("patchForOutcome: network outcomes", () => {
  it("a connect failure is a retryable failure; a timeout after the request left is unknown and never resent", () => {
    const connect = patchForOutcome({ kind: "network_error", message: "fetch failed", unknownOutcome: false }, "t", { retryCount: 0 })
    expect(connect.status).toBe("failed")
    expect(String(connect.error).startsWith("network_error")).toBe(true)
    expect(connect.retried_at).toBeNull()
    const timeout = patchForOutcome({ kind: "network_error", message: "timed out", unknownOutcome: true }, "t", { retryCount: 0 })
    expect(timeout.status).toBe("pending")
    expect(timeout.error).toBe("timeout_unknown_outcome")
    expect(timeout.retried_at).toBe("t")
  })
})

// ── executeSend with an in-memory store ────────────────────────────────────────────────────────────────────────────
type Call = { op: string; detail?: unknown }

function makeDeps(opts: {
  lastInboundAt?: string | null
  mapping?: TemplateMapping | null
  mappingByLang?: Record<string, TemplateMapping | null>
  testMode?: { blocked: false } | { blocked: true; reason: string }
  transport?: boolean
  response?: { status: number; text: string } | Error
}) {
  const calls: Call[] = []
  const rows = new Map<string, Record<string, unknown>>()
  let seq = 0
  const deps: SendDeps = {
    nowMs: () => NOW,
    async getLastInboundAt() {
      return opts.lastInboundAt ?? null
    },
    async findApprovedMapping(_org, _event, language) {
      calls.push({ op: "findMapping", detail: language })
      if (opts.mappingByLang) return opts.mappingByLang[language] ?? null
      return opts.mapping ?? null
    },
    async insertRow(row) {
      const id = `row-${++seq}`
      rows.set(id, { ...row })
      calls.push({ op: "insert", detail: { status: row.status } })
      return id
    },
    async updateRow(id, patch) {
      rows.set(id, { ...(rows.get(id) ?? {}), ...patch })
      calls.push({ op: "update", detail: patch })
    },
    async evaluateTestMode() {
      return opts.testMode ?? { blocked: false }
    },
    async logBlocked(info) {
      calls.push({ op: "logBlocked", detail: info.reason })
    },
    async getTransport() {
      return opts.transport === false ? null : { baseUrl: "https://wasi.invalid", apiKey: "key-x", clientId: "client-x" }
    },
    async post(_url, _key, body) {
      calls.push({ op: "post", detail: body })
      if (opts.response instanceof Error) throw opts.response
      const r = opts.response ?? { status: 201, text: JSON.stringify({ id: WASI_UUID, status: "sent", meta_message_id: FAKE_WAMID }) }
      return { status: r.status, text: r.text, headers }
    },
  }
  return { deps, calls, rows }
}

const base: CoreSendInput = {
  orgId: "org-1",
  to: "9000000001",
  customerId: "cust-1",
  template: "milestone.booked",
  body: "Hi, your service is booked.",
  refType: "service_ticket",
  refId: "tk-1",
  purpose: "notification",
}

describe("executeSend", () => {
  it("inserts the row BEFORE the HTTP call, then updates the same row (one row per message)", async () => {
    const { deps, calls, rows } = makeDeps({ mapping: mappingShipping })
    const r = await executeSend(deps, { ...base, vars: { name: "A" } })
    const ops = calls.map((c) => c.op)
    expect(ops.indexOf("insert")).toBeGreaterThanOrEqual(0)
    expect(ops.indexOf("insert")).toBeLessThan(ops.indexOf("post"))
    expect(calls.filter((c) => c.op === "insert")).toHaveLength(1)
    expect(r.status).toBe("sent")
    expect(r.dispatched).toBe(true)
    expect(rows.size).toBe(1)
    const row = [...rows.values()][0]
    expect(row.status).toBe("sent")
    expect(row.wa_message_id).toBe(FAKE_WAMID)
    expect(row.wasi_message_id).toBe(WASI_UUID)
    expect(row.delivery_status).toBe("sent")
  })

  it("a template row sends template + params, never body or type text", async () => {
    const { deps, calls } = makeDeps({ mapping: mappingShipping })
    await executeSend(deps, { ...base, vars: { name: "GV Mart Test" } })
    const post = calls.find((c) => c.op === "post")!.detail as Record<string, unknown>
    expect(post.type).toBe("template")
    expect(post.template).toBe("shipping_update")
    expect(post.params).toEqual({ name: "GV Mart Test" })
    expect(post).not.toHaveProperty("body")
  })

  it("outside the window with no approved template: skipped_no_template, nothing is sent", async () => {
    const { deps, calls, rows } = makeDeps({ mapping: null, lastInboundAt: new Date(NOW - 3 * WINDOW_MS).toISOString() })
    const r = await executeSend(deps, base)
    expect(calls.some((c) => c.op === "post")).toBe(false)
    expect(r.status).toBe("skipped_no_template")
    expect(r.dispatched).toBe(false)
    expect([...rows.values()][0].status).toBe("skipped_no_template")
    expect(String(r.error)).toContain("no_approved_template:milestone.booked_en")
  })

  it("skipped on the dispatcher's own row updates it in place (no second row)", async () => {
    const { deps, rows } = makeDeps({ mapping: null })
    rows.set("claimed-1", { status: "pending", claimed_at: "t" })
    const r = await executeSend(deps, { ...base, outboxId: "claimed-1" })
    expect(r.outboxId).toBe("claimed-1")
    expect(rows.size).toBe(1)
    expect(rows.get("claimed-1")?.status).toBe("skipped_no_template")
  })

  it("inside the window with no template: free text is allowed", async () => {
    const { deps, calls } = makeDeps({ mapping: null, lastInboundAt: new Date(NOW - 60_000).toISOString() })
    const r = await executeSend(deps, base)
    const post = calls.find((c) => c.op === "post")!.detail as Record<string, unknown>
    expect(post.type).toBe("text")
    expect(post.body).toBe(base.body)
    expect(r.status).toBe("sent")
  })

  it("a bot reply is always free text and never needs a template", async () => {
    const { deps, calls } = makeDeps({ mapping: null })
    await executeSend(deps, { ...base, purpose: "reply", template: "wa.menu.menu_shown" })
    expect(calls.some((c) => c.op === "findMapping")).toBe(false)
    expect((calls.find((c) => c.op === "post")!.detail as Record<string, unknown>).type).toBe("text")
  })

  it("an interactive reply keeps Wasi's flat interactive shape", async () => {
    const { deps, calls } = makeDeps({})
    await executeSend(deps, { ...base, purpose: "reply", interactive: { buttons: [{ id: "a", title: "A" }] } })
    const post = calls.find((c) => c.op === "post")!.detail as Record<string, unknown>
    expect(post.type).toBe("interactive")
    expect(post.buttons).toBeTruthy()
  })

  it("falls back to the English template when the customer's language has none", async () => {
    const { deps, calls } = makeDeps({ mappingByLang: { ta: null, en: mappingShipping } })
    const r = await executeSend(deps, { ...base, language: "ta", vars: { name: "A" } })
    expect(calls.filter((c) => c.op === "findMapping").map((c) => c.detail)).toEqual(["ta", "en"])
    expect(r.status).toBe("sent")
  })

  it("a missing variable fails the row locally without calling Wasi", async () => {
    const { deps, calls, rows } = makeDeps({ mapping: mappingShipping })
    const r = await executeSend(deps, { ...base, vars: {} })
    expect(calls.some((c) => c.op === "post")).toBe(false)
    expect(r.status).toBe("failed")
    expect(r.error).toBe("missing_param:name")
    expect([...rows.values()][0].retried_at).toBeTruthy()
  })

  it("F-08 test mode: blocked after the row exists, same row updated to failed, audit logged, nothing sent", async () => {
    const { deps, calls, rows } = makeDeps({ mapping: mappingShipping, testMode: { blocked: true, reason: "test_mode_not_allow_listed" } })
    const r = await executeSend(deps, { ...base, vars: { name: "A" } })
    expect(calls.some((c) => c.op === "post")).toBe(false)
    expect(calls.some((c) => c.op === "logBlocked")).toBe(true)
    expect(rows.size).toBe(1)
    const row = [...rows.values()][0]
    expect(row.status).toBe("failed")
    expect(row.error).toBe("blocked: test_mode_not_allow_listed")
    expect(row.retried_at).toBeTruthy()
    expect(r.dispatched).toBe(false)
  })

  it("stub mode (no transport): row stays pending, never sent", async () => {
    const { deps, rows } = makeDeps({ mapping: mappingShipping, transport: false })
    const r = await executeSend(deps, { ...base, vars: { name: "A" } })
    expect(r.status).toBe("pending")
    expect(r.dispatched).toBe(false)
    expect([...rows.values()][0].error).toBe("not_dispatched_stub")
    expect([...rows.values()][0].status).toBe("pending")
  })

  it("409 session_window_closed: row failed, terminal, error carries the code", async () => {
    const { deps, rows } = makeDeps({ mapping: mappingShipping, response: { status: 409, text: JSON.stringify({ error: { code: "session_window_closed" } }) } })
    const r = await executeSend(deps, { ...base, vars: { name: "A" } })
    expect(r.status).toBe("failed")
    const row = [...rows.values()][0]
    expect(String(row.error)).toContain("session_window_closed")
    expect(row.retried_at).toBeTruthy()
    expect(row.wa_message_id).toBeUndefined()
  })

  it("502 with metaError is stored whole on the row", async () => {
    const { deps, rows } = makeDeps({
      mapping: mappingShipping,
      response: { status: 502, text: JSON.stringify({ error: { code: "x" }, metaError: { code: 131026, message: "undeliverable" }, fbtrace_id: "TRACE1" }) },
    })
    await executeSend(deps, { ...base, vars: { name: "A" } })
    const stored = [...rows.values()][0].wasi_response as Record<string, unknown>
    expect(stored.fbtrace_id).toBe("TRACE1")
    expect(stored.metaError).toMatchObject({ code: 131026 })
  })

  it("network error before the request is sent (DNS / connect): failed and retryable", async () => {
    const { deps, rows } = makeDeps({ mapping: mappingShipping, response: new Error("error sending request for url: client error (Connect): dns error: failed to lookup address") })
    const r = await executeSend(deps, { ...base, vars: { name: "A" } })
    expect(r.status).toBe("failed")
    const row = [...rows.values()][0]
    expect(String(row.error).startsWith("network_error")).toBe(true)
    expect(row.retried_at).toBeNull()
  })

  it("a reset or an unknown exception after the request may have left: unknown outcome, pending, never auto-resent", async () => {
    for (const msg of ["fetch failed", "connection reset by peer", "unexpected EOF during handshake"]) {
      const { deps, rows } = makeDeps({ mapping: mappingShipping, response: new Error(msg) })
      const r = await executeSend(deps, { ...base, vars: { name: "A" } })
      expect(r.status, msg).toBe("pending")
      const row = [...rows.values()][0]
      expect(row.error, msg).toBe("timeout_unknown_outcome")
      expect(row.retried_at, msg).toBeTruthy()
    }
  })

  it("timeout: outcome unknown, row stays pending and is not auto-resent", async () => {
    const timeout = Object.assign(new Error("timed out"), { name: "TimeoutError" })
    const { deps, rows } = makeDeps({ mapping: mappingShipping, response: timeout })
    const r = await executeSend(deps, { ...base, vars: { name: "A" } })
    expect(r.status).toBe("pending")
    expect([...rows.values()][0].error).toBe("timeout_unknown_outcome")
    expect([...rows.values()][0].retried_at).toBeTruthy()
  })

  it("201 without meta_message_id: stays pending with an error note", async () => {
    const { deps, rows } = makeDeps({ mapping: mappingShipping, response: { status: 201, text: JSON.stringify({ id: WASI_UUID, status: "sent" }) } })
    const r = await executeSend(deps, { ...base, vars: { name: "A" } })
    expect(r.status).toBe("pending")
    expect(r.dispatched).toBe(false)
    expect([...rows.values()][0].error).toBe("accepted_no_message_id")
  })

  it("a document-header template sends headerMediaUrl from vars.pdf_url", async () => {
    const { deps, calls } = makeDeps({ mapping: mappingDoc })
    await executeSend(deps, { ...base, template: "milestone.invoice", vars: { customer_name: "A", invoice_date: "12 Oct 2026", invoice_number: "AB12CD34", pdf_url: "https://example.invalid/i.pdf" } })
    const post = calls.find((c) => c.op === "post")!.detail as Record<string, unknown>
    expect(post.headerMediaUrl).toBe("https://example.invalid/i.pdf")
    expect(post.type).toBe("template")
  })

  it("the legacy templateSend (supplier quote PDF) goes through the same template request", async () => {
    const { deps, calls } = makeDeps({})
    await executeSend(deps, { ...base, purpose: "notification", templateSend: { templateName: "po_quote_request_doc_v3", headerMediaUrl: "https://example.invalid/q.pdf", params: { supplier_name: "S" } } })
    const post = calls.find((c) => c.op === "post")!.detail as Record<string, unknown>
    expect(post).toMatchObject({ type: "template", template: "po_quote_request_doc_v3", params: { supplier_name: "S" }, headerMediaUrl: "https://example.invalid/q.pdf" })
    expect(post).not.toHaveProperty("body")
  })

  it("no log or stored field ever contains the wamid", async () => {
    const { deps, rows } = makeDeps({ mapping: mappingShipping })
    await executeSend(deps, { ...base, vars: { name: "A" } })
    const row = [...rows.values()][0]
    // the ONLY place the id may live is wa_message_id
    const { wa_message_id, ...rest } = row
    expect(wa_message_id).toBe(FAKE_WAMID)
    expect(JSON.stringify(rest)).not.toContain("SYNTHETIC")
  })
})
