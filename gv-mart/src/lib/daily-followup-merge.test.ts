import { describe, expect, it } from "vitest"
import { mergeBuckets, postServiceVisible } from "./daily-followup-merge"

const lead = (id: string, bucket: string, due_at: string) => ({ id, bucket, due_at })
const post = (id: string, bucket: string, due_at: string) => ({ id, bucket, due_at })

describe("mergeBuckets", () => {
  it("puts each row in its bucket and sorts by due time across both kinds", () => {
    const m = mergeBuckets(
      [lead("l1", "today", "2026-10-13T10:00:00Z"), lead("l2", "overdue", "2026-10-11T10:00:00Z"), lead("l3", "today", "2026-10-13T06:00:00Z")],
      [post("p1", "today", "2026-10-13T08:00:00Z"), post("p2", "overdue", "2026-10-10T10:00:00Z"), post("p3", "upcoming", "2026-10-15T10:00:00Z")]
    )
    expect(m.today.map((x) => x.item.id)).toEqual(["l3", "p1", "l1"])
    expect(m.overdue.map((x) => x.item.id)).toEqual(["p2", "l2"])
    expect(m.upcoming.map((x) => x.item.id)).toEqual(["p3"])
    expect(m.today.map((x) => x.type)).toEqual(["lead", "post", "lead"])
  })
  it("drops buckets that are not shown (later) and tolerates missing lists", () => {
    const m = mergeBuckets([lead("l1", "later", "2026-12-01T00:00:00Z")], undefined)
    expect(m.overdue).toEqual([])
    expect(m.today).toEqual([])
    expect(m.upcoming).toEqual([])
    expect(mergeBuckets(undefined, undefined).today).toEqual([])
  })
  it("does not change what the lead list alone would show", () => {
    const leads = [lead("a", "overdue", "2026-10-01T00:00:00Z"), lead("b", "overdue", "2026-10-02T00:00:00Z"), lead("c", "today", "2026-10-13T00:00:00Z")]
    const withPosts = mergeBuckets(leads, [])
    const without = mergeBuckets(leads, undefined)
    expect(withPosts).toEqual(without)
    expect(withPosts.overdue.map((x) => x.item.id)).toEqual(["a", "b"])
  })
})

describe("postServiceVisible", () => {
  it("shows post-service calls when no lead-only filter is on", () => {
    expect(postServiceVisible({})).toBe(true)
    expect(postServiceVisible({ kind: "service" })).toBe(true)
  })
  it("hides them for a stage, a source, stuck-only, or another kind", () => {
    expect(postServiceVisible({ stage: "new" })).toBe(false)
    expect(postServiceVisible({ source: "whatsapp" })).toBe(false)
    expect(postServiceVisible({ stuckOnly: true })).toBe(false)
    expect(postServiceVisible({ kind: "product" })).toBe(false)
    expect(postServiceVisible({ kind: "warranty" })).toBe(false)
  })
})
