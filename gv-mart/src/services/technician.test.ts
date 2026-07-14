import { describe, expect, it } from "vitest"
import { findOpenVisit, isChargeableTicketType, isTicketClosed } from "./technician"

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
