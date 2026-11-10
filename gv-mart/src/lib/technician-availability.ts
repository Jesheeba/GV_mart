/**
 * Urgent item #5 — availability-assisted scheduling for the master's
 * create/assign-complaint flow. Pure, server-mirroring logic only; the
 * actual data comes from the read-only RPC get_technician_availability_for_date
 * (20261202100000_master_technician_availability_rpc.sql), and actual
 * booking/assignment always goes through the existing create_complaint_ticket
 * / assign_ticket_technician RPCs — nothing here writes anything.
 *
 * `isOverlapping` mirrors the EXACT comparison the database already uses
 * for technician scheduling everywhere: _appt_range's tstzrange(..., '[)')
 * and the appointments_technician_no_overlap EXCLUDE constraint /
 * _tech_conflict_appt's `&&` test (20261016100000_amc_cancel_visit_
 * scheduling_overlap.sql). Two half-open intervals [aStart, aEnd) and
 * [bStart, bEnd) overlap iff aStart < bEnd && bStart < aEnd — in particular
 * an interval ending exactly when another starts does NOT overlap (the
 * same boundary behaviour the DB gives a technician whose 9:00-10:00 job is
 * immediately followed by a 10:00-11:00 job: not a conflict).
 *
 * `allFreeGaps` mirrors _free_gaps (new helper in the same migration, which
 * itself mirrors the live _largest_free_window's merge algorithm from
 * 20260723100000_step4_booking_model_schema.sql) — reuses this file's own
 * `mergedBlocks` (exported from booking-window.ts) rather than a second
 * merge implementation, and returns every surviving gap instead of only the
 * largest.
 */
import { mergedBlocks, toHHMM, toMinutes, type TimeWindow } from "./booking-window"

/** Any two time-ish values the caller treats as consistently ordered —
 * either "HH:MM" strings for same-day comparisons, or epoch milliseconds /
 * ISO datetime strings for full appointment ranges. Comparison is always a
 * strict less-than, so the caller must pass the same representation on
 * both sides. */
type Instant = string | number

function cmp(a: Instant, b: Instant): number {
  if (typeof a === "number" && typeof b === "number") return a - b
  return String(a) < String(b) ? -1 : String(a) > String(b) ? 1 : 0
}

/**
 * Half-open interval overlap test, exactly mirroring the database's
 * tstzrange('[)') `&&` comparison (see module doc). Works for "HH:MM"
 * same-day times or full ISO datetime strings — whichever the caller is
 * consistently comparing.
 */
export function isOverlapping(aStart: Instant, aEnd: Instant, bStart: Instant, bEnd: Instant): boolean {
  return cmp(aStart, bEnd) < 0 && cmp(bStart, aEnd) < 0
}

export type FreeGap = TimeWindow & { minutes: number }

/** Every free gap in [workStart, workEnd] once every `blocked` window is
 * removed, ordered by start time. Mirrors _free_gaps exactly (merge via the
 * shared mergedBlocks, then walk the remaining gaps) instead of only
 * returning the single largest the way largestFreeWindow does. */
export function allFreeGaps(workStart: string, workEnd: string, blocked: TimeWindow[]): FreeGap[] {
  const wStart = toMinutes(workStart)
  const wEnd = toMinutes(workEnd)
  const merged = mergedBlocks(workStart, workEnd, blocked)

  const gaps: FreeGap[] = []
  let cursor = wStart
  for (const b of merged) {
    const bs = toMinutes(b.start)
    const be = toMinutes(b.end)
    if (bs > cursor) {
      gaps.push({ start: toHHMM(cursor), end: toHHMM(bs), minutes: bs - cursor })
    }
    if (be > cursor) cursor = be
  }
  if (wEnd > cursor) {
    gaps.push({ start: toHHMM(cursor), end: toHHMM(wEnd), minutes: wEnd - cursor })
  }
  return gaps
}

/** Shape of one row returned by get_technician_availability_for_date,
 * camelCased for the client. */
export type TechnicianAvailabilityRow = {
  technicianId: string
  technicianName: string
  isOnLeave: boolean
  workStart: string
  workEnd: string
  busyWindows: TimeWindow[]
  freeWindows: FreeGap[]
}

/**
 * Is this technician actually free for [slot.start, slot.end) on the day
 * this row describes? Defence-in-depth, not the source of truth — the
 * server already forces freeWindows to [] on a leave day and never offers a
 * gap the booked/leave windows don't actually leave — but the UI must never
 * let a click register as "free" against a stale/leave row even if its
 * freeWindows payload were somehow non-empty.
 */
export function isSlotFree(row: Pick<TechnicianAvailabilityRow, "isOnLeave" | "freeWindows">, slot: TimeWindow): boolean {
  if (row.isOnLeave) return false
  return row.freeWindows.some((g) => toMinutes(slot.start) >= toMinutes(g.start) && toMinutes(slot.end) <= toMinutes(g.end))
}
