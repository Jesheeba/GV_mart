import { describe, expect, it } from "vitest"
import { isTaskOverdue, sortOverdueFirst, type OverdueTaskLike } from "./task-overdue"

// 2026-10-20 10:00 IST
const NOW = new Date("2026-10-20T04:30:00.000Z")

const t = (over: Partial<OverdueTaskLike> & { id?: string }): OverdueTaskLike & { id: string } => ({
  id: over.id ?? "x",
  status: "open",
  due_date: null,
  due_at: null,
  ...over,
})

describe("isTaskOverdue", () => {
  it("is never overdue when done", () => {
    expect(isTaskOverdue(t({ status: "done", due_date: "2026-10-01" }), NOW)).toBe(false)
  })
  it("is not overdue without a deadline", () => {
    expect(isTaskOverdue(t({}), NOW)).toBe(false)
  })
  it("date-only task due today is not overdue; due yesterday is", () => {
    expect(isTaskOverdue(t({ due_date: "2026-10-20" }), NOW)).toBe(false)
    expect(isTaskOverdue(t({ due_date: "2026-10-19" }), NOW)).toBe(true)
  })
  it("due_at is compared as an instant and wins over due_date", () => {
    expect(isTaskOverdue(t({ due_at: "2026-10-20T04:00:00.000Z", due_date: "2026-10-25" }), NOW)).toBe(true)
    expect(isTaskOverdue(t({ due_at: "2026-10-20T05:00:00.000Z", due_date: "2026-10-01" }), NOW)).toBe(false)
  })
  it("uses the IST date, not the UTC date, around midnight", () => {
    // 2026-10-20 01:00 IST is still 2026-10-19 in UTC
    const earlyIst = new Date("2026-10-19T19:30:00.000Z")
    expect(isTaskOverdue(t({ due_date: "2026-10-19" }), earlyIst)).toBe(true)
    expect(isTaskOverdue(t({ due_date: "2026-10-20" }), earlyIst)).toBe(false)
  })
})

describe("sortOverdueFirst", () => {
  it("puts overdue first (longest overdue on top), then upcoming, undated, then done", () => {
    const sorted = sortOverdueFirst(
      [
        t({ id: "done", status: "done", due_date: "2026-10-01" }),
        t({ id: "undated" }),
        t({ id: "later", due_date: "2026-10-30" }),
        t({ id: "overdue-recent", due_date: "2026-10-19" }),
        t({ id: "overdue-old", due_date: "2026-10-02" }),
        t({ id: "today", due_date: "2026-10-20" }),
      ],
      NOW
    )
    expect(sorted.map((x) => (x as { id: string }).id)).toEqual(["overdue-old", "overdue-recent", "today", "later", "undated", "done"])
  })
  it("does not mutate the input", () => {
    const input = [t({ id: "b", due_date: "2026-10-30" }), t({ id: "a", due_date: "2026-10-01" })]
    sortOverdueFirst(input, NOW)
    expect((input[0] as { id: string }).id).toBe("b")
  })
})
