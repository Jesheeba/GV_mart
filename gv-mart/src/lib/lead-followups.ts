// Pure date/time logic for lead follow-ups. Everything is Asia/Kolkata (IST,
// fixed +05:30, no DST), never the device's own timezone: dates are plain
// "YYYY-MM-DD" strings and times "HH:MM", combined into an absolute instant
// only at the edge (toIso). Mirrors the SQL helpers in
// 20261006210000_lead_followups_functions.sql (working days, initial slot).

import { getIstNow } from "@/lib/ist"

export const IST_TIME_ZONE = "Asia/Kolkata"

export type IstNow = { date: string; time: string }

/** Default working schedule (settings.lead_work_*): Mon–Sat, ISO weekdays. */
export const DEFAULT_WORK_DAYS = [1, 2, 3, 4, 5, 6]

// ── date arithmetic on "YYYY-MM-DD" ──────────────────────────────────────
function parts(date: string): [number, number, number] {
  const [y, m, d] = date.split("-").map(Number)
  return [y, m, d]
}

export function addDays(date: string, n: number): string {
  const [y, m, d] = parts(date)
  return new Date(Date.UTC(y, m - 1, d + n)).toISOString().slice(0, 10)
}

/** Same day-of-month N months on; clamps to month end (31 Jan + 1 month = 28/29 Feb). */
export function addMonths(date: string, n: number): string {
  const [y, m, d] = parts(date)
  const first = new Date(Date.UTC(y, m - 1 + n, 1))
  const lastDay = new Date(Date.UTC(first.getUTCFullYear(), first.getUTCMonth() + 1, 0)).getUTCDate()
  first.setUTCDate(Math.min(d, lastDay))
  return first.toISOString().slice(0, 10)
}

/** ISO weekday: Monday = 1 … Sunday = 7. */
export function isoDow(date: string): number {
  const dow = new Date(`${date}T00:00:00Z`).getUTCDay()
  return dow === 0 ? 7 : dow
}

export function isWorkingDay(date: string, workDays: number[] = DEFAULT_WORK_DAYS): boolean {
  return workDays.includes(isoDow(date))
}

/** First working day strictly after `date`. */
export function nextWorkingDay(date: string, workDays: number[] = DEFAULT_WORK_DAYS): string {
  let d = date
  for (let i = 0; i < 14; i++) {
    d = addDays(d, 1)
    if (isWorkingDay(d, workDays)) return d
  }
  return addDays(date, 1)
}

/** null when `date` is a working day; otherwise the next working day to suggest. */
export function suggestWorkingDay(date: string, workDays: number[] = DEFAULT_WORK_DAYS): string | null {
  return isWorkingDay(date, workDays) ? null : nextWorkingDay(date, workDays)
}

// ── instants ─────────────────────────────────────────────────────────────
/** The absolute instant (ISO/UTC string) of an IST wall-clock date + time. */
export function toIso(date: string, time: string): string {
  return new Date(`${date}T${time.length === 5 ? `${time}:00` : time}+05:30`).toISOString()
}

/** True when the IST wall-clock date+time is still in the future. */
export function isFutureIst(date: string, time: string, now: Date = new Date()): boolean {
  return new Date(toIso(date, time)).getTime() > now.getTime()
}

/** IST calendar date ("YYYY-MM-DD") of an instant. */
export function istDate(iso: string | Date): string {
  return new Date(iso).toLocaleDateString("en-CA", { timeZone: IST_TIME_ZONE })
}

/** IST "HH:MM" (24h) of an instant. */
export function istTime(iso: string | Date): string {
  return new Date(iso).toLocaleTimeString("en-GB", { timeZone: IST_TIME_ZONE, hour: "2-digit", minute: "2-digit", hour12: false })
}

/** A follow-up is overdue the moment its time has passed (red chip), regardless of tab. */
export function isOverdueNow(iso: string, now: Date = new Date()): boolean {
  return new Date(iso).getTime() < now.getTime()
}

// ── chips ────────────────────────────────────────────────────────────────
export const DATE_CHIPS = ["laterToday", "tomorrow", "days3", "week1", "weeks2", "month1", "months3", "custom"] as const
export type DateChip = (typeof DATE_CHIPS)[number]

export const TIME_CHIPS = [
  { key: "morning", time: "10:00" },
  { key: "afternoon", time: "14:00" },
  { key: "evening", time: "17:00" },
] as const
export type TimeChipKey = (typeof TIME_CHIPS)[number]["key"]

export const DEFAULT_TIME = "10:00"

/** Later-today slots, tried in order; the first at least an hour away (and before closing) wins. */
const LATER_TODAY_SLOTS = ["14:00", "17:00", "18:30"]

function minutes(time: string): number {
  const [h, m] = time.split(":").map(Number)
  return h * 60 + m
}

export function laterTodaySlot(nowTime: string, workEnd = "19:00"): string | null {
  return LATER_TODAY_SLOTS.find((s) => minutes(s) >= minutes(nowTime) + 60 && minutes(s) < minutes(workEnd)) ?? null
}

/**
 * Resolves a date chip to a date (and, for "Later today", a time). Returns
 * null when the chip does not apply (custom, or later-today after hours).
 */
