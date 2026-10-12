import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { isDispatchV2Enabled, resetDispatchV2FlagCache, sendMessage } from "./whatsapp"

// Synthetic only: no real number, no real wamid.
const FAKE_WAMID = "wamid.SYNTHETICxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
const ORG = "org-1"

type Row = Record<string, unknown>

/** A tiny chainable stand-in for the supabase-js query builder, covering exactly the shapes whatsapp.ts uses. */
function fakeAdmin(cfg: { v2: boolean; testMode?: boolean; allowed?: string[]; lastInbound?: string | null; templates?: Row[]; mapping?: Row | null; creds?: boolean }) {
  const outbox = new Map<string, Row>()
  const ops: { op: string; table: string; detail?: unknown }[] = []
  let seq = 0

  const reads: Record<string, () => unknown> = {
    settings: () => ({ wa_dispatch_v2_enabled: cfg.v2, wa_test_mode_enabled: cfg.testMode ?? false, wa_test_allowed_numbers: cfg.allowed ?? [] }),
    whatsapp_contacts: () => (cfg.lastInbound ? { last_inbound_at: cfg.lastInbound } : null),
    whatsapp_event_templates: () => cfg.mapping ?? null,
    whatsapp_wasi_templates: () => cfg.templates ?? [],
    whatsapp_provider_credentials: () => (cfg.creds === false ? null : { client_id: "client-x", api_key: "key-x" }),
  }

  const from = (table: string) => {
    const b: Record<string, unknown> = {}
    const chain = () => b
    for (const m of ["select", "eq", "is", "in", "order", "limit", "abortSignal"]) b[m] = chain
    b.maybeSingle = async () => ({ data: reads[table]?.() ?? null, error: null })
    // list-style reads (whatsapp_wasi_templates returns an array) resolve when awaited
    b.then = (resolve: (v: unknown) => unknown) => resolve({ data: reads[table]?.() ?? null, error: null })
    b.insert = (row: Row) => {
      const id = `row-${++seq}`
      if (table === "whatsapp_outbox") outbox.set(id, { ...row })
      ops.push({ op: "insert", table, detail: { ...row } })
      return { select: () => ({ single: async () => ({ data: { id }, error: null }) }), then: (r: (v: unknown) => unknown) => r({ error: null }) }
    }
    b.update = (patch: Row) => ({
      eq: async (_col: string, id: string) => {
        if (table === "whatsapp_outbox") outbox.set(id, { ...(outbox.get(id) ?? {}), ...patch })
        ops.push({ op: "update", table, detail: { id, ...patch } })
        return { error: null }
      },
    })
    return b
  }
  return { admin: { from } as never, outbox, ops }
}

const fetchMock = vi.fn()
let env: Record<string, string | undefined>

beforeEach(() => {
  env = { WASI_API_BASE_URL: undefined }
  vi.stubGlobal("Deno", { env: { get: (k: string) => env[k] } })
  vi.stubGlobal("fetch", fetchMock)
  fetchMock.mockReset()
  resetDispatchV2FlagCache()
})
afterEach(() => {
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
})

const input = { orgId: ORG, to: "9000000001", customerId: "c-1", template: "milestone.booked", body: "Hi, your service is booked.", refType: "service_ticket", refId: "tk-1" }

