import { describe, expect, it } from "vitest"
import { buildDayLegs, classifyRouteTrail, mergeDayLegs, sliceTrailForWindow, type DayJobInput, type DayVisitInput, type RouteTrailPoint } from "./routeColor"

// Shared test fixture: a technician driving due north toward a destination
// ~2.2 km away, one ping roughly every ~1.11 km step (0.01 deg latitude).
// perKmMinutes = 5 matches v2.2's documented "1 km = 5 min" default rate.
const PER_KM_MINUTES = 5
const DESTINATION = { lat: 13.1027, lng: 80.2707 } // ~2.22 km north of the origin below
const ORIGIN = { lat: 13.0827, lng: 80.2707 }

function iso(minutesFromEpoch: number) {
  return new Date(minutesFromEpoch * 60_000).toISOString()
}

describe("classifyRouteTrail", () => {
  it("marks a steady, on-pace approach toward the destination green", () => {
    // Each ~1.11 km step in ~5.5 min at the 5 min/km rate is exactly on
    // pace; using 5 min gaps here is comfortably under (faster than)
    // expected, so every segment should classify as green.
    const trail: RouteTrailPoint[] = [
      { lat: ORIGIN.lat, lng: ORIGIN.lng, recordedAt: iso(0) },
      { lat: 13.0927, lng: 80.2707, recordedAt: iso(5) },
      { lat: 13.1027, lng: 80.2707, recordedAt: iso(10) },
    ]
    const result = classifyRouteTrail(trail, { perKmMinutes: PER_KM_MINUTES, destination: DESTINATION, dueAt: null })
    expect(result.segments).toHaveLength(2)
    expect(result.segments.every((s) => s.color === "green")).toBe(true)
    expect(result.idleSpots).toHaveLength(0)
  })

  it("marks a slower-than-expected approach yellow", () => {
    // Same spatial steps, but each leg takes 10 min instead of ~5.5 —
    // 1.8x the expected pace, over the 1.4x SLOW_PACE_RATIO threshold.
    const trail: RouteTrailPoint[] = [
      { lat: ORIGIN.lat, lng: ORIGIN.lng, recordedAt: iso(0) },
      { lat: 13.0927, lng: 80.2707, recordedAt: iso(10) },
      { lat: 13.1027, lng: 80.2707, recordedAt: iso(20) },
    ]
    const result = classifyRouteTrail(trail, { perKmMinutes: PER_KM_MINUTES, destination: DESTINATION, dueAt: null })
    expect(result.segments).toHaveLength(2)
    expect(result.segments.every((s) => s.color === "yellow")).toBe(true)
  })

  it("marks segments yellow once past the job's due time, even at a fine pace", () => {
    const dueAt = iso(2) // due 2 minutes after the trail starts
    const trail: RouteTrailPoint[] = [
      { lat: ORIGIN.lat, lng: ORIGIN.lng, recordedAt: iso(0) },
      { lat: 13.0927, lng: 80.2707, recordedAt: iso(5) },
      { lat: 13.1027, lng: 80.2707, recordedAt: iso(10) },
    ]
    const result = classifyRouteTrail(trail, { perKmMinutes: PER_KM_MINUTES, destination: DESTINATION, dueAt })
    expect(result.segments.every((s) => s.color === "yellow")).toBe(true)
  })

  it("marks movement away from the destination yellow, not green", () => {
    const trail: RouteTrailPoint[] = [
      { lat: 13.1027, lng: 80.2707, recordedAt: iso(0) },
      { lat: 13.0927, lng: 80.2707, recordedAt: iso(5) }, // stepping away from DESTINATION
    ]
    const result = classifyRouteTrail(trail, { perKmMinutes: PER_KM_MINUTES, destination: DESTINATION, dueAt: null })
    expect(result.segments[0].color).toBe("yellow")
  })

  it("marks a stationary spot red and reports it as a distinct idle spot", () => {
    // Three pings clustered within ~30 m of each other, spanning 12 minutes
    // — over IDLE_TIME_THRESHOLD_MINUTES (10) and within
    // IDLE_DISTANCE_THRESHOLD_KM (0.05 km).
    const trail: RouteTrailPoint[] = [
      { lat: 13.09, lng: 80.27, recordedAt: iso(0) },
      { lat: 13.0901, lng: 80.2701, recordedAt: iso(6) },
      { lat: 13.09, lng: 80.27, recordedAt: iso(12) },
    ]
    const result = classifyRouteTrail(trail, { perKmMinutes: PER_KM_MINUTES, destination: DESTINATION, dueAt: null })
    expect(result.segments).toHaveLength(2)
    expect(result.segments.every((s) => s.color === "red")).toBe(true)
    expect(result.idleSpots).toHaveLength(1)
    expect(result.idleSpots[0].idleMinutes).toBe(12)
    expect(result.idleSpots[0].point).toEqual(trail[0])
  })

  it("does not flag a short stop under the idle time threshold as idle", () => {
    // Same tight cluster, but only 4 minutes elapsed — under
    // IDLE_TIME_THRESHOLD_MINUTES (10), so this must not read as idle. With
    // no real movement (progressKm effectively 0) it falls through to the
    // "no progress" yellow branch instead of green.
    const trail: RouteTrailPoint[] = [
      { lat: 13.09, lng: 80.27, recordedAt: iso(0) },
      { lat: 13.0901, lng: 80.2701, recordedAt: iso(4) },
    ]
    const result = classifyRouteTrail(trail, { perKmMinutes: PER_KM_MINUTES, destination: DESTINATION, dueAt: null })
    expect(result.idleSpots).toHaveLength(0)
    expect(result.segments[0].color).not.toBe("red")
  })

  it("returns no segments for a trail with fewer than 2 points", () => {
    expect(classifyRouteTrail([], { perKmMinutes: 5, destination: null, dueAt: null })).toEqual({ segments: [], idleSpots: [] })
    expect(
      classifyRouteTrail([{ lat: 1, lng: 1, recordedAt: iso(0) }], { perKmMinutes: 5, destination: null, dueAt: null })
    ).toEqual({ segments: [], idleSpots: [] })
  })

  it("falls back to raw-distance progress when no destination is known (e.g. the trailing leg)", () => {
    const trail: RouteTrailPoint[] = [
      { lat: ORIGIN.lat, lng: ORIGIN.lng, recordedAt: iso(0) },
      { lat: 13.0927, lng: 80.2707, recordedAt: iso(5) },
    ]
    const result = classifyRouteTrail(trail, { perKmMinutes: PER_KM_MINUTES, destination: null, dueAt: null })
    expect(result.segments[0].color).toBe("green")
  })
})

