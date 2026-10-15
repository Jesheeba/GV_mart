import { readFileSync } from "node:fs"
import { join } from "node:path"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { resetDispatchV2FlagCache, sendMessage } from "./whatsapp"

// Design B: what a BLOCKED initiated send leaves behind, and why the scheduled-tasks loops cannot flood on it.
// Synthetic numbers only.
const LISTED = "9000000001"
const OTHER = "9111111111"

type Row = Record<string, unknown>

function fakeAdmin(cfg: { onlyAllowlisted?: boolean; list?: string[] } = {}) {
  const inserts: { table: string; row: Row }[] = []
  const updates: { table: string; patch: Row; id: string }[] = []
  let seq = 0
  const settings = () => ({
    wa_initiated_allowlist_only: cfg.onlyAllowlisted ?? true,
    wa_test_allowed_numbers: cfg.list ?? [LISTED],
    wa_test_mode_enabled: false,
    wa_dispatch_v2_enabled: false,
    wa_dispatch_v2_scope: "numbers",
    wa_dispatch_v2_numbers: [],
  })
  const from = (table: string) => {
    const b: Record<string, unknown> = {}
    for (const m of ["select", "eq", "is", "in", "order", "limit", "abortSignal"]) b[m] = () => b
    b.maybeSingle = async () => ({ data: table === "settings" ? settings() : null, error: null })
    b.insert = (row: Row) => {
      inserts.push({ table, row: { ...row } })
      const id = `row-${++seq}`
      return { select: () => ({ single: async () => ({ data: { id }, error: null }) }), then: (r: (v: unknown) => unknown) => r({ error: null }) }
    }
    b.update = (patch: Row) => ({
      eq: async (_c: string, id: string) => {
        updates.push({ table, patch: { ...patch }, id })
        return { error: null }
      },
    })
    return b
  }
  return { admin: { from } as never, inserts, updates }
}

const fetchMock = vi.fn()
beforeEach(() => {
  vi.stubGlobal("Deno", { env: { get: () => undefined } })
  vi.stubGlobal("fetch", fetchMock)
  fetchMock.mockReset()
  resetDispatchV2FlagCache()
})
afterEach(() => vi.unstubAllGlobals())

const send = (admin: never, to: string, extra: Row = {}) =>
  sendMessage(admin, { orgId: "org-1", to, customerId: "c-1", template: "feedback_request", body: "hi", refType: "service_tickets", refId: "t-1", initiated: true, ...extra } as never)

describe("a blocked initiated send", () => {
  it("writes exactly one failed row that every poller skips, plus one audit row with only the last four digits", async () => {
    const { admin, inserts } = fakeAdmin()
    const r = await send(admin, OTHER)
    expect(r.dispatched).toBe(false)
    expect(fetchMock).not.toHaveBeenCalled()
    const outbox = inserts.filter((i) => i.table === "whatsapp_outbox")
    expect(outbox).toHaveLength(1)
    expect(outbox[0].row).toMatchObject({ direction: "outbound", status: "failed", wa_message_id: null, ref_type: "service_tickets", ref_id: "t-1", template: "feedback_request" })
    expect(outbox[0].row.retried_at).toEqual(expect.any(String)) // closed: the retry pass and the milestone loop both require retried_at IS NULL
    expect(String(outbox[0].row.error)).toBe("blocked: initiated_not_allow_listed")
    const audit = inserts.filter((i) => i.table === "audit_log")
    expect(audit).toHaveLength(1)
    expect(JSON.stringify(audit[0].row)).not.toContain(OTHER)
    expect(audit[0].row).toMatchObject({ action: "WA_SEND_BLOCKED" })
    expect((audit[0].row.after as Row).to_last4).toBe("1111")
  })

  it("updates the dispatcher's own row in place when it already holds one (no second row)", async () => {
    const { admin, inserts, updates } = fakeAdmin()
    const r = await send(admin, OTHER, { outboxId: "held-row" })
    expect(r.outboxId).toBe("held-row")
    expect(inserts.filter((i) => i.table === "whatsapp_outbox")).toHaveLength(0)
    expect(updates).toHaveLength(1)
    expect(updates[0]).toMatchObject({ id: "held-row", patch: { status: "failed" } })
    expect(updates[0].patch.retried_at).toEqual(expect.any(String))
  })

  it("a listed recipient is not blocked and no blocked row is written", async () => {
    const { admin, inserts } = fakeAdmin()
    await send(admin, LISTED)
    expect(inserts.filter((i) => i.table === "audit_log")).toHaveLength(0)
    expect(inserts.filter((i) => i.table === "whatsapp_outbox" && String(i.row.error ?? "").startsWith("blocked:"))).toHaveLength(0)
  })

  it("with the go-live switch open (false) nothing is blocked", async () => {
    const { admin, inserts } = fakeAdmin({ onlyAllowlisted: false, list: [] })
    await send(admin, OTHER)
    expect(inserts.filter((i) => i.table === "audit_log")).toHaveLength(0)
  })
})

// The loops in wa-scheduled-tasks/index.ts run inside a Deno function that vitest cannot import, so the properties that
// stop a blocked item being attempted again are asserted on its source text.
describe("wa-scheduled-tasks cannot flood on blocked rows", () => {
  const src = readFileSync(join(__dirname, "..", "wa-scheduled-tasks", "index.ts"), "utf8").replace(/\r\n/g, "\n")

  it("the duplicate check counts a row of ANY status (so a blocked failed row suppresses the next attempt within the lookback)", () => {
    const fn = src.slice(src.indexOf("async function alreadySentRecently"), src.indexOf("async function runAmcReminders"))
    expect(fn).toContain('.eq("ref_type", refType)')
    expect(fn).toContain('.eq("ref_id", refId)')
    expect(fn).toContain('.eq("template", template)')
    expect(fn).toContain('.gte("created_at"')
    expect(fn).not.toMatch(/\.eq\("status"|\.neq\("status"|\.in\("status"/)
  })
  it("AMC reminders and feedback requests both call the duplicate check before sending", () => {
    expect(src).toMatch(/alreadySentRecently\(admin, orgId, "amc_contracts", contract\.id, template\)/)
    expect(src).toMatch(/alreadySentRecently\(admin, orgId, "service_tickets", ticket\.id, "feedback_request"\)/)
  })
  it("both retry passes only pick rows whose retried_at is null (a blocked row has it set)", () => {
    for (const fn of ["async function runFailedSendRetriesV2", "async function runLegacyFailedSendRetries"]) {
      const start = src.indexOf(fn)
      expect(start, fn).toBeGreaterThan(-1)
      expect(src.slice(start, start + 1400), fn).toMatch(/\.eq\("status", "failed"\)[\s\S]*\.is\("retried_at", null\)/)
    }
  })
})
