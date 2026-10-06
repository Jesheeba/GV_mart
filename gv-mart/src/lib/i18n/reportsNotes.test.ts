import { describe, expect, it } from "vitest"
import en from "./en.json"
import ta from "./ta.json"

type Tree = { [k: string]: string | Tree }
const get = (tree: Tree, path: string): string | undefined => {
  let cur: string | Tree | undefined = tree
  for (const part of path.split(".")) {
    if (cur === undefined || typeof cur === "string") return undefined
    cur = cur[part]
  }
  return typeof cur === "string" ? cur : undefined
}
const placeholders = (s: string) => [...s.matchAll(/\{\{\s*(\w+)\s*\}\}/g)].map((m) => m[1]).sort()

// Keys added or reworded by the reports SQL-aggregation work. The Tamil of every key below is a DRAFT
// that still needs a Tamil speaker's review (see docs/tamil-review-pending.md).
const KEYS = ["reports.insights.funnelNote", "reports.salesService.revenueByTypeNote", "reports.salesService.ofWhichGst", "reports.salesService.visitsCount"]

describe("reports notes: en / ta parity", () => {
  it.each(KEYS)("%s exists in both locales with the same placeholders", (key) => {
    const e = get(en as Tree, key)
    const t = get(ta as Tree, key)
    expect(e, `en ${key}`).toBeTruthy()
    expect(t, `ta ${key}`).toBeTruthy()
    expect(placeholders(t!)).toEqual(placeholders(e!))
  })

  it("the funnel note is the approved English and no longer claims pre-history leads are placed by status", () => {
    const e = get(en as Tree, "reports.insights.funnelNote")!
    expect(e).toBe("Stages come from each lead’s logged stage history. A lead with no recorded history can’t be placed at a stage, so it appears only in the totals (or as Lost).")
    expect(e).not.toMatch(/current status/i)
    const t = get(ta as Tree, "reports.insights.funnelNote")!
    expect(t).toMatch(/[஀-௿]/) // Tamil script, not an English fallback
    expect(t).not.toBe(e)
  })

  it("the Sales & Service note no longer says Service counts visits", () => {
    expect(get(en as Tree, "reports.salesService.revenueByTypeNote")).not.toMatch(/visits for Service/i)
  })
})
