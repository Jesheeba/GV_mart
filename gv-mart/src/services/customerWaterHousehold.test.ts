import { beforeEach, describe, expect, it, vi } from "vitest"

/**
 * build-docs/features/customer-water-household.md + water-solution-followup.md — the exact writes the Water &
 * household save sends: which customers columns, which RPC, with which arguments, in which order, and when the
 * follow-up task is (not) touched. The DB rules themselves are covered by supabase/tests/customer_water_household_v2.test.sql.
 */
const state: { calls: { kind: string; method: string; args: unknown[] }[]; rpcResult: { data: unknown; error: unknown } } = {
  calls: [],
  rpcResult: { data: null, error: null },
}

function builder(kind: string): unknown {
  const handler: ProxyHandler<object> = {
    get(_t, prop: string) {
      if (prop === "then") return (resolve: (v: unknown) => void) => resolve({ data: null, error: null })
      return (...args: unknown[]) => {
        state.calls.push({ kind, method: prop, args })
        return proxy
      }
    },
  }
  const proxy: unknown = new Proxy({}, handler)
  return proxy
}

vi.mock("@/lib/supabase", () => ({
  supabase: {
    from: (table: string) => builder(`from:${table}`),
    rpc: (name: string, args: unknown) => {
      state.calls.push({ kind: "rpc", method: name, args: [args] })
      return Promise.resolve(state.rpcResult)
    },
  },
}))

import {
  getCustomerWaterFollowup,
  getCustomer,
  saveWaterHousehold,
  setCustomerWaterFollowup,
  postponeWaterFollowup,
  closeWaterFollowupAsLead,
  updateMember,
} from "@/services/customers"
import { getMyCustomerRecord } from "@/services/customerApp"

const rpcCalls = () => state.calls.filter((c) => c.kind === "rpc")
const updatePayload = () => state.calls.find((c) => c.kind === "from:customers" && c.method === "update")?.args[0] as Record<string, unknown> | undefined

const patch = {
  waterSource: "borewater" as const,
  waterSourceOther: null,
  waterTdsPpm: 400,
  waterPh: 7,
  waterHardnessPpm: 320,
  householdProblems: ["Hair fall"],
  waterRecommendedSolution: "Softener",
}

beforeEach(() => {
  state.calls = []
  state.rpcResult = { data: null, error: null }
})

