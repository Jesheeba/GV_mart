import { beforeEach, describe, expect, it, vi } from "vitest"
import { DISPATCH_V2_OFF, parseDispatchV2Scope } from "./wa-dispatch-scope"

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

let currentScope = parseDispatchV2Scope({ wa_dispatch_v2_enabled: true, wa_dispatch_v2_scope: "org", wa_dispatch_v2_numbers: [] })

vi.mock("./whatsapp.ts", () => ({
  sendMessage: (...a: [unknown, { to: string; outboxId?: string }]) => sendMessage(...a),
  getDispatchV2Scope: async () => currentScope,
}))
vi.mock("./wa-event-context.ts", () => ({
  resolveEventContext: async () => ({ language: "en", vars: {} }),
}))

type Row = Record<string, unknown>
type Challenge = { expires_at: string; used_at: string | null; superseded_at: string | null }

// `challenges`: ref_id -> challenge row. A ref_id with no entry resolves to "not found" (data:
// null), matching customerLinkOtpStillSendable's fail-open-to-true behavior for a missing row —
// this is what every pre-existing test above relies on implicitly (none of them populate this map).
function fakeAdmin(rows: Row[], challenges: Record<string, Challenge> = {}) {
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
    b.in = (c: string, v: unknown) => { filters[`in:${c}`] = v; return b }
    b.order = chain
    b.limit = chain
    b.maybeSingle = async () => {
      if (table !== "customer_link_otp_challenges") return { data: null, error: null }
      const id = filters["eq:id"] as string | undefined
      return { data: id && id in challenges ? challenges[id] : null, error: null }
    }
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
      const refTypeFilter = filters["in:ref_type"] as string[] | undefined
      const out = rows.filter(
        (r) =>
          r.wa_message_id == null &&
          r.retried_at == null &&
          r.status === "pending" &&
          r.claimed_at == null &&
          (!refTypeFilter || refTypeFilter.includes(r.ref_type as string))
      )
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
  currentScope = parseDispatchV2Scope({ wa_dispatch_v2_enabled: true, wa_dispatch_v2_scope: "org", wa_dispatch_v2_numbers: [] })
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

  // Phase 2, Item 2: a challenge may have expired, been used, or been superseded by the time
  // either dispatch path (the new fast path, or this cron sweep as its fallback) gets to actually
  // send it. Both paths must check this BEFORE ever calling sendMessage — never hand a customer a
  // dead code, and never let the plaintext body/code sit around once it can't be verified anyway.
  describe("stale-challenge guard (customerLinkOtpStillSendable)", () => {
    const future = new Date(Date.now() + 60_000).toISOString()
    const past = new Date(Date.now() - 60_000).toISOString()

    it("v2 path: an EXPIRED challenge is never sent, is marked failed, and is redacted", async () => {
      const { runMilestoneDispatch } = await import("./wa-milestone-dispatch-core")
      const { admin, updates } = fakeAdmin([{ ...base, id: "otp-row" }], {
        "challenge-1": { expires_at: past, used_at: null, superseded_at: null },
      })
      const result = await runMilestoneDispatch(admin, "org-1")
      expect(sendMessage).not.toHaveBeenCalled()
      expect(result.dispatched).toBe(0)
      const u = updates.find((x) => x.id === "otp-row" && "status" in x.patch)
      expect(u).toBeDefined()
      expect(u!.patch.status).toBe("failed")
      expect(u!.patch.error).toBe("otp_expired_or_used")
      expect((u!.patch.payload as { body: string }).body).not.toContain("482913")
    })

    it("v2 path: a USED challenge is never sent", async () => {
      const { runMilestoneDispatch } = await import("./wa-milestone-dispatch-core")
      const { admin } = fakeAdmin([{ ...base, id: "otp-row" }], {
        "challenge-1": { expires_at: future, used_at: new Date().toISOString(), superseded_at: null },
      })
      await runMilestoneDispatch(admin, "org-1")
      expect(sendMessage).not.toHaveBeenCalled()
    })

    it("v2 path: a SUPERSEDED challenge is never sent", async () => {
      const { runMilestoneDispatch } = await import("./wa-milestone-dispatch-core")
      const { admin } = fakeAdmin([{ ...base, id: "otp-row" }], {
        "challenge-1": { expires_at: future, used_at: null, superseded_at: new Date().toISOString() },
      })
      await runMilestoneDispatch(admin, "org-1")
      expect(sendMessage).not.toHaveBeenCalled()
    })

    it("v2 path: a still-VALID challenge sends normally (no regression)", async () => {
      const { runMilestoneDispatch } = await import("./wa-milestone-dispatch-core")
      const { admin } = fakeAdmin([{ ...base, id: "otp-row" }], {
        "challenge-1": { expires_at: future, used_at: null, superseded_at: null },
      })
      const result = await runMilestoneDispatch(admin, "org-1")
      expect(sendMessage).toHaveBeenCalledTimes(1)
      expect(result.dispatched).toBe(1)
    })

    it("legacy path (v2 off): an EXPIRED challenge is never sent and never redacted via a retry-eligible row", async () => {
      currentScope = DISPATCH_V2_OFF
      const { runMilestoneDispatch } = await import("./wa-milestone-dispatch-core")
      const { admin, updates } = fakeAdmin([{ ...base, id: "otp-row" }], {
        "challenge-1": { expires_at: past, used_at: null, superseded_at: null },
      })
      const result = await runMilestoneDispatch(admin, "org-1")
      expect(sendMessage).not.toHaveBeenCalled()
      expect(result.dispatched).toBe(0)
      const u = updates.find((x) => x.id === "otp-row" && "retried_at" in x.patch)
      expect(u?.patch.status).toBe("failed")
      expect(u?.patch.error).toBe("otp_expired_or_used")
    })

    it("never queries customer_link_otp_challenges for a different ref_type (true no-op)", async () => {
      const { runMilestoneDispatch } = await import("./wa-milestone-dispatch-core")
      const { admin } = fakeAdmin([{ ...base, id: "ticket-row", ref_type: "service_ticket", ref_id: "ticket-xyz", payload: { body: "your technician is on the way" } }])
      await runMilestoneDispatch(admin, "org-1")
      expect(sendMessage).toHaveBeenCalledTimes(1) // never blocked by a challenge lookup it should never make
    })
  })

  // Phase 2, Item 2: wa-otp-dispatch/index.ts calls runMilestoneDispatch with a hardcoded
  // { refTypes: ["customer_link_otp"] } so the fast path can never widen into a general
  // low-latency scan for other milestone types. Every existing caller (the cron sweep,
  // wa-dispatch-now) omits the option and must keep scanning everything, unchanged.
  describe("optional refTypes scoping (runMilestoneDispatch's new 3rd argument)", () => {
    it("with refTypes restricted, a different ref_type row in the same org is ignored entirely", async () => {
      const { runMilestoneDispatch } = await import("./wa-milestone-dispatch-core")
      const { admin } = fakeAdmin([
        { ...base, id: "otp-row" },
        { ...base, id: "ticket-row", ref_type: "service_ticket", ref_id: "ticket-xyz", payload: { body: "your technician is on the way" } },
      ])
      const result = await runMilestoneDispatch(admin, "org-1", { refTypes: ["customer_link_otp"] })
      expect(sendMessage).toHaveBeenCalledTimes(1)
      expect(sendMessage).toHaveBeenCalledWith(expect.anything(), expect.objectContaining({ refType: "customer_link_otp" }))
      expect(result.dispatched).toBe(1)
    })

    it("omitting refTypes (every existing caller) still scans every milestone ref_type, unchanged", async () => {
      const { runMilestoneDispatch } = await import("./wa-milestone-dispatch-core")
      const { admin } = fakeAdmin([
        { ...base, id: "otp-row" },
        { ...base, id: "ticket-row", ref_type: "service_ticket", ref_id: "ticket-xyz", payload: { body: "your technician is on the way" } },
      ])
      const result = await runMilestoneDispatch(admin, "org-1")
      expect(sendMessage).toHaveBeenCalledTimes(2)
      expect(result.dispatched).toBe(2)
    })
  })
})
