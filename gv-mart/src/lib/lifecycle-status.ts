import type { StatusTone } from "@/components/shared/StatusDot"

/**
 * Product Lifecycle widget (W4 drop). Statuses as they come back from
 * `customer_part_schedules.status` / the derived lifetime-expiry bucket,
 * mapped to the shared StatusDot tone scale (see AMC_STATUS_TONE for the
 * sibling pattern this mirrors).
 */
export type LifecycleStatus = "due_soon" | "due" | "overdue" | "lifetime_expiring_90d"

export const LIFECYCLE_STATUS_TONE: Record<LifecycleStatus, StatusTone> = {
  due_soon: "info",
  due: "warning",
  overdue: "danger",
  lifetime_expiring_90d: "warning",
}

/** Pure lookup with a safe fallback — an unrecognised status never throws, it just reads neutral. */
export function lifecycleStatusTone(status: string): StatusTone {
  return LIFECYCLE_STATUS_TONE[status as LifecycleStatus] ?? "neutral"
}
