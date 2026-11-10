import { beforeEach, describe, expect, it, vi } from "vitest"

/**
 * tasks_update_assign (20261101100000) grants UPDATE to `assignee_id = auth.uid() or assigned_by = auth.uid()`.
 * updateTask() must never write assigned_by except on an actual reassignment — writing it on every save (even to
 * the same value) silently moves that update right from the task's original assigner to whoever last saved it.
 * This pins the exact payload sent to Postgres, since that's the only thing that can regress here; the RLS
 * consequence itself is covered end to end in supabase/tests/task_completion_rule.test.sql.
 */
const state: { calls: { method: string; args: unknown[] }[] } = { calls: [] }

function builder(): unknown {
  const handler: ProxyHandler<object> = {
    get(_t, prop: string) {
      if (prop === "then") {
        return (resolve: (v: unknown) => void) => resolve({ data: { id: "task-1" }, error: null })
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

import { updateTask, type UpdateTaskInput } from "@/services/tasks"

const baseInput: UpdateTaskInput = {
  id: "task-1",
  title: "Title",
  description: null,
  assigneeId: "assignee-1",
  priority: "normal",
  dueDate: null,
  dueAt: null,
  isRecurring: false,
}
const updatePayload = () => state.calls.find((c) => c.method === "update")?.args[0] as Record<string, unknown>

beforeEach(() => {
  state.calls = []
})

describe("updateTask: assigned_by is written only on a real reassignment", () => {
  it("an unrelated edit (assignedBy omitted) does not touch assigned_by at all", async () => {
    await updateTask(baseInput)
    const payload = updatePayload()
    expect("assigned_by" in payload).toBe(false)
    expect(payload.title).toBe("Title")
  })

  it("a reassignment (assignedBy provided) writes assigned_by", async () => {
    await updateTask({ ...baseInput, assigneeId: "assignee-2", assignedBy: "assigner-1" })
    const payload = updatePayload()
    expect(payload.assigned_by).toBe("assigner-1")
    expect(payload.assignee_id).toBe("assignee-2")
  })
})
