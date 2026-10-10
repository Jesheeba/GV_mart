/**
 * Daily Follow Up shows two kinds of rows side by side: lead follow-ups (list_followups) and post-service calls
 * (list_post_service_followups). They come from separate functions on purpose (list_followups is lead-centric and
 * untouched), so the page merges them here: same buckets, oldest due first.
 */
export type Bucket = "overdue" | "today" | "upcoming"
type Dated = { bucket: string; due_at: string }

export type DailyItem<L extends Dated, P extends Dated> = { type: "lead"; item: L } | { type: "post"; item: P }

export function mergeBuckets<L extends Dated, P extends Dated>(leads: L[] | undefined, posts: P[] | undefined): Record<Bucket, DailyItem<L, P>[]> {
  const out: Record<Bucket, DailyItem<L, P>[]> = { overdue: [], today: [], upcoming: [] }
  for (const item of leads ?? []) if (item.bucket in out) out[item.bucket as Bucket].push({ type: "lead", item })
  for (const item of posts ?? []) if (item.bucket in out) out[item.bucket as Bucket].push({ type: "post", item })
  for (const b of Object.keys(out) as Bucket[]) out[b].sort((a, c) => a.item.due_at.localeCompare(c.item.due_at))
  return out
}

/**
 * Post-service calls have no lead stage, no lead source, no "stuck" state. So a stage, source or stuck filter hides
 * them; the Kind filter keeps them only for "service" (that is what they are).
 */
export function postServiceVisible(f: { stage?: string; source?: string; kind?: string; stuckOnly?: boolean }): boolean {
  return !f.stage && !f.source && !f.stuckOnly && (!f.kind || f.kind === "service")
}
