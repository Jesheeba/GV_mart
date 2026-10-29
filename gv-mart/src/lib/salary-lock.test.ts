import { describe, expect, it } from "vitest"
import { alreadyLoggedMessage, canLogToAccounts, canRecompute, canReopen, isSalaryLocked } from "./salary-lock"

describe("isSalaryLocked", () => {
  it("is false for a freshly computed, never-posted row", () => {
    expect(isSalaryLocked({ locked_at: null })).toBe(false)
  })
  it("is true once locked_at is set by log_salary_to_accounts", () => {
    expect(isSalaryLocked({ locked_at: "2026-10-29T10:00:00Z" })).toBe(true)
  })
})

describe("canRecompute / canLogToAccounts / canReopen", () => {
  it("an unlocked row can be recomputed and logged, but not reopened", () => {
    const row = { locked_at: null }
    expect(canRecompute(row)).toBe(true)
    expect(canLogToAccounts(row)).toBe(true)
    expect(canReopen(row)).toBe(false)
  })
  it("a locked row cannot be recomputed or re-logged, but can be reopened", () => {
    const row = { locked_at: "2026-10-29T10:00:00Z" }
    expect(canRecompute(row)).toBe(false)
    expect(canLogToAccounts(row)).toBe(false)
    expect(canReopen(row)).toBe(true)
  })
})

describe("alreadyLoggedMessage", () => {
  it("includes the date when one is given", () => {
    expect(alreadyLoggedMessage("2026-10-29")).toBe("already logged on 2026-10-29")
  })
  it("falls back to a generic phrase when no date is available", () => {
    expect(alreadyLoggedMessage(null)).toBe("already logged on an earlier date")
  })
})
