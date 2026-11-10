import { describe, expect, it } from "vitest"
import { computeLeadSummaryTiles } from "./leadSummaryTiles"

describe("computeLeadSummaryTiles", () => {
  it("returns zero counts and 0% total when there are no leads", () => {
    const tiles = computeLeadSummaryTiles([])
    expect(tiles.map((t) => [t.id, t.count, t.pct])).toEqual([
      ["total", 0, 0],
      ["new", 0, 0],
      ["contacted", 0, 0],
      ["quoted", 0, 0],
      ["won", 0, 0],
      ["lost", 0, 0],
    ])
  })

  it("computes count + percentage per status, with total at 100%", () => {
    const rows = [
      { status: "new" as const },
      { status: "new" as const },
      { status: "contacted" as const },
      { status: "quoted" as const },
      { status: "won" as const },
      { status: "lost" as const },
      { status: "lost" as const },
      { status: "lost" as const },
      { status: "lost" as const },
      { status: "lost" as const },
    ]
    const tiles = computeLeadSummaryTiles(rows)
    const byId = Object.fromEntries(tiles.map((t) => [t.id, t]))
    expect(byId.total).toEqual({ id: "total", count: 10, pct: 100 })
    expect(byId.new).toEqual({ id: "new", count: 2, pct: 20 })
    expect(byId.contacted).toEqual({ id: "contacted", count: 1, pct: 10 })
    expect(byId.quoted).toEqual({ id: "quoted", count: 1, pct: 10 })
    expect(byId.won).toEqual({ id: "won", count: 1, pct: 10 })
    expect(byId.lost).toEqual({ id: "lost", count: 5, pct: 50 })
  })

  it("rounds percentages to whole numbers", () => {
    const rows = [{ status: "new" as const }, { status: "contacted" as const }, { status: "contacted" as const }]
    const tiles = computeLeadSummaryTiles(rows)
    const byId = Object.fromEntries(tiles.map((t) => [t.id, t]))
    expect(byId.new.pct).toBe(33)
    expect(byId.contacted.pct).toBe(67)
  })

  it("returns tiles in the fixed spec order: total, new, contacted, quoted, won, lost", () => {
    const tiles = computeLeadSummaryTiles([])
    expect(tiles.map((t) => t.id)).toEqual(["total", "new", "contacted", "quoted", "won", "lost"])
  })
})
