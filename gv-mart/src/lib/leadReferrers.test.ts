import { describe, expect, it } from "vitest"
import { buildLeadTechnicianNames, chunk } from "./leadReferrers"

describe("buildLeadTechnicianNames", () => {
  it("maps lead id to the technician's name and skips leads without one", () => {
    const m = buildLeadTechnicianNames([
      { id: "a", owner_id: "t1", technicians: { profiles: { full_name: "Ravi" } } },
      { id: "b", owner_id: null, technicians: null },
      { id: "c", owner_id: "t2", technicians: { profiles: { full_name: null } } },
      { id: "d", owner_id: "t3", technicians: { profiles: { full_name: "  Mani " } } },
    ])
    expect([...m.entries()]).toEqual([
      ["a", "Ravi"],
      ["d", "Mani"],
    ])
  })
})

describe("chunk", () => {
  it("splits into fixed-size groups", () => {
    expect(chunk([1, 2, 3, 4, 5], 2)).toEqual([[1, 2], [3, 4], [5]])
    expect(chunk([], 3)).toEqual([])
  })
})
