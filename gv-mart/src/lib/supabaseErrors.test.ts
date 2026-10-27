import { describe, expect, it } from "vitest"
import { isNotYetAvailableError, isUndefinedColumnError, isUndefinedFunctionError, isUndefinedTableError } from "./supabaseErrors"

// These codes are what the technician/admin leave screens see before the
// 20261106100000_technician_leave_request migration is applied:
// technician_leave_requests missing entirely (42P01), a missing column on it
// (42703), or a leave RPC (e.g. request_technician_leave, decide_technician_leave)
// not defined yet (42883).

describe("isUndefinedTableError", () => {
  it("is true for Postgres 42P01 (missing-table failure, e.g. technician_leave_requests not migrated yet)", () => {
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
  it("is true for Postgres 42883 (missing RPC, e.g. request_technician_leave not migrated yet)", () => {
    expect(isUndefinedFunctionError({ code: "42883" })).toBe(true)
  })
  it("is false for an unrelated error code", () => {
    expect(isUndefinedFunctionError({ code: "23505" })).toBe(false)
  })
})

describe("isNotYetAvailableError", () => {
  it("is true for any of the three deploy-order codes (missing-feature failure)", () => {
    expect(isNotYetAvailableError({ code: "42P01" })).toBe(true)
    expect(isNotYetAvailableError({ code: "42703" })).toBe(true)
    expect(isNotYetAvailableError({ code: "42883" })).toBe(true)
  })

  it("is false for a genuine save/load failure unrelated to a missing schema object (generic failure)", () => {
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
