import { describe, expect, it, vi } from "vitest"

/**
 * Karthik Raja archive, item 2(a) (2026-11-02) — listTechnicians backs every
 * manual technician dropdown (ticket reassign, New Complaint, appointment
 * assign, AMC/sale technician pick). Once a technician is archived
 * (is_active=false), they must stop being a selectable option here. This
 * does NOT affect display of an already-assigned inactive technician's name
 * on an existing ticket/appointment — that comes from a separate joined
 * `technicians` relation on the record itself, never from this list.
 */
const calls: { table: string; method: string; args: unknown[] }[] = []

const TECH_ROWS = [
  { id: "active-1", profiles: { full_name: "Aakash" } },
  { id: "active-2", profiles: { full_name: "V.A.Subash" } },
]

function fromBuilder(table: string): unknown {
  const handler: ProxyHandler<object> = {
    get(_t, prop: string) {
      if (prop === "then") {
        return (resolve: (v: unknown) => void) => {
          if (table === "technicians") return resolve({ data: TECH_ROWS, error: null })
          return resolve({ data: [], error: null }) // attendance: nobody on duty, irrelevant to this test
        }
      }
      return (...args: unknown[]) => {
        calls.push({ table, method: prop, args })
        return proxy
      }
    },
  }
  const proxy: unknown = new Proxy({}, handler)
  return proxy
}

vi.mock("@/lib/supabase", () => ({
  supabase: { from: (table: string) => fromBuilder(table) },
}))

vi.mock("@/lib/ist", () => ({
  getIstNow: () => ({ date: "2026-11-02" }),
  istDateOf: (d: string) => d,
}))

import { listTechnicians } from "@/services/service"

describe("listTechnicians", () => {
  it("filters the technicians table to is_active=true (never offers an archived technician as a selectable option)", async () => {
    calls.length = 0
    await listTechnicians("org-1")
    expect(calls).toEqual(
      expect.arrayContaining([
        { table: "technicians", method: "eq", args: ["org_id", "org-1"] },
        { table: "technicians", method: "eq", args: ["is_active", true] },
      ])
    )
  })

  it("returns the server-filtered rows mapped to id/full_name/is_on_duty (whatever the query returns is already active-only)", async () => {
    const result = await listTechnicians("org-1")
    expect(result).toEqual([
      { id: "active-1", full_name: "Aakash", is_on_duty: false },
      { id: "active-2", full_name: "V.A.Subash", is_on_duty: false },
    ])
  })
})
