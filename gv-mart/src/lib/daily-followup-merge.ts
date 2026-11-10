/**
 * Daily Follow Up shows three kinds of rows side by side: lead follow-ups (list_followups), post-service calls
 * (list_post_service_followups), and Product Lifecycle service reminders (get_lifecycle_followups_for_sales, W5).
 * They come from separate functions on purpose (list_followups is lead-centric and untouched), so the page merges
 * them here: same buckets, oldest due first.
 */
export type Bucket = "overdue" | "today" | "upcoming"
type Dated = { bucket: string; due_at: string }

/** Lifecycle rows carry their own tri-state status instead of a server-computed bucket; see lifecycleBucket below. */
type LifecycleDated = { status: "due_soon" | "due" | "overdue"; nextDueDate: string }

export type DailyItem<L extends Dated, P extends Dated, F extends LifecycleDated = never> =
  | { type: "lead"; item: L }
  | { type: "post"; item: P }
  | { type: "lifecycle"; item: F }

/** due_soon/due/overdue map 1:1 onto upcoming/today/overdue so lifecycle rows sort into the same three buckets as
 * leads and post-service calls, which already arrive with a server-computed `bucket`. */
export function lifecycleBucket(status: LifecycleDated["status"]): Bucket {
  if (status === "overdue") return "overdue"
  if (status === "due") return "today"
  return "upcoming"
}

export function mergeBuckets<L extends Dated, P extends Dated, F extends LifecycleDated = never>(
  leads: L[] | undefined,
  posts: P[] | undefined,
  lifecycle?: F[] | undefined
): Record<Bucket, DailyItem<L, P, F>[]> {
  const out: Record<Bucket, DailyItem<L, P, F>[]> = { overdue: [], today: [], upcoming: [] }
  for (const item of leads ?? []) if (item.bucket in out) out[item.bucket as Bucket].push({ type: "lead", item })
  for (const item of posts ?? []) if (item.bucket in out) out[item.bucket as Bucket].push({ type: "post", item })
  for (const item of lifecycle ?? []) out[lifecycleBucket(item.status)].push({ type: "lifecycle", item })
  const dueAtOf = (x: DailyItem<L, P, F>): string => (x.type === "lifecycle" ? x.item.nextDueDate : x.item.due_at)
  for (const b of Object.keys(out) as Bucket[]) out[b].sort((a, c) => dueAtOf(a).localeCompare(dueAtOf(c)))
  return out
}

/**
 * Post-service calls have no lead stage, no lead source, no "stuck" state. So a stage, source or stuck filter hides
 * them; the Kind filter keeps them only for "service" (that is what they are).
 */
export function postServiceVisible(f: { stage?: string; source?: string; kind?: string; stuckOnly?: boolean }): boolean {
  return !f.stage && !f.source && !f.stuckOnly && (!f.kind || f.kind === "service")
}

/**
 * Lifecycle (Product Lifecycle service reminder) rows have no lead stage, no lead source, no "stuck" state either --
 * same reasoning as postServiceVisible. They aren't "service" kind (that's a ticket on an existing complaint); any
 * Kind filter hides them since there's no matching kind option for a scheduled part reminder.
 */
export function lifecycleFollowupVisible(f: { stage?: string; source?: string; kind?: string; stuckOnly?: boolean }): boolean {
  return !f.stage && !f.source && !f.stuckOnly && !f.kind
}
