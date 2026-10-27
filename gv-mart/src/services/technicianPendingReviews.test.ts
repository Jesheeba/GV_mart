import { describe, expect, it, vi } from "vitest"

/**
 * listMyPendingReviews is a thin RPC wrapper, but the two behaviours it owns matter a lot for the Pending Reviews
 * screen: (1) it must call the right, parameterless RPC (ownership is enforced server-side, not by an id this
 * function could pass wrong), and (2) a PostgREST error must REJECT the promise, never resolve with an empty
 * array — PendingReviewsPage relies on that rejection to tell "failed to load" apart from "genuinely no pending
 * reviews" (two visibly different states on that screen).
 */
const rpcCalls: { fn: string; args: unknown }[] = []
let rpcResult: { data: unknown; error: unknown } = { data: [], error: null }

vi.mock("@/lib/supabase", () => ({
  supabase: {
    rpc: (fn: string, args?: unknown) => {
      rpcCalls.push({ fn, args })
      return Promise.resolve(rpcResult)
    },
  },
}))

import { listMyPendingReviews } from "@/services/technician"

describe("listMyPendingReviews", () => {
  it("calls list_technician_pending_reviews with no arguments (ownership is server-side, not client-passed)", async () => {
    rpcCalls.length = 0
    rpcResult = { data: [], error: null }
    await listMyPendingReviews()
    expect(rpcCalls).toEqual([{ fn: "list_technician_pending_reviews", args: undefined }])
  })

  it("returns the rows as-is when the RPC succeeds", async () => {
    const rows = [
      {
        visit_id: "v1",
        ticket_id: "t1",
        customer_id: "c1",
        customer_name: "__TEST_customer",
        complaint: "Leaking filter",
        visit_completed_at: "2026-11-01T10:00:00Z",
      },
    ]
    rpcResult = { data: rows, error: null }
    const result = await listMyPendingReviews()
    expect(result).toEqual(rows)
  })

  it("treats a null data response as an empty list, not an error", async () => {
    rpcResult = { data: null, error: null }
    const result = await listMyPendingReviews()
    expect(result).toEqual([])
  })

  it("throws (rejects) when the RPC returns an error, instead of silently resolving empty", async () => {
    rpcResult = { data: null, error: { message: "network error" } }
    await expect(listMyPendingReviews()).rejects.toEqual({ message: "network error" })
  })
})