describe("sliceTrailForWindow", () => {
  it("keeps only points within the [start, end] window, inclusive", () => {
    const trail: RouteTrailPoint[] = [
      { lat: 0, lng: 0, recordedAt: iso(0) },
      { lat: 0, lng: 0, recordedAt: iso(5) },
      { lat: 0, lng: 0, recordedAt: iso(10) },
    ]
    expect(sliceTrailForWindow(trail, iso(5), iso(10))).toEqual([trail[1], trail[2]])
  })
})

describe("mergeDayLegs", () => {
  it("attaches visit timing onto a matching job by ticket id", () => {
    const jobs: DayJobInput[] = [{ ticketId: "t1", scheduledAt: "2026-07-23T09:00:00Z", lat: 13, lng: 80, customerName: "Asha" }]
    const visits: DayVisitInput[] = [{ ticketId: "t1", timerStart: "2026-07-23T09:10:00Z", timerEnd: "2026-07-23T09:40:00Z" }]
    const legs = mergeDayLegs(jobs, visits)
    expect(legs).toHaveLength(1)
    expect(legs[0]).toMatchObject({ ticketId: "t1", customerName: "Asha", timerStart: "2026-07-23T09:10:00Z", timerEnd: "2026-07-23T09:40:00Z" })
  })

  it("keeps a job with no visit yet as its own leg with null timing", () => {
    const jobs: DayJobInput[] = [{ ticketId: "t2", scheduledAt: "2026-07-23T14:00:00Z", lat: 13, lng: 80 }]
    const legs = mergeDayLegs(jobs, [])
    expect(legs).toEqual([{ ticketId: "t2", customerName: null, lat: 13, lng: 80, scheduledAt: "2026-07-23T14:00:00Z", timerStart: null, timerEnd: null }])
  })

  it("keeps a visit with no matching job (e.g. it already dropped out of the active-appointment list)", () => {
    const visits: DayVisitInput[] = [{ ticketId: "t3", timerStart: "2026-07-23T08:00:00Z", timerEnd: "2026-07-23T08:30:00Z" }]
    const legs = mergeDayLegs([], visits)
    expect(legs).toEqual([{ ticketId: "t3", customerName: null, lat: null, lng: null, scheduledAt: null, timerStart: "2026-07-23T08:00:00Z", timerEnd: "2026-07-23T08:30:00Z" }])
  })
})

describe("buildDayLegs", () => {
  const dayStart = "2026-07-23T00:00:00.000Z"

  it("orders legs by actual arrival, carving the day into consecutive windows", () => {
    const legs = mergeDayLegs(
      [
        { ticketId: "a", scheduledAt: "2026-07-23T09:00:00Z", lat: 13.1, lng: 80.1, customerName: "A" },
        { ticketId: "b", scheduledAt: "2026-07-23T11:00:00Z", lat: 13.2, lng: 80.2, customerName: "B" },
      ],
      [
        { ticketId: "a", timerStart: "2026-07-23T09:05:00Z", timerEnd: "2026-07-23T09:30:00Z" },
        { ticketId: "b", timerStart: "2026-07-23T11:10:00Z", timerEnd: "2026-07-23T11:40:00Z" },
      ]
    )
    const now = "2026-07-23T12:00:00.000Z"
    const windows = buildDayLegs(legs, dayStart, now)

    // Leg to A: dayStart -> A's arrival. Leg to B: A's departure -> B's
    // arrival. Trailing leg: B's departure -> now (no more jobs today).
    expect(windows).toHaveLength(3)
    expect(windows[0]).toMatchObject({ ticketId: "a", startIso: dayStart, endIso: "2026-07-23T09:05:00Z" })
    expect(windows[1]).toMatchObject({ ticketId: "b", startIso: "2026-07-23T09:30:00Z", endIso: "2026-07-23T11:10:00Z" })
    expect(windows[2]).toMatchObject({ ticketId: null, startIso: "2026-07-23T11:40:00Z", endIso: now })
  })

  it("gives the immediate next (not-yet-visited) job a window ending now, but skips jobs further down the queue", () => {
    const legs = mergeDayLegs(
      [
        { ticketId: "next", scheduledAt: "2026-07-23T10:00:00Z", lat: 13.1, lng: 80.1 },
        { ticketId: "later", scheduledAt: "2026-07-23T15:00:00Z", lat: 13.3, lng: 80.3 },
      ],
      []
    )
    const now = "2026-07-23T09:45:00.000Z"
    const windows = buildDayLegs(legs, dayStart, now)
    expect(windows).toHaveLength(1)
    expect(windows[0]).toMatchObject({ ticketId: "next", startIso: dayStart, endIso: now })
  })

  it("emits no windows when nothing has happened yet and now equals day start", () => {
    expect(buildDayLegs([], dayStart, dayStart)).toEqual([])
  })
})
