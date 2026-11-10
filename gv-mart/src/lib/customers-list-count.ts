/**
 * Pagination total for the Customers list (extracted for testability out of
 * CustomersListPage's `effectiveCount`).
 *
 * The Customers list query itself never excludes is_test customers (they
 * stay visible, tagged with the TEST badge) — but customer_filter_counts()'s
 * `total` field does exclude them (`is_test = false`), so it alone
 * undercounts the rows the list actually paginates over. The unfiltered
 * total is therefore `customer_filter_counts().total` plus a separate exact
 * count of just the org's is_test customers, added back in.
 *
 * Filtered/search views are unaffected: `ids` (the full matching id list
 * listCustomers already computed) is an exact count on its own, independent
 * of this is_test question.
 */
export function computeCustomersListCount(params: {
  hasActiveFilters: boolean
  /** queryCustomers' own count: ids.length when filtered, a "planned" estimate (covers every row regardless of is_test) when not. */
  queryCount: number | undefined
  /** customer_filter_counts().total — exact, excludes is_test customers. Undefined while still loading. */
  exactNonTestTotal: number | undefined
  /** Exact count of the org's is_test customers. Undefined while still loading. */
  testCustomerCount: number | undefined
}): number {
  const { hasActiveFilters, queryCount, exactNonTestTotal, testCustomerCount } = params
  if (hasActiveFilters) return queryCount ?? 0
  // Only add the test-customer count back in when we actually have the
  // exact non-test total to add it to — queryCount's own "planned" estimate
  // already covers every row (test customers included), so adding on top
  // of that fallback would double-count them.
  if (exactNonTestTotal != null) return exactNonTestTotal + (testCustomerCount ?? 0)
  return queryCount ?? 0
}
