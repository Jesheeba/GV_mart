/**
 * A5 — technician route trail colour classification.
 *
 * Pure, testable functions that turn a technician's `technician_locations`
 * trail (STEP TECH-04's existing live-tracking table — see
 * services/technician.ts's pingLiveLocation / techniciansAdmin.ts's
 * listRecentTechnicianLocations, both already reused here rather than
 * rebuilt) into a green/yellow/red-classified route, for two surfaces:
 *  - a single job's travel leg (technician tapping a customer's name), and
 *  - a technician's full day (admin's "Track today's movement").
 *
 * Deliberately mirrors STEP 5's computeRouteOrder in services/technician.ts:
 * a pure client-side function over data already fetched elsewhere, no new
 * schema/triggers, using the same Haversine (`distanceKm`) and
 * per-km-minutes (`expectedMinutes`) helpers from lib/offline/geo.ts that
 * MapPage/TechniciansMapPage/computeRouteOrder already share.
 */

import { distanceKm, expectedMinutes, type GeoPoint } from "@/lib/offline/geo"

/** One point in a technician's location trail — already ordered by
 * recorded_at ascending (technician_locations' natural query order, see
 * getTodaysTechnicianTrail / getTechnicianTrailForDate). */
export type RouteTrailPoint = { lat: number; lng: number; recordedAt: string }

export type RouteColor = "green" | "yellow" | "red"

/** Suggested display colours for each RouteColor — not classification logic,
 * just avoiding this hex triplet being duplicated on every map surface that
 * renders a classified route. Green/red match TechniciansMapPage's existing
 * COLOR_ON_TIME/COLOR_ALERT for visual consistency with its current-position
 * markers. */
export const ROUTE_COLOR_HEX: Record<RouteColor, string> = {
  green: "#2fae5f",
  yellow: "#e8a23d",
  red: "#e5484d",
}

export type ClassifiedRouteSegment = {
  from: RouteTrailPoint
  to: RouteTrailPoint
  color: RouteColor
}

/** A distinctly-markable idle location — rendered as its own marker/pin in
 * the UI, separate from the moving-route polyline styling (not just a red
 * line segment). */
export type IdleSpot = {
  point: RouteTrailPoint
  /** Minutes stationary at this spot, from the first point of the idle run to the last. */
  idleMinutes: number
}

export type ClassifiedRoute = {
  segments: ClassifiedRouteSegment[]
  idleSpots: IdleSpot[]
}

export type RouteLegContext = {
  /** Admin-set per-km travel rate (settings.per_km_minutes, v2.2 §6.6) — the
   * same "expected minutes" input MapPage/TechniciansMapPage already use. */
  perKmMinutes: number
  /** This leg's destination (the job/customer's geocoded address) — used to
   * judge both direction ("closing in" vs not) and pace. Null when no
   * destination is known for this leg (e.g. the trailing "back to base" /
   * not-yet-assigned leg from buildDayLegs). */
  destination: GeoPoint | null
  /** The job's scheduled/due time (appointment.scheduled_at). Once a trail
   * point falls after this without having arrived, that segment is yellow
   * regardless of its own instantaneous pace — "running late relative to the
   * job's scheduled window." Null for jobs with no fixed time (mode="always"). */
  dueAt: string | null
}

// ── Tunable thresholds ────────────────────────────────────────────────────
// Documented + adjustable, mirroring STEP 3's own "~1km bucket, tunable"
// reorder-formula precedent (see reorder migration 20260722110000) rather
// than hard-coding-and-hiding a magic number.

/**
 * How long a technician must stay within IDLE_DISTANCE_THRESHOLD_KM of one
 * spot before it's flagged red/idle, rather than left as an ordinary (green/
 * yellow) segment. Chosen to sit between TechniciansMapPage's coarser
 * fleet-wide IDLE_TRIGGER_MINUTES (5 min — a "flag this technician now"
 * signal for the whole live map) and a typical on-site service visit (often
 * 15-45+ min): long enough that a genuine customer visit, a red light, or a
 * short stop isn't misread as "stuck," short enough to still catch a
 * technician who is actually stalled or lost mid-route within the working
 * day. Tunable — raise it if idle spots fire too eagerly on normal short
 * stops, lower it to flag idling sooner.
 */
const IDLE_TIME_THRESHOLD_MINUTES = 10

/**
 * Same order of magnitude as TechniciansMapPage's own IDLE_MOVE_THRESHOLD_KM
 * (0.05 km / 50 m) — ordinary GPS drift on a stationary phone commonly
 * wanders 10-30 m, so movement under this threshold isn't real travel.
 * Tunable.
 */
