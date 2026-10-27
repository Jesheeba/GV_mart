import { describe, expect, it } from "vitest"
import { resolveSectionState } from "./listState"

// Covers the branching used by ExpensesHistoryPage's claims list and km-log
// list: a failed query must never render the same "nothing here" message as
// a query that succeeded with zero rows (the bug the Capacitor-build audit
// found — expense_claims/technician_km_log missing was indistinguishable
// from the technician genuinely having no history).

describe("resolveSectionState", () => {
  it("is 'loading' while the query is in flight, regardless of error/empty flags", () => {
    expect(resolveSectionState({ isLoading: true, isError: false, isEmpty: true })).toBe("loading")
    expect(resolveSectionState({ isLoading: true, isError: true, isEmpty: false })).toBe("loading")
  })

  it("is 'error' on a load failure, even when the stale/placeholder data looks empty (load failure)", () => {
    expect(resolveSectionState({ isLoading: false, isError: true, isEmpty: true })).toBe("error")
  })

  it("is 'error' on a load failure with non-empty stale data too (error always wins over empty/data)", () => {
    expect(resolveSectionState({ isLoading: false, isError: true, isEmpty: false })).toBe("error")
  })

  it("is 'empty' when the query succeeded with zero rows (genuine-empty state, not a failure)", () => {
    expect(resolveSectionState({ isLoading: false, isError: false, isEmpty: true })).toBe("empty")
  })

  it("is 'data' when the query succeeded with rows", () => {
    expect(resolveSectionState({ isLoading: false, isError: false, isEmpty: false })).toBe("data")
  })
})
