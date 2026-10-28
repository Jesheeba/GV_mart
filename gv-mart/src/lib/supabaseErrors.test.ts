import { describe, expect, it } from "vitest"
import { isNotYetAvailableError, isUndefinedColumnError, isUndefinedFunctionError, isUndefinedTableError } from "./supabaseErrors"

// These codes are what the expenses screens see before their migration
// (20261107100000-20261107100500) is applied: technician_km_log / expense_claims
// missing entirely (42P01), own_bike_allowance_base missing (42703), or
// technician_km_log_sum / submit_expense_claim not defined yet (42883).

describe("isUndefinedTableError", () => {
  it("is true for Postgres 42P01 (missing-table failure, e.g. technician_km_log not migrated yet)", () => {
    expect(isUndefinedTableError({ code: "42P01" })).toBe(true)
  })
  it("is false for an unrelated error code", () => {
    expect(isUndefinedTableError({ code: "23505" })).toBe(false)
  })
})

describe("isUndefinedColumnError", () => {
  it("is true for Postgres 42703 (missing-column failure)", () => {
    expect(isUndefinedColumnError({ code: "42703" })).toBe(true)
  })
  it("is false for an unrelated error code", () => {
    expect(isUndefinedColumnError({ code: "23505" })).toBe(false)
  })
})

describe("isUndefinedFunctionError", () => {
  it("is true for Postgres 42883 (missing RPC, e.g. technician_km_log_sum not migrated yet)", () => {
    expect(isUndefinedFunctionError({ code: "42883" })).toBe(true)
  })
  it("is false for an unrelated error code", () => {
    expect(isUndefinedFunctionError({ code: "23505" })).toBe(false)
  })
})

describe("isNotYetAvailableError", () => {
  it("is true for any of the three deploy-order codes (missing-table failure)", () => {
    expect(isNotYetAvailableError({ code: "42P01" })).toBe(true)
    expect(isNotYetAvailableError({ code: "42703" })).toBe(true)
    expect(isNotYetAvailableError({ code: "42883" })).toBe(true)
  })

  it("is false for a genuine save/load failure unrelated to a missing schema object", () => {
    // e.g. a unique-constraint violation on submit, or a plain network error —
    // these should show the generic failure message, never the calm
    // "not available yet" one.
    expect(isNotYetAvailableError({ code: "23505" })).toBe(false)
    expect(isNotYetAvailableError(new Error("Failed to fetch"))).toBe(false)
  })

  it("is false for non-object and null errors", () => {
    expect(isNotYetAvailableError(null)).toBe(false)
    expect(isNotYetAvailableError(undefined)).toBe(false)
    expect(isNotYetAvailableError("some string error")).toBe(false)
  })
})
