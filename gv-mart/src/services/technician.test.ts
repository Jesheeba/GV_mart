import { describe, expect, it } from "vitest"
import { computeRouteOrder, findOpenVisit, isChargeableTicketType, isTicketClosed, selectNextJob, type RoutableJob } from "./technician"

describe("findOpenVisit", () => {
  it("returns null for an empty list", () => {
    expect(findOpenVisit([])).toBeNull()
  })

  it("returns null when no visit is open (all closed, or none started)", () => {
    const visits = [
      { id: "1", timer_start: "2026-07-10T09:00:00Z", timer_end: "2026-07-10T09:30:00Z" },
      { id: "2", timer_start: null, timer_end: null },
    ]
    expect(findOpenVisit(visits)).toBeNull()
  })

  it("finds the single open visit (timer_start set, timer_end not set) among closed ones", () => {
    const visits = [
      { id: "1", timer_start: "2026-07-10T09:00:00Z", timer_end: "2026-07-10T09:30:00Z" },
      { id: "2", timer_start: "2026-07-10T10:00:00Z", timer_end: null },
      { id: "3", timer_start: null, timer_end: null },
    ]
    expect(findOpenVisit(visits)?.id).toBe("2")
  })

  it("returns the first match when multiple are (unexpectedly) open", () => {
    const visits = [
      { id: "1", timer_start: "2026-07-10T09:00:00Z", timer_end: null },
      { id: "2", timer_start: "2026-07-10T10:00:00Z", timer_end: null },
    ]
    expect(findOpenVisit(visits)?.id).toBe("1")
  })

  it("does not treat a visit with no timer_start as open even if timer_end is also null", () => {
    const visits = [{ id: "1", timer_start: null, timer_end: null }]
    expect(findOpenVisit(visits)).toBeNull()
  })
})

describe("isTicketClosed", () => {
  it("is true for completed", () => {
    expect(isTicketClosed("completed")).toBe(true)
  })
  it("is true for cancelled", () => {
    expect(isTicketClosed("cancelled")).toBe(true)
  })
  it("is false for open", () => {
    expect(isTicketClosed("open")).toBe(false)
  })
  it("is false for assigned", () => {
    expect(isTicketClosed("assigned")).toBe(false)
  })
  it("is false for in_progress", () => {
    expect(isTicketClosed("in_progress")).toBe(false)
  })
  it("is false for null/undefined", () => {
    expect(isTicketClosed(null)).toBe(false)
    expect(isTicketClosed(undefined)).toBe(false)
  })
})

describe("isChargeableTicketType", () => {
  it("is chargeable for paid", () => {
    expect(isChargeableTicketType("paid")).toBe(true)
  })
  it("is chargeable for installation", () => {
    expect(isChargeableTicketType("installation")).toBe(true)
  })
  it("is not chargeable for warranty", () => {
    expect(isChargeableTicketType("warranty")).toBe(false)
  })
  it("is not chargeable for amc", () => {
    expect(isChargeableTicketType("amc")).toBe(false)
  })
  it("is not chargeable for null", () => {
    expect(isChargeableTicketType(null)).toBe(false)
  })
})

// ── computeRouteOrder / selectNextJob (Build Order STEP 5, Assignment spec Phase 4) ──

type TestJob = RoutableJob & { id: string }

function makeJob(id: string, opts: { lat?: number | null; lng?: number | null; from?: string | null; to?: string | null; durationMinutes?: number | null } = {}): TestJob {
  return {
    id,
    available_from: opts.from ?? null,
    available_to: opts.to ?? null,
    service_tickets: {
      estimated_duration_minutes: opts.durationMinutes ?? null,
      addresses: opts.lat === undefined && opts.lng === undefined ? { lat: 0, lng: 0 } : { lat: opts.lat ?? null, lng: opts.lng ?? null },
    },
  }
}

const START = { lat: 0, lng: 0 }
// Local-time constructor (not UTC) so getHours()/getMinutes() inside
// computeRouteOrder read back exactly 09:00 regardless of the machine's
// timezone running the test.
const NINE_AM = new Date(2026, 6, 21, 9, 0)

describe("computeRouteOrder / selectNextJob", () => {
  it("verification gate 4: a nearer job with a closed window is skipped for a farther open one, then returned to (A -> C -> B)", () => {
    const b = makeJob("B", { lat: 0.01, lng: 0, from: "17:00:00", to: "18:00:00" }) // near, closed at 9am
    const c = makeJob("C", { lat: 0.05, lng: 0 }) // farther, no window = always open

    const order = computeRouteOrder([b, c], START, NINE_AM, 5)
    expect(order.map((j) => j.id)).toEqual(["C", "B"])
    expect(selectNextJob([b, c], START, NINE_AM, 5)?.id).toBe("C")
  })

  it("orders strictly nearest-first when every window is open (null = unconstrained)", () => {
    const near = makeJob("near", { lat: 0.01, lng: 0 })
    const far = makeJob("far", { lat: 0.05, lng: 0 })

    expect(computeRouteOrder([far, near], START, NINE_AM, 5).map((j) => j.id)).toEqual(["near", "far"])
  })

  it("treats a window with only ONE bound set as unconstrained (permissive when either side is null)", () => {
    const partial = makeJob("partial", { lat: 0.01, lng: 0, from: "09:00:00", to: null })
    expect(computeRouteOrder([partial], START, NINE_AM, 5).map((j) => j.id)).toEqual(["partial"])
  })

  it("sorts jobs missing geocoded coordinates last, but still includes them", () => {
    const located = makeJob("located", { lat: 0.05, lng: 0 })
    const unlocated = makeJob("unlocated", { lat: null, lng: null })

    expect(computeRouteOrder([unlocated, located], START, NINE_AM, 5).map((j) => j.id)).toEqual(["located", "unlocated"])
  })

  it("falls back to the nearest job when NO remaining job's window is open (never stalls the route)", () => {
    const onlyJob = makeJob("onlyJob", { lat: 0.01, lng: 0, from: "17:00:00", to: "18:00:00" })
    expect(computeRouteOrder([onlyJob], START, NINE_AM, 5).map((j) => j.id)).toEqual(["onlyJob"])
  })

  it("returns an empty route / null next job for an empty job list", () => {
    expect(computeRouteOrder([], START, NINE_AM, 5)).toEqual([])
    expect(selectNextJob([], START, NINE_AM, 5)).toBeNull()
  })
})
