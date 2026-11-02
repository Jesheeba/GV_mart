import { beforeEach, describe, expect, it, vi } from "vitest"

/**
 * Regression test for the 2026-11-02 production outage: the customer
 * search combobox used by New Complaint, New Sale, rentals, quotations,
 * leads, AMC, the customer merge panel, and the Customers list (all via
 * useCustomerAutocomplete) fired 3 uncancelled Supabase queries per
 * keystroke with no debounce. Under real concurrent load those requests
 * queued instead of being superseded, so the dropdown's loading spinner
 * never cleared even though the backend eventually answered correctly.
 * The fix threads an AbortSignal through every one of the three
 * sub-queries so a superseded request is actually cancelled, not merely
 * ignored by the caller. This test pins that every sub-query receives
 * the signal passed into autocompleteCustomers — before the fix, none of
 * them did, so .abortSignal would never have been called.
 */
const state: { calls: { method: string; args: unknown[] }[] } = { calls: [] }

function builder(): unknown {
  const handler: ProxyHandler<object> = {
    get(_t, prop: string) {
      if (prop === "then") {
        return (resolve: (v: unknown) => void) => resolve({ data: [], error: null })
      }
      return (...args: unknown[]) => {
        state.calls.push({ method: prop, args })
        return proxy
      }
    },
  }
  const proxy: unknown = new Proxy({}, handler)
  return proxy
}

vi.mock("@/lib/supabase", () => ({
  supabase: { from: () => builder() },
}))

import { autocompleteCustomers } from "@/services/customers"

beforeEach(() => {
  state.calls = []
})

describe("autocompleteCustomers cancellation wiring", () => {
  it("threads the caller's AbortSignal into every one of the three sub-queries", async () => {
    const controller = new AbortController()
    await autocompleteCustomers("org-1", "9024549553", controller.signal)

    const abortCalls = state.calls.filter((c) => c.method === "abortSignal")
    expect(abortCalls).toHaveLength(3)
    for (const call of abortCalls) {
      expect(call.args[0]).toBe(controller.signal)
    }
  })

  it("still works with no signal supplied (falls back to a signal that never aborts)", async () => {
    await autocompleteCustomers("org-1", "9024549553")
    const abortCalls = state.calls.filter((c) => c.method === "abortSignal")
    expect(abortCalls).toHaveLength(3)
    for (const call of abortCalls) {
      expect(call.args[0]).toBeInstanceOf(AbortSignal)
      expect((call.args[0] as AbortSignal).aborted).toBe(false)
    }
  })
})
