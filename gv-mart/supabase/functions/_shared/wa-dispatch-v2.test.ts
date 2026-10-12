import { describe, expect, it } from "vitest"
import { runDispatchV2, type DispatchDeps, type PendingRow } from "./wa-dispatch-v2"

function row(id: string, over: Partial<PendingRow> = {}): PendingRow {
  return { id, org_id: "org-1", to_mobile: "9000000001", customer_id: "c-1", template: "milestone.booked", payload: { body: "hi" }, ref_type: "service_ticket", ref_id: "tk-1", retry_count: 0, ...over }
}

/** In-memory store with a genuinely atomic claim (single-threaded JS: the check-and-set has no await in between). */
function makeStore(rows: PendingRow[], opts: { sendStatus?: string; sendDelayMs?: number } = {}) {
  const claimed = new Set<string>()
  const sends: string[] = []
  const failed: Record<string, Record<string, unknown>> = {}
  const deps: DispatchDeps = {
    async listPending() {
      // the SAME snapshot for every concurrent worker, like two cron/dispatch-now invocations reading at once
      return rows.filter((r) => !claimed.has(r.id)).map((r) => ({ ...r }))
    },
    async claim(id) {
      await Promise.resolve()
      if (claimed.has(id)) return false
      claimed.add(id)
      return true
    },
    async failRow(id, patch) {
      failed[id] = patch
    },
    async resolveContext() {
      return { language: "en", vars: { name: "A" } }
    },
    async send(r) {
      sends.push(r.id)
      if (opts.sendDelayMs) await new Promise((res) => setTimeout(res, opts.sendDelayMs))
      return { status: opts.sendStatus ?? "sent" }
    },
    nowIso: () => "2026-10-12T12:00:00.000Z",
  }
  return { deps, sends, failed, claimed }
}

describe("runDispatchV2", () => {
  it("duplicate dispatch race: two workers over the same rows send each row exactly once", async () => {
    const rows = [row("a"), row("b"), row("c"), row("d")]
    const { deps, sends } = makeStore(rows, { sendDelayMs: 5 })
    const [s1, s2] = await Promise.all([runDispatchV2(deps, "org-1"), runDispatchV2(deps, "org-1")])
    expect([...sends].sort()).toEqual(["a", "b", "c", "d"])
    expect(s1.sent + s2.sent).toBe(4)
    expect(s1.lostClaim + s2.lostClaim).toBe(4)
  })

  it("a row already claimed by someone else is never sent", async () => {
    const { deps, sends, claimed } = makeStore([row("a")])
    claimed.add("a")
    const s = await runDispatchV2({ ...deps, listPending: async () => [row("a")] }, "org-1")
    expect(sends).toEqual([])
    expect(s.lostClaim).toBe(1)
  })

  it("a row with no recipient number is failed visibly, not sent", async () => {
    const { deps, sends, failed } = makeStore([row("a", { to_mobile: null })])
    const s = await runDispatchV2(deps, "org-1")
    expect(sends).toEqual([])
    expect(failed.a).toMatchObject({ status: "failed", error: "no_recipient_number" })
    expect(s.noRecipient).toBe(1)
  })

  it("a row over the attempt cap is closed out, never resent", async () => {
    const { deps, sends, failed } = makeStore([row("a", { retry_count: 3 })])
    const s = await runDispatchV2(deps, "org-1")
    expect(sends).toEqual([])
    expect(failed.a).toMatchObject({ status: "failed", error: "gave_up_after_max_attempts" })
    expect(s.failed).toBe(1)
  })

  it("counts skipped_no_template and failed outcomes separately", async () => {
    const a = makeStore([row("a")], { sendStatus: "skipped_no_template" })
    expect((await runDispatchV2(a.deps, "org-1")).skippedNoTemplate).toBe(1)
    const b = makeStore([row("a")], { sendStatus: "failed" })
    expect((await runDispatchV2(b.deps, "org-1")).failed).toBe(1)
  })

  it("a send that throws leaves the claim in place (no automatic resend) and does not stop the batch", async () => {
    const rows = [row("a"), row("b")]
    const { deps, sends, claimed } = makeStore(rows)
    let n = 0
    const wrapped: DispatchDeps = {
      ...deps,
      async send(r, ctx) {
        n++
        if (r.id === "a") throw new Error("db write failed")
        return deps.send(r, ctx)
      },
    }
    const s = await runDispatchV2(wrapped, "org-1")
    expect(n).toBe(2)
    expect(sends).toEqual(["b"])
    expect(claimed.has("a")).toBe(true)
    expect(s.pendingAfter).toBe(1)
    expect(s.sent).toBe(1)
  })
})
