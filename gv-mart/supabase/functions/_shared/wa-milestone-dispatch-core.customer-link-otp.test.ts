import { beforeEach, describe, expect, it, vi } from "vitest"
import { parseDispatchV2Scope } from "./wa-dispatch-scope"

// customer_link_otp (20261120100000_customer_link_otp.sql): the OTP code lives in
// whatsapp_outbox.payload.body until it is actually sent. This proves two things about the
// existing dispatcher that the OTP feature depends on and must not regress:
//   1. a 'customer_link_otp' ref_type row is picked up at all (it's in MILESTONE_REF_TYPES now);
//   2. once sendMessage reports it as sent, the v2 path redacts payload.body in place so the
//      plaintext code does not keep sitting in a table any staff/master user can browse
//      (whatsapp_outbox_select_staff) — see wa-milestone-dispatch-core.ts's
//      REDACT_BODY_AFTER_SEND_REF_TYPES.
// A send that does NOT succeed (still pending/failed, e.g. transport error — the retry needs the
// real body) must NOT be redacted, otherwise a retry would resend a redacted placeholder.

let sendResult: { status: string } = { status: "sent" }
const sendMessage = vi.fn(async (_admin: unknown, input: { to: string; outboxId?: string }) => ({
  outboxId: input.outboxId ?? "new-row",
  waMessageId: sendResult.status === "sent" ? "wamid.1" : null,
  dispatched: sendResult.status === "sent",
  status: sendResult.status,
}))

const scope = parseDispatchV2Scope({ wa_dispatch_v2_enabled: true, wa_dispatch_v2_scope: "org", wa_dispatch_v2_numbers: [] })

vi.mock("./whatsapp.ts", () => ({
  sendMessage: (...a: [unknown, { to: string; outboxId?: string }]) => sendMessage(...a),
  getDispatchV2Scope: async () => scope,
}))
vi.mock("./wa-event-context.ts", () => ({
  resolveEventContext: async () => ({ language: "en", vars: {} }),
}))

type Row = Record<string, unknown>

function fakeAdmin(rows: Row[]) {
  const updates: { table: string; id: string; patch: Row }[] = []
  const claimed = new Set<string>()
  const from = (table: string) => {
    const filters: Record<string, unknown> = {}
    const b: Record<string, unknown> = {}
    const chain = () => b
    b.select = chain
    b.eq = (c: string, v: unknown) => { filters[`eq:${c}`] = v; return b }
    b.is = (c: string, v: unknown) => { filters[`is:${c}`] = v; return b }
    b.neq = chain
    b.in = chain
    b.order = chain
    b.limit = chain
    b.update = (patch: Row) => {
      const u = { table, id: "", patch }
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
      const out = rows.filter((r) => r.wa_message_id == null && r.retried_at == null && r.status === "pending" && r.claimed_at == null)
      return resolve({ data: out, error: null })
    }
    return b
  }
  return { admin: { from } as never, updates }
}

const base = {
  org_id: "org-1",
  customer_id: "cust-1",
  template: "customer_link_otp",
  type: "text",
  payload: { body: "482913 is your GV Mart account linking code. Do not share it with anyone. It expires in 10 minutes." },
  ref_type: "customer_link_otp",
  ref_id: "challenge-1",
  retry_count: 0,
  wa_message_id: null,
  retried_at: null,
  claimed_at: null,
  to_mobile: "9000000001",
  status: "pending",
}

beforeEach(() => {
  sendMessage.mockClear()
  sendResult = { status: "sent" }
  vi.spyOn(console, "error").mockImplementation(() => {})
})

describe("customer_link_otp rows through the existing milestone dispatcher", () => {
  it("is picked up (MILESTONE_REF_TYPES includes customer_link_otp)", async () => {
    const { runMilestoneDispatch } = await import("./wa-milestone-dispatch-core")
    const { admin } = fakeAdmin([{ ...base, id: "otp-row" }])
    const result = await runMilestoneDispatch(admin, "org-1")
    expect(sendMessage).toHaveBeenCalledTimes(1)
    expect(result.dispatched).toBe(1)
  })

  it("redacts payload.body after a successful send, so the plaintext code is not left readable", async () => {
    const { runMilestoneDispatch } = await import("./wa-milestone-dispatch-core")
    const { admin, updates } = fakeAdmin([{ ...base, id: "otp-row" }])
    await runMilestoneDispatch(admin, "org-1")
    const redaction = updates.find((u) => u.id === "otp-row" && "payload" in u.patch)
    expect(redaction).toBeDefined()
    expect((redaction!.patch.payload as { body: string }).body).not.toContain("482913")
    expect((redaction!.patch.payload as { body: string }).body).toBe("[redacted after send]")
  })

  it("does NOT redact when the send did not succeed (so a retry still has the real body)", async () => {
    sendResult = { status: "pending" }
    const { runMilestoneDispatch } = await import("./wa-milestone-dispatch-core")
    const { admin, updates } = fakeAdmin([{ ...base, id: "otp-row" }])
    await runMilestoneDispatch(admin, "org-1")
    const redaction = updates.find((u) => u.id === "otp-row" && "payload" in u.patch)
    expect(redaction).toBeUndefined()
  })

  it("never redacts a different ref_type's row, even on a successful send", async () => {
    const { runMilestoneDispatch } = await import("./wa-milestone-dispatch-core")
    const { admin, updates } = fakeAdmin([{ ...base, id: "ticket-row", ref_type: "service_ticket", payload: { body: "your technician is on the way" } }])
    await runMilestoneDispatch(admin, "org-1")
    const redaction = updates.find((u) => u.id === "ticket-row" && "payload" in u.patch)
    expect(redaction).toBeUndefined()
  })
})