describe("sendMessage routing by settings.wa_dispatch_v2_enabled", () => {
  it("reads the flag from settings and defaults to legacy on any read problem", async () => {
    const { admin } = fakeAdmin({ v2: true })
    expect(await isDispatchV2Enabled(admin, ORG)).toBe(true)
    resetDispatchV2FlagCache()
    const broken = { from: () => ({ select: () => ({ eq: () => ({ abortSignal: () => ({ maybeSingle: async () => ({ data: null, error: { message: "boom" } }) }) }) }) }) } as never
    expect(await isDispatchV2Enabled(broken, ORG)).toBe(false)
  })

  it("flag OFF: today's behaviour exactly: one insert after the send, optimistic 'sent' in stub mode", async () => {
    const { admin, ops, outbox } = fakeAdmin({ v2: false })
    const r = await sendMessage(admin, input)
    const inserts = ops.filter((o) => o.table === "whatsapp_outbox" && o.op === "insert")
    expect(inserts).toHaveLength(1)
    expect([...outbox.values()][0].status).toBe("sent")
    expect(r.dispatched).toBe(false)
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it("flag ON in stub mode: row is inserted pending and stays pending (never 'sent')", async () => {
    const { admin, outbox } = fakeAdmin({ v2: true })
    const r = await sendMessage(admin, { ...input, purpose: "reply" })
    const row = [...outbox.values()][0]
    expect(row.status).toBe("pending")
    expect(row.error).toBe("not_dispatched_stub")
    expect(r.dispatched).toBe(false)
    expect(r.status).toBe("pending")
  })

  it("flag ON, real transport, approved template: template request, wamid stored, nothing logged with it", async () => {
    env.WASI_API_BASE_URL = "https://wasi.invalid"
    fetchMock.mockResolvedValue({
      status: 201,
      text: async () => JSON.stringify({ id: "wasi-uuid", status: "sent", meta_message_id: FAKE_WAMID }),
      headers: { get: () => "application/json" },
    })
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => {})
    const errSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    const { admin, outbox } = fakeAdmin({
      v2: true,
      mapping: { wasi_template_name: "shipping_update", param_map: { name: "name" } },
      templates: [{ status: "approved", header_type: null, param_keys: ["name"] }],
    })
    const r = await sendMessage(admin, { ...input, purpose: "notification", language: "en", vars: { name: "GV Mart Test" } })
    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0]
    expect(url).toBe("https://wasi.invalid/api/v1/messages")
    expect(JSON.parse(init.body)).toEqual({ client_id: "client-x", to: "919000000001", type: "template", template: "shipping_update", params: { name: "GV Mart Test" } })
    expect(init.headers.Authorization).toBe("Bearer key-x")
    const row = [...outbox.values()][0]
    expect(row.status).toBe("sent")
    expect(row.wa_message_id).toBe(FAKE_WAMID)
    expect(row.wasi_message_id).toBe("wasi-uuid")
    expect(r.waMessageId).toBe(FAKE_WAMID)
    const logged = JSON.stringify([...logSpy.mock.calls, ...errSpy.mock.calls])
    expect(logged).not.toContain("SYNTHETIC")
  })

  it("flag ON, notification with no approved template and no window: skipped, Wasi never called", async () => {
    env.WASI_API_BASE_URL = "https://wasi.invalid"
    const { admin, outbox } = fakeAdmin({ v2: true, mapping: null })
    const r = await sendMessage(admin, { ...input, purpose: "notification" })
    expect(fetchMock).not.toHaveBeenCalled()
    expect(r.status).toBe("skipped_no_template")
    expect([...outbox.values()][0].status).toBe("skipped_no_template")
  })

  it("flag ON: a name that exists in two languages on Wasi is never used (their arbitrary-pick bug)", async () => {
    env.WASI_API_BASE_URL = "https://wasi.invalid"
    const { admin } = fakeAdmin({
      v2: true,
      mapping: { wasi_template_name: "po_quote_request_doc_v3", param_map: {} },
      templates: [
        { status: "approved", header_type: "DOCUMENT", param_keys: ["supplier_name"] },
        { status: "approved", header_type: "DOCUMENT", param_keys: ["supplier_name"] },
      ],
    })
    const r = await sendMessage(admin, { ...input, template: "po.quote_request", purpose: "notification", body: "" })
    expect(fetchMock).not.toHaveBeenCalled()
    expect(r.status).toBe("skipped_no_template")
  })

  it("flag ON, F-08 test mode: a non-listed number is blocked on the same row and nothing is sent", async () => {
    env.WASI_API_BASE_URL = "https://wasi.invalid"
    const { admin, outbox } = fakeAdmin({
      v2: true,
      testMode: true,
      allowed: ["9111111111"],
      mapping: { wasi_template_name: "shipping_update", param_map: { name: "name" } },
      templates: [{ status: "approved", header_type: null, param_keys: ["name"] }],
    })
    const r = await sendMessage(admin, { ...input, purpose: "notification", vars: { name: "A" } })
    expect(fetchMock).not.toHaveBeenCalled()
    expect(outbox.size).toBe(1)
    expect([...outbox.values()][0].status).toBe("failed")
    expect(String([...outbox.values()][0].error)).toBe("blocked: test_mode_not_allow_listed")
    expect(r.dispatched).toBe(false)
  })
})
