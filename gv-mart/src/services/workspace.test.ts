import { beforeEach, describe, expect, it, vi } from "vitest"

/**
 * tasks_update_assign (20261101100000) grants UPDATE to `assignee_id = auth.uid() or assigned_by = auth.uid()`.
 * setTaskStatus and moveTaskToToday deliberately never put assigned_by in their payload — see tasks.test.ts for
 * the one path that does, conditionally. These two pin that omission so it reads as deliberate, not an oversight
 * someone "helpfully" fixes by adding the field back.
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

import { moveTaskToToday, setTaskStatus } from "@/services/workspace"

const updatePayload = () => state.calls.find((c) => c.method === "update")?.args[0] as Record<string, unknown>

beforeEach(() => {
  state.calls = []
})

describe("tasks table updates that must never carry assigned_by", () => {
  it("setTaskStatus must not send assigned_by — it is an RLS identity in tasks_update_assign, and including it transfers update permission", async () => {
    await setTaskStatus("task-1", "done")
    expect("assigned_by" in updatePayload()).toBe(false)
  })

  it("moveTaskToToday must not send assigned_by — it is an RLS identity in tasks_update_assign, and including it transfers update permission", async () => {
    await moveTaskToToday({ id: "task-1", due_date: "2026-10-20", original_due_date: null, rolled_count: 0 })
    expect("assigned_by" in updatePayload()).toBe(false)
  })
})
