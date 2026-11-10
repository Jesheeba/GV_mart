import { describe, expect, it } from "vitest"
import { distinctLeadCountByActor, groupLeadIdsByActor } from "./followedByFilter"

describe("groupLeadIdsByActor", () => {
  it("groups lead ids per actor", () => {
    const result = groupLeadIdsByActor([
      { leadId: "L1", actorId: "A" },
      { leadId: "L2", actorId: "A" },
      { leadId: "L1", actorId: "B" },
    ])
    expect(result.get("A")).toEqual(new Set(["L1", "L2"]))
    expect(result.get("B")).toEqual(new Set(["L1"]))
  })

  it("returns an empty map for no activity", () => {
    expect(groupLeadIdsByActor([]).size).toBe(0)
  })
})

describe("distinctLeadCountByActor", () => {
  it("counts DISTINCT leads, not activity rows — a person logging 5 notes on the same lead counts once", () => {
    const pairs = [
      { leadId: "L1", actorId: "A" },
      { leadId: "L1", actorId: "A" },
      { leadId: "L1", actorId: "A" },
      { leadId: "L1", actorId: "A" },
      { leadId: "L1", actorId: "A" },
    ]
    expect(distinctLeadCountByActor(pairs).get("A")).toBe(1)
  })

  it("counts correctly across multiple actors and leads", () => {
    const pairs = [
      { leadId: "L1", actorId: "A" },
      { leadId: "L2", actorId: "A" },
      { leadId: "L1", actorId: "B" },
      { leadId: "L2", actorId: "B" },
      { leadId: "L3", actorId: "B" },
    ]
    const counts = distinctLeadCountByActor(pairs)
    expect(counts.get("A")).toBe(2)
    expect(counts.get("B")).toBe(3)
  })
})