const IDLE_DISTANCE_THRESHOLD_KM = 0.05

/**
 * A moving segment is coloured yellow ("slower than expected") once its
 * actual travel time exceeds this multiple of the expected-minutes-per-km
 * estimate (lib/offline/geo.ts's expectedMinutes). 1.4x sits below
 * TechniciansMapPage's OFF_ROUTE_RATIO (1.6x, for a route distinctly longer
 * than straight-line distance) because pace is a softer, noisier signal than
 * a route-distance ratio — a lower bar catches "running behind" sooner.
 * Tunable.
 */
const SLOW_PACE_RATIO = 1.4

function minutesBetween(aIso: string, bIso: string): number {
  return (new Date(bIso).getTime() - new Date(aIso).getTime()) / 60_000
}

/**
 * Classifies one leg of a technician's trail (one destination, one due time
 * — see buildDayLegs below for splitting a full day into legs first) into
 * green/yellow/red segments plus distinctly-marked idle spots.
 *
 *  - red / idle: any maximal run of points that stays within
 *    IDLE_DISTANCE_THRESHOLD_KM of its first point for at least
 *    IDLE_TIME_THRESHOLD_MINUTES. Every segment inside that run is red, and
 *    the run's anchor point is additionally reported as an IdleSpot (with
 *    its own duration) so the UI can mark it with a distinct
 *    marker/pin — not just a coloured line.
 *  - yellow / slow-or-late: a non-idle segment where either (a) the
 *    technician is already past `dueAt` for this leg (late against the
 *    job's scheduled window, regardless of this segment's own pace), or
 *    (b) it isn't closing distance toward `destination` at all (wrong
 *    direction / no progress), or (c) it IS closing distance but slower
 *    than SLOW_PACE_RATIO times the expected pace.
 *  - green: everything else — moving, the right direction, roughly on the
 *    expected pace.
 */
export function classifyRouteTrail(trail: RouteTrailPoint[], context: RouteLegContext): ClassifiedRoute {
  const { perKmMinutes, destination, dueAt } = context
  const segments: ClassifiedRouteSegment[] = []
  const idleSpots: IdleSpot[] = []
  if (trail.length < 2) return { segments, idleSpots }

  // Pass 1 — idle-run detection: walk forward, extending the current run
  // while each new point stays within IDLE_DISTANCE_THRESHOLD_KM of the
  // run's anchor; once a point breaks free (or the trail ends), flush the
  // run as idle if it lasted at least IDLE_TIME_THRESHOLD_MINUTES.
  const idleFlags = new Array<boolean>(trail.length).fill(false)
  let anchorIndex = 0
  for (let i = 1; i <= trail.length; i++) {
    const atEnd = i === trail.length
    const broke = atEnd || distanceKm(trail[anchorIndex], trail[i]) > IDLE_DISTANCE_THRESHOLD_KM
    if (!broke) continue
    const runEnd = i - 1
    if (runEnd > anchorIndex) {
      const durationMin = minutesBetween(trail[anchorIndex].recordedAt, trail[runEnd].recordedAt)
      if (durationMin >= IDLE_TIME_THRESHOLD_MINUTES) {
        for (let j = anchorIndex; j <= runEnd; j++) idleFlags[j] = true
        idleSpots.push({ point: trail[anchorIndex], idleMinutes: durationMin })
      }
    }
    anchorIndex = i
  }

  // Pass 2 — per-segment colour.
  for (let i = 1; i < trail.length; i++) {
    const prev = trail[i - 1]
    const curr = trail[i]

    if (idleFlags[i - 1] && idleFlags[i]) {
      segments.push({ from: prev, to: curr, color: "red" })
      continue
    }

    const isLate = dueAt != null && new Date(curr.recordedAt).getTime() > new Date(dueAt).getTime()
    if (isLate) {
      segments.push({ from: prev, to: curr, color: "yellow" })
      continue
    }

    const dtMin = minutesBetween(prev.recordedAt, curr.recordedAt)
    const progressKm = destination ? distanceKm(prev, destination) - distanceKm(curr, destination) : distanceKm(prev, curr)

    if (progressKm <= 0) {
      // Moving, but not toward the destination (or destination unknown and
      // there was no measurable movement at all — already handled by the
      // idle pass above in the latter case).
      segments.push({ from: prev, to: curr, color: "yellow" })
      continue
    }

    const expectedMin = expectedMinutes(progressKm, perKmMinutes)
    const paceRatio = expectedMin > 0 ? dtMin / expectedMin : 0
    segments.push({ from: prev, to: curr, color: paceRatio > SLOW_PACE_RATIO ? "yellow" : "green" })
  }

  return { segments, idleSpots }
}

