import { describe, expect, it } from "vitest"
import { canCompleteTask, compareTasksOverdueFirst, isTaskOverdue, taskDueDay, type TaskLike } from "./task-rules"

const task = (p: Partial<TaskLike> = {}): TaskLike => ({ status: "open", due_date: null, due_at: null, assignee_id: "u1", ref_type: null, ...p })

describe("task rules", () => {
  it("overdue means not done and due before today (IST)", () => {
    expect(isTaskOverdue(task({ due_date: "2026-10-14" }), "2026-10-15")).toBe(true)
    expect(isTaskOverdue(task({ due_date: "2026-10-15" }), "2026-10-15")).toBe(false)
    expect(isTaskOverdue(task({ due_date: "2026-10-14", status: "done" }), "2026-10-15")).toBe(false)
    expect(isTaskOverdue(task(), "2026-10-15")).toBe(false)
  })

  it("uses the IST day of due_at, not the UTC day", () => {
    // 2026-10-14T19:00Z is 2026-10-15 00:30 IST
    expect(taskDueDay(task({ due_at: "2026-10-14T19:00:00Z" }))).toBe("2026-10-15")
    expect(isTaskOverdue(task({ due_at: "2026-10-14T19:00:00Z" }), "2026-10-15")).toBe(false)
    expect(isTaskOverdue(task({ due_at: "2026-10-14T17:00:00Z" }), "2026-10-15")).toBe(true) // 22:30 IST on the 14th
  })

  it("sorts overdue first (oldest first), then upcoming, undated, finished last", () => {
    const today = "2026-10-15"
    const list = [
      task({ due_date: "2026-10-20" }),
      task({ status: "done", due_date: "2026-10-01" }),
      task({}),
      task({ due_date: "2026-10-10" }),
      task({ due_date: "2026-10-13" }),
    ]
    const sorted = [...list].sort((a, b) => compareTasksOverdueFirst(a, b, today))
    expect(sorted.map((t) => (t.status === "done" ? "done" : (t.due_date ?? "none")))).toEqual(["2026-10-10", "2026-10-13", "2026-10-20", "none", "done"])
  })

  it("only the assignee finishes a task; master and operations do not finish for someone else", () => {
    expect(canCompleteTask({ assignee_id: "u1", ref_type: null }, { id: "u1", role: "technician" })).toBe(true)
    expect(canCompleteTask({ assignee_id: "u1", ref_type: null }, { id: "u2", role: "master" })).toBe(false)
    expect(canCompleteTask({ assignee_id: "u1", ref_type: null }, { id: "u2", role: "operation_admin" })).toBe(false)
    expect(canCompleteTask({ assignee_id: null, ref_type: null }, { id: "u2", role: "operation_admin" })).toBe(true)
    expect(canCompleteTask({ assignee_id: null, ref_type: null }, { id: "u2", role: "sales_admin" })).toBe(false)
    expect(canCompleteTask({ assignee_id: "u1", ref_type: null }, null)).toBe(false)
  })

  it("a purchase-order task needs a master", () => {
    expect(canCompleteTask({ assignee_id: "u1", ref_type: "purchase_order" }, { id: "u1", role: "operation_admin" })).toBe(false)
    expect(canCompleteTask({ assignee_id: "u1", ref_type: "purchase_order" }, { id: "u1", role: "master" })).toBe(true)
  })
})