export function resolveDateChip(chip: DateChip, now: IstNow, workEnd = "19:00"): { date: string; time?: string } | null {
  switch (chip) {
    case "laterToday": {
      const slot = laterTodaySlot(now.time, workEnd)
      return slot ? { date: now.date, time: slot } : null
    }
    case "tomorrow":
      return { date: addDays(now.date, 1) }
    case "days3":
      return { date: addDays(now.date, 3) }
    case "week1":
      return { date: addDays(now.date, 7) }
    case "weeks2":
      return { date: addDays(now.date, 14) }
    case "month1":
      return { date: addMonths(now.date, 1) }
    case "months3":
      return { date: addMonths(now.date, 3) }
    case "custom":
      return null
  }
}

export type OutcomeDefaults = { followup_mode: "none" | "offset" | "ask_date" | "exact_time"; default_offset_days: number | null }

/** Pre-fill for the "next follow-up" step from the chosen outcome's rule. */
export function defaultNextFor(
  outcome: OutcomeDefaults,
  now: IstNow,
  workDays: number[] = DEFAULT_WORK_DAYS,
  workEnd = "19:00"
): { date: string | null; time: string | null; exact: boolean } {
  switch (outcome.followup_mode) {
    case "none":
      return { date: null, time: null, exact: false }
    case "ask_date":
      return { date: null, time: DEFAULT_TIME, exact: false }
    case "exact_time":
      return { date: now.date, time: null, exact: true }
    case "offset": {
      const days = outcome.default_offset_days ?? 0
      if (days === 0) {
        const slot = laterTodaySlot(now.time, workEnd)
        if (slot && isWorkingDay(now.date, workDays)) return { date: now.date, time: slot, exact: false }
        return { date: nextWorkingDay(now.date, workDays), time: DEFAULT_TIME, exact: false }
      }
      return { date: addDays(now.date, days), time: DEFAULT_TIME, exact: false }
    }
  }
}

// ── display ──────────────────────────────────────────────────────────────
function locale(lang: string): string {
  return lang.startsWith("ta") ? "ta-IN" : "en-IN"
}

/** "Tue 6 Oct, 10:00 am" — always IST. */
export function formatIstDateTime(iso: string, lang = "en"): string {
  return new Date(iso).toLocaleString(locale(lang), {
    timeZone: IST_TIME_ZONE,
    weekday: "short",
    day: "numeric",
    month: "short",
    hour: "numeric",
    minute: "2-digit",
    hour12: true,
  })
}

/** "6 Oct 2026, 10:00 am" — for history entries. */
export function formatIstStamp(iso: string, lang = "en"): string {
  return new Date(iso).toLocaleString(locale(lang), {
    timeZone: IST_TIME_ZONE,
    day: "numeric",
    month: "short",
    year: "numeric",
    hour: "numeric",
    minute: "2-digit",
    hour12: true,
  })
}

export function formatIstTime(iso: string, lang = "en"): string {
  return new Date(iso).toLocaleTimeString(locale(lang), { timeZone: IST_TIME_ZONE, hour: "numeric", minute: "2-digit", hour12: true })
}

export function formatIstDate(date: string, lang = "en"): string {
  return new Date(`${date}T00:00:00Z`).toLocaleDateString(locale(lang), { timeZone: "UTC", weekday: "short", day: "numeric", month: "short" })
}

// ── contact links ────────────────────────────────────────────────────────
// WhatsApp deep links reuse toWhatsappLink (lib/whatsapp-link.ts).
export function telHref(mobile: string): string {
  return `tel:${mobile.replace(/[^\d+]/g, "")}`
}

/** The "next follow-up" form value: IST date, IST time (null until chosen) and whether the time was typed as an exact time. */
export type NextFollowupValue = { date: string | null; time: string | null; exact: boolean }

/** True when the picker value is complete and in the future. */
export function isNextFollowupValid(v: NextFollowupValue, now: Date = new Date()): boolean {
  return !!v.date && !!v.time && isFutureIst(v.date, v.time, now)
}

export { getIstNow }

export const FOLLOWUP_TYPES = ["call", "whatsapp", "visit", "send_quote"] as const
export type SetFollowupType = (typeof FOLLOWUP_TYPES)[number]
export const FOLLOWUP_NOTE_MAX = 200

/** "Set follow-up" form: a known type plus a complete, future date/time. */
export function canSetFollowup(f: { type: string; next: NextFollowupValue }, now: Date = new Date()): boolean {
  return (FOLLOWUP_TYPES as readonly string[]).includes(f.type) && isNextFollowupValid(f.next, now)
}

/** Trimmed note, or null when blank; capped so a paste can't bloat the row. */
export function cleanFollowupNote(note: string): string | null {
  const n = note.trim().slice(0, FOLLOWUP_NOTE_MAX).trim()
  return n === "" ? null : n
}

/**
 * True when set_lead_followup lost a race: another person set the follow-up
 * first (the RPC's own check, or the one-open-per-lead unique index). Supabase
 * errors are plain objects, not Error instances, so read message/code off any shape.
 */
export function isFollowupAlreadySetError(e: unknown): boolean {
  const o = (e ?? {}) as { message?: unknown; code?: unknown; details?: unknown }
  const text = `${String(o.message ?? "")} ${String(o.details ?? "")}`
  return String(o.code ?? "") === "23505" || /already has an open follow-up|lead_followups_one_open_per_lead/i.test(text)
}
