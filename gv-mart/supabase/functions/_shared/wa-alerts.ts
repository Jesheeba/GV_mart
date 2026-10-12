// Alert rules for the WhatsApp dispatcher (pure, so vitest covers the boundaries). Used by wa-scheduled-tasks
// (runDispatchAlerts) and mirrored by the Failed Sends tab.
//
//   * a row that is still 'pending' 15 minutes after it was created (never claimed) or claimed (claimed but never finished)
//     is "stuck": the dispatcher is not running, or a worker died mid-send. It is NEVER resent automatically (Wasi has no
//     idempotency key); a human decides.
//   * skipped_no_template rows above a per-day threshold (settings.wa_skipped_alert_threshold, default 10, 0 = off) mean
//     customers are not being told something because no approved template exists yet.

export const STUCK_PENDING_MS = 15 * 60_000
export const DEFAULT_SKIPPED_ALERT_THRESHOLD = 10
export const IST_OFFSET_MS = 5.5 * 3_600_000

/** Timestamp (ISO, UTC) at which a pending row becomes "stuck", relative to now. */
export function stuckBeforeIso(nowMs: number): string {
  return new Date(nowMs - STUCK_PENDING_MS).toISOString()
}

/** Start of the current IST calendar day, as an ISO UTC timestamp. */
export function istDayStartIso(nowMs: number): string {
  const ist = nowMs + IST_OFFSET_MS
  const dayStartIst = ist - (((ist % 86_400_000) + 86_400_000) % 86_400_000)
  return new Date(dayStartIst - IST_OFFSET_MS).toISOString()
}

export function normaliseThreshold(raw: number | null | undefined): number {
  if (raw == null || !Number.isFinite(raw) || raw < 0) return DEFAULT_SKIPPED_ALERT_THRESHOLD
  return Math.floor(raw)
}

/** More than `threshold` skipped rows today. A threshold of 0 switches the alert off. */
export function skippedAlertDue(skippedToday: number, rawThreshold: number | null | undefined): boolean {
  const threshold = normaliseThreshold(rawThreshold)
  return threshold > 0 && skippedToday > threshold
}

export function stuckAlertDue(stuckCount: number): boolean {
  return stuckCount > 0
}

export const ALERT_TYPES = { stuck: "wa_pending_stuck", skipped: "wa_skipped_threshold" } as const
