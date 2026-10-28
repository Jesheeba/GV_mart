import { describe, expect, it } from "vitest"
import { computeCustomersListCount } from "./customers-list-count"

describe("computeCustomersListCount", () => {
  it("filtered/search view always uses queryCount (ids.length), regardless of the other totals", () => {
    expect(
      computeCustomersListCount({ hasActiveFilters: true, queryCount: 7, exactNonTestTotal: 999, testCustomerCount: 999 })
    ).toBe(7)
    expect(
      computeCustomersListCount({ hasActiveFilters: true, queryCount: 0, exactNonTestTotal: 50, testCustomerCount: 5 })
    ).toBe(0)
  })

  it("unfiltered view adds the exact non-test total and the test-customer count", () => {
    expect(
      computeCustomersListCount({ hasActiveFilters: false, queryCount: 123, exactNonTestTotal: 100, testCustomerCount: 23 })
    ).toBe(123)
  })

  it("unfiltered view with zero test customers is just the exact non-test total", () => {
    expect(
      computeCustomersListCount({ hasActiveFilters: false, queryCount: 100, exactNonTestTotal: 100, testCustomerCount: 0 })
    ).toBe(100)
  })

  it("unfiltered view treats a still-loading test-customer count as 0, not as missing", () => {
    expect(
      computeCustomersListCount({ hasActiveFilters: false, queryCount: 100, exactNonTestTotal: 100, testCustomerCount: undefined })
    ).toBe(100)
  })

  it("unfiltered view falls back to queryCount's own planned estimate when the exact total hasn't loaded yet, without double-adding the test count on top", () => {
    expect(
      computeCustomersListCount({ hasActiveFilters: false, queryCount: 118, exactNonTestTotal: undefined, testCustomerCount: 23 })
    ).toBe(118)
  })

  it("unfiltered view with nothing loaded yet is 0", () => {
    expect(
      computeCustomersListCount({ hasActiveFilters: false, queryCount: undefined, exactNonTestTotal: undefined, testCustomerCount: undefined })
    ).toBe(0)
  })
})
