export const REMINDER_OFFSETS = ["at", "15m", "1h", "1d"] as const
export type ReminderOffset = "" | (typeof REMINDER_OFFSETS)[number]

const OFFSET_MINUTES: Record<(typeof REMINDER_OFFSETS)[number], number> = {
  at: 0,
  "15m": 15,
  "1h": 60,
  "1d": 24 * 60,
}

/** ISO timestamp for the reminder, offset back from the follow-up's due time. */
export function reminderDueAt(followupDueAtIso: string, offset: Exclude<ReminderOffset, "">): string {
  const ms = new Date(followupDueAtIso).getTime() - OFFSET_MINUTES[offset] * 60_000
  return new Date(ms).toISOString()
}
