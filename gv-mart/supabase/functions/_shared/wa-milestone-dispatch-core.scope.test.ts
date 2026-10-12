import { beforeEach, describe, expect, it, vi } from "vitest"
import { parseDispatchV2Scope } from "./wa-dispatch-scope"

// runMilestoneDispatch with a per-number scope: listed recipients go through the v2 claim loop, everyone else through the
// legacy loop exactly as before, and neither half touches the other's rows. sendMessage is mocked (nothing is sent).
const LISTED = "9000000001"
const OTHER = "9000000002"

const sendMessage = vi.fn(async (_admin: unknown, input: { to: string; outboxId?: string }) => ({
  outboxId: input.outboxId ?? "new-row",
  waMessageId: null,
  dispatched: false,
  status: input.outboxId ? "skipped_no_template" : undefined,
}))
let scope = parseDispatchV2Scope({ wa_dispatch_v2_enabled: true, wa_dispatch_v2_scope: "numbers", wa_dispatch_v2_numbers: [LISTED] })

vi.mock("./whatsapp.ts", () => ({
  sendMessage: (...a: [unknown, { to: string; outboxId?: string }]) => sendMessage(...a),
  getDispatchV2Scope: async () => scope,
}))
vi.mock("./wa-event-context.ts", () => ({
  resolveEventContext: async () => ({ language: "en", vars: {} }),
}))

type Row = Record<string, unknown>
function fakeAdmin(rows: Row[]) {
  const updates: { id: string; patch: Row }[] = []
  const claimed = new Set<string>()
  const from = (table: string) => {
    const filters: Record<string, unknown> = {}
    const b: Record<string, unknown> = {}
    const chain = () => b
    b.select = chain
    b.eq = (c: string, v: unknown) => { filters[`eq:${c}`] = v; return b }
    b.is = (c: string, v: unknown) => { filters[`is:${c}`] = v; return b }
    b.neq = (c: string, v: unknown) => { filters[`neq:${c}`] = v; return b }
    b.in = chain
    b.order = chain
    b.limit = chain
    b.update = (patch: Row) => {
      const u = { id: "", patch }
      const upd: Record<string, unknown> = {}
      upd.eq = (c: string, v: unknown) => { if (c === "id") u.id = String(v); return upd }
      upd.is = () => upd
      upd.select = () => upd
      upd.then = (resolve: (v: unknown) => unknown) => {
        updates.push(u)
        if ("claimed_at" in patch) {
          const first = !claimed.has(u.id)
          claimed.add(u.id)
          return resolve({ data: first ? [{ id: u.id }] : [], error: null })
        }
        return resolve({ data: null, error: null })
      }
      return upd
    }
    b.insert = async () => ({ error: null })
    b.then = (resolve: (v: unknown) => unknown) => {
      if (table !== "whatsapp_outbox") return resolve({ data: [], error: null })
      let out = rows.filter((r) => r.wa_message_id == null && r.retried_at == null)
      if (filters["eq:status"] !== undefined) out = out.filter((r) => r.status === filters["eq:status"])
      if (filters["neq:status"] !== undefined) out = out.filter((r) => r.status !== filters["neq:status"])
      if (filters["is:claimed_at"] === null) out = out.filter((r) => r.claimed_at == null)
      return resolve({ data: out, error: null })
    }
    return b
  }
  return { admin: { from } as never, updates }
}

const base = { org_id: "org-1", customer_id: null, template: "milestone.booked", type: "text", payload: { body: "hello" }, ref_type: "service_ticket", ref_id: "tk", retry_count: 0, wa_message_id: null, retried_at: null, claimed_at: null }

beforeEach(() => {
  sendMessage.mockClear()
  scope = parseDispatchV2Scope({ wa_dispatch_v2_enabled: true, wa_dispatch_v2_scope: "numbers", wa_dispatch_v2_numbers: [LISTED] })
  vi.spyOn(console, "error").mockImplementation(() => {})
})

describe("runMilestoneDispatch with scope numbers", () => {
  it("v2 serves the listed recipient's pending row; the legacy loop serves the unlisted optimistic row; neither crosses over", async () => {
    const { runMilestoneDispatch } = await import("./wa-milestone-dispatch-core")
    const rows: Row[] = [
      { ...base, id: "v2-row", status: "pending", to_mobile: LISTED },
      { ...base, id: "legacy-row", status: "sent", to_mobile: OTHER },
      { ...base, id: "legacy-pending-other", status: "pending", to_mobile: OTHER }, // a stray pending row for an unlisted number
    ]
    const { admin } = fakeAdmin(rows)
    await runMilestoneDispatch(admin, "org-1")
    const calls = sendMessage.mock.calls.map((c) => c[1])
    const v2Call = calls.find((c) => c.outboxId === "v2-row")
    expect(v2Call?.to).toBe(LISTED)
    const legacyCall = calls.find((c) => !c.outboxId)
    expect(legacyCall?.to).toBe(OTHER)
    // exactly two sends: the stray pending row for the unlisted number is left alone by both halves
    expect(calls).toHaveLength(2)
  })

  it("an empty list leaves the whole dispatcher on the legacy loop", async () => {
    scope = parseDispatchV2Scope({ wa_dispatch_v2_enabled: true, wa_dispatch_v2_scope: "numbers", wa_dispatch_v2_numbers: [] })
    const { runMilestoneDispatch } = await import("./wa-milestone-dispatch-core")
    const rows: Row[] = [{ ...base, id: "a", status: "sent", to_mobile: LISTED }, { ...base, id: "b", status: "sent", to_mobile: OTHER }]
    const { admin } = fakeAdmin(rows)
    await runMilestoneDispatch(admin, "org-1")
    expect(sendMessage).toHaveBeenCalledTimes(2)
    expect(sendMessage.mock.calls.every((c) => c[1].outboxId === undefined)).toBe(true)
  })

  it("flag OFF: identical to today (every row through the legacy loop)", async () => {
    scope = parseDispatchV2Scope({ wa_dispatch_v2_enabled: false, wa_dispatch_v2_scope: "numbers", wa_dispatch_v2_numbers: [LISTED] })
    const { runMilestoneDispatch } = await import("./wa-milestone-dispatch-core")
    const rows: Row[] = [{ ...base, id: "a", status: "sent", to_mobile: LISTED }, { ...base, id: "b", status: "sent", to_mobile: OTHER }]
    const { admin } = fakeAdmin(rows)
    await runMilestoneDispatch(admin, "org-1")
    expect(sendMessage).toHaveBeenCalledTimes(2)
    expect(sendMessage.mock.calls.every((c) => c[1].outboxId === undefined)).toBe(true)
  })

  it("scope org: everything through v2, the legacy loop does not run", async () => {
    scope = parseDispatchV2Scope({ wa_dispatch_v2_enabled: true, wa_dispatch_v2_scope: "org", wa_dispatch_v2_numbers: [] })
    const { runMilestoneDispatch } = await import("./wa-milestone-dispatch-core")
    const rows: Row[] = [{ ...base, id: "p1", status: "pending", to_mobile: LISTED }, { ...base, id: "legacy", status: "sent", to_mobile: OTHER }]
    const { admin } = fakeAdmin(rows)
    await runMilestoneDispatch(admin, "org-1")
    expect(sendMessage).toHaveBeenCalledTimes(1)
    expect(sendMessage.mock.calls[0][1].outboxId).toBe("p1")
  })
})