// ── Splitting a technician's full day into per-job legs ────────────────────
// computeRouteOrder (services/technician.ts, STEP 5) decides which job is
// next going forward; the pair below instead looks backward at what already
// happened today, purely from timer_start/timer_end + scheduled_at, so
// classifyRouteTrail can run once per leg against that leg's own
// destination/due-time context instead of averaging the whole day as one
// undifferentiated trail.

export type DayJobInput = {
  ticketId: string
  scheduledAt: string | null
  lat: number | null
  lng: number | null
  customerName?: string | null
}

export type DayVisitInput = {
  ticketId: string
  timerStart: string | null
  timerEnd: string | null
}

export type DayLeg = {
  ticketId: string
  customerName: string | null
  lat: number | null
  lng: number | null
  scheduledAt: string | null
  timerStart: string | null
  timerEnd: string | null
}

/**
 * Merges a technician's today's jobs (appointment/ticket data — customer,
 * address, scheduled time) with today's service_visits (actual
 * timer_start/timer_end) into one row per ticket. Two independent inputs
 * because a still-upcoming job has no service_visits row yet (one is only
 * created on arrival — see queueStartVisit's doc comment), while a job
 * completed earlier today may have already fallen out of an "active
 * appointment" list once its status flipped away from scheduled/in_progress.
 */
export function mergeDayLegs(jobs: DayJobInput[], visits: DayVisitInput[]): DayLeg[] {
  const byTicket = new Map<string, DayLeg>()
  for (const j of jobs) {
    byTicket.set(j.ticketId, {
      ticketId: j.ticketId,
      customerName: j.customerName ?? null,
      lat: j.lat,
      lng: j.lng,
      scheduledAt: j.scheduledAt,
      timerStart: null,
      timerEnd: null,
    })
  }
  for (const v of visits) {
    const existing = byTicket.get(v.ticketId)
    if (existing) {
      existing.timerStart = v.timerStart
      existing.timerEnd = v.timerEnd
    } else {
      byTicket.set(v.ticketId, {
        ticketId: v.ticketId,
        customerName: null,
        lat: null,
        lng: null,
        scheduledAt: null,
        timerStart: v.timerStart,
        timerEnd: v.timerEnd,
      })
    }
  }
  return Array.from(byTicket.values())
}

export type LegWindow = {
  /** null = a trailing/leading leg with no specific destination yet (e.g.
   * heading back to base after the last job, or before the first job of the
   * day is picked up) — classifyRouteTrail still runs on it, just without a
   * destination/dueAt to judge direction/lateness against. */
  ticketId: string | null
  destination: GeoPoint | null
  dueAt: string | null
  startIso: string
  endIso: string
}

/**
 * Orders a technician's legs by each job's actual arrival (timer_start) when
 * known, falling back to its scheduled time for jobs not yet reached, then
 * carves the [dayStartIso, nowIso] span into one window per leg. A job the
 * technician hasn't started today gets no window at all unless it's the very
 * next one in that order — its leg only "exists" once the running cursor
 * reaches it and there's a real time span left to explain (see the `end <=
 * cursor` skip below), so jobs further down today's queue don't spuriously
 * claim the "currently traveling" window.
 */
export function buildDayLegs(legs: DayLeg[], dayStartIso: string, nowIso: string): LegWindow[] {
  const sorted = [...legs].sort((a, b) => {
    const at = a.timerStart ?? a.scheduledAt ?? ""
    const bt = b.timerStart ?? b.scheduledAt ?? ""
    return at.localeCompare(bt)
  })

  const windows: LegWindow[] = []
  let cursor = dayStartIso
  for (const leg of sorted) {
    const end = leg.timerStart ?? leg.timerEnd ?? nowIso
    if (end <= cursor) continue // no real travel window left to explain — skip rather than emit a zero/negative-length leg
    windows.push({
      ticketId: leg.ticketId,
      destination: leg.lat != null && leg.lng != null ? { lat: leg.lat, lng: leg.lng } : null,
      dueAt: leg.scheduledAt,
      startIso: cursor,
      endIso: end,
    })
    cursor = leg.timerEnd ?? end
  }
  if (cursor < nowIso) {
    windows.push({ ticketId: null, destination: null, dueAt: null, startIso: cursor, endIso: nowIso })
  }
  return windows
}

/** Slices an ascending trail down to one leg's [startIso, endIso] window. */
export function sliceTrailForWindow(trail: RouteTrailPoint[], startIso: string, endIso: string): RouteTrailPoint[] {
  return trail.filter((p) => p.recordedAt >= startIso && p.recordedAt <= endIso)
}