describe("saveWaterHousehold", () => {
  it("WH-4: writes hardness, problems and solution to the customers row (no address write, no health table)", async () => {
    await saveWaterHousehold({ customerId: "c1", patch, profileDirty: true, followUpDate: null, savedFollowUpDate: null })
    expect(updatePayload()).toEqual({
      water_source: "borewater",
      water_source_other: null,
      water_tds_ppm: 400,
      water_ph: 7,
      water_hardness_ppm: 320,
      household_problems: ["Hair fall"],
      water_recommended_solution: "Softener",
    })
    expect(state.calls.some((c) => c.kind === "from:addresses" || c.kind === "from:customer_health_profile")).toBe(false)
    expect(state.calls.find((c) => c.method === "eq")?.args).toEqual(["id", "c1"])
  })

  it("FU-1: a new date writes the profile FIRST, then sets the follow-up (task description is current)", async () => {
    await saveWaterHousehold({ customerId: "c1", patch, profileDirty: true, followUpDate: "2026-12-05", savedFollowUpDate: null })
    const updateIdx = state.calls.findIndex((c) => c.method === "update")
    const rpcIdx = state.calls.findIndex((c) => c.kind === "rpc")
    expect(updateIdx).toBeGreaterThanOrEqual(0)
    expect(rpcIdx).toBeGreaterThan(updateIdx)
    expect(rpcCalls()).toEqual([{ kind: "rpc", method: "set_customer_water_followup", args: [{ p_customer_id: "c1", p_due_date: "2026-12-05" }] }])
  })

  it("FU-2: only the date changed — no profile write, the follow-up moves", async () => {
    await saveWaterHousehold({ customerId: "c1", patch, profileDirty: false, followUpDate: "2026-12-09", savedFollowUpDate: "2026-12-05" })
    expect(updatePayload()).toBeUndefined()
    expect(rpcCalls()[0].args[0]).toEqual({ p_customer_id: "c1", p_due_date: "2026-12-09" })
  })

  it("FU-3: clearing the date sends null (closes the task)", async () => {
    await saveWaterHousehold({ customerId: "c1", patch, profileDirty: false, followUpDate: null, savedFollowUpDate: "2026-12-05" })
    expect(rpcCalls()[0].args[0]).toEqual({ p_customer_id: "c1", p_due_date: null })
  })

  it("FU-edge: profile changed with an unchanged date refreshes the task description", async () => {
    await saveWaterHousehold({ customerId: "c1", patch, profileDirty: true, followUpDate: "2026-12-05", savedFollowUpDate: "2026-12-05" })
    expect(rpcCalls()).toHaveLength(1)
  })

  it("FU-edge: nothing changed — no writes at all", async () => {
    await saveWaterHousehold({ customerId: "c1", patch, profileDirty: false, followUpDate: "2026-12-05", savedFollowUpDate: "2026-12-05" })
    expect(state.calls).toHaveLength(0)
  })

  it("FU-edge: no date before or after and only the profile changed — no RPC", async () => {
    await saveWaterHousehold({ customerId: "c1", patch, profileDirty: true, followUpDate: null, savedFollowUpDate: null })
    expect(rpcCalls()).toHaveLength(0)
  })

  it("FU-edge: an RPC error is surfaced, not swallowed", async () => {
    state.rpcResult = { data: null, error: { message: "water follow-up: the date cannot be in the past", code: "22023" } }
    await expect(setCustomerWaterFollowup("c1", "2020-01-01")).rejects.toMatchObject({ code: "22023" })
  })
})

describe("follow-up RPC wrappers", () => {
  it("get returns the open task's id + date, or null when none", async () => {
    state.rpcResult = { data: [{ task_id: "t1", due_date: "2026-12-05" }], error: null }
    expect(await getCustomerWaterFollowup("c1")).toEqual({ taskId: "t1", dueDate: "2026-12-05" })
    state.rpcResult = { data: [], error: null }
    expect(await getCustomerWaterFollowup("c1")).toBeNull()
  })
  it("postpone and close-as-lead send the exact arguments", async () => {
    await postponeWaterFollowup("t1", "2026-12-20", "Customer travelling")
    await closeWaterFollowupAsLead("t1", "l1")
    expect(rpcCalls().map((c) => [c.method, c.args[0]])).toEqual([
      ["postpone_water_followup", { p_task_id: "t1", p_new_date: "2026-12-20", p_reason: "Customer travelling" }],
      ["close_water_followup_as_lead", { p_task_id: "t1", p_lead_id: "l1" }],
    ])
  })
})

describe("family members: moved-out members are never counted", () => {
  it("admin getCustomer filters moved_out_at and no longer reads the health table", async () => {
    await getCustomer("c1").catch(() => undefined)
    expect(state.calls.some((c) => c.method === "is" && (c.args as unknown[])[0] === "customer_members.moved_out_at")).toBe(true)
    expect(state.calls.some((c) => c.kind === "from:customer_health_profile")).toBe(false)
  })
  it("customer app getMyCustomerRecord filters moved_out_at too", async () => {
    await getMyCustomerRecord("c1").catch(() => undefined)
    expect(state.calls.some((c) => c.method === "is" && (c.args as unknown[])[0] === "customer_members.moved_out_at")).toBe(true)
  })
})

describe("SYNC-1/6: editing the primary member is ONE write (the DB copies it onto the customer row)", () => {
  it("updateMember writes customer_members only, never a second client-side customers update", async () => {
    await updateMember("m1", { name: "Ravi Kumar", mobile: "9000000001", profession: "Teacher", email: "r@x.in" }).catch(() => undefined)
    expect(state.calls.some((c) => c.kind === "from:customer_members" && c.method === "update")).toBe(true)
    expect(state.calls.some((c) => c.kind === "from:customers")).toBe(false)
  })
})
