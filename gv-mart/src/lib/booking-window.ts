/**
 * B1/B2 booking-model math (GV_Mart_Build_Order_and_Guardrails.md Step 4) —
 * mirrors public._largest_free_window (20260723100000_step4_booking_model_
 * schema.sql) exactly, for a live client-side preview only. The RPCs
 * (book_service_ticket / create_complaint_ticket) always recompute this
 * server-side from settings + the submitted windows — this module never
 * decides what actually gets booked, it just lets the wizard show "your
 * available window will be X–Y" / narrow-window warnings before submit.
 */

export type TimeWindow = { start: string; end: string }

function toMinutes(hhmm: string): number {
  const [h, m] = hhmm.split(":").map(Number)
  return h * 60 + (m || 0)
}

function toHHMM(minutes: number): string {
  const h = Math.floor(minutes / 60)
    .toString()
    .padStart(2, "0")
  const m = (minutes % 60).toString().padStart(2, "0")
  return `${h}:${m}`
}

/** Merges overlapping/adjacent windows and clips each to [workStart, workEnd]. */
function mergedBlocks(workStart: string, workEnd: string, blocked: TimeWindow[]): TimeWindow[] {
  const wStart = toMinutes(workStart)
  const wEnd = toMinutes(workEnd)

  const clipped = blocked
    .map((w) => ({ s: Math.max(toMinutes(w.start), wStart), e: Math.min(toMinutes(w.end), wEnd) }))
    .filter((w) => w.s < w.e)
    .sort((a, b) => a.s - b.s)

  const merged: { s: number; e: number }[] = []
  for (const w of clipped) {
    const last = merged[merged.length - 1]
    if (last && w.s <= last.e) {
      last.e = Math.max(last.e, w.e)
    } else {
      merged.push({ ...w })
    }
  }
  return merged.map((w) => ({ start: toHHMM(w.s), end: toHHMM(w.e) }))
}

export type FreeWindowResult = {
  availableFrom: string | null
  availableTo: string | null
  minutes: number
}

/** The single largest contiguous free segment of [workStart, workEnd] once every `blocked` window is removed. */
export function largestFreeWindow(workStart: string, workEnd: string, blocked: TimeWindow[]): FreeWindowResult {
  const wStart = toMinutes(workStart)
  const wEnd = toMinutes(workEnd)
  const merged = mergedBlocks(workStart, workEnd, blocked)

  let cursor = wStart
  let bestStart = -1
  let bestEnd = -1
  let bestMinutes = -1

  for (const b of merged) {
    const bs = toMinutes(b.start)
    const be = toMinutes(b.end)
    if (bs > cursor) {
      const gap = bs - cursor
      if (gap > bestMinutes) {
        bestMinutes = gap
        bestStart = cursor
        bestEnd = bs
      }
    }
    if (be > cursor) cursor = be
  }
  if (wEnd > cursor) {
    const gap = wEnd - cursor
    if (gap > bestMinutes) {
      bestMinutes = gap
      bestStart = cursor
      bestEnd = wEnd
    }
  }

  if (bestMinutes <= 0) return { availableFrom: null, availableTo: null, minutes: 0 }
  return { availableFrom: toHHMM(bestStart), availableTo: toHHMM(bestEnd), minutes: bestMinutes }
}

/** B2: a window is "narrow" once it's at or below the settings-driven threshold. */
export function isNarrowWindow(result: FreeWindowResult, thresholdMinutes: number): boolean {
  return result.availableFrom !== null && result.minutes <= thresholdMinutes
}

/** B2: a narrow window that's physically shorter than the job itself can't be booked at all. */
export function fitsJob(result: FreeWindowResult, estimatedMinutes: number): boolean {
  return result.availableFrom !== null && result.minutes >= estimatedMinutes
}

/**
 * Mirrors the RPCs' v_geometrically_ok: is this date bookable at all, i.e.
 * would the server accept it on the first pass without needing to bump to
 * the next day (B3)? Used to show a "this will move to the next day"
 * warning before the customer even submits.
 */
export function isBookableDate(result: FreeWindowResult, thresholdMinutes: number, estimatedMinutes: number): boolean {
  if (result.availableFrom === null) return false
  return !isNarrowWindow(result, thresholdMinutes) || fitsJob(result, estimatedMinutes)
}
