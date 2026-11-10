import { describe, expect, it } from "vitest"
import { reminderDueAt } from "./followupReminder"

describe("reminderDueAt", () => {
  const dueAt = "2026-11-20T10:00:00.000Z"

  it("'at' offset matches the follow-up time exactly", () => {
    expect(reminderDueAt(dueAt, "at")).toBe(dueAt)
  })

  it("'15m' offset is 15 minutes before", () => {
    expect(reminderDueAt(dueAt, "15m")).toBe("2026-11-20T09:45:00.000Z")
  })

  it("'1h' offset is 1 hour before", () => {
    expect(reminderDueAt(dueAt, "1h")).toBe("2026-11-20T09:00:00.000Z")
  })

  it("'1d' offset is 1 day before", () => {
    expect(reminderDueAt(dueAt, "1d")).toBe("2026-11-19T10:00:00.000Z")
  })
})
