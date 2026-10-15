import { istDateOf } from "@/lib/ist"

/** The slice of a task the overdue rules need. */
export type OverdueTaskLike = {
  status: string
  due_date: string | null
  due_at: string | null
}

/**
 * A task is overdue when it is not done and its deadline has passed.
 * `due_at` (an instant) wins over `due_date` (a calendar date). A date-only task
 * is overdue from the start of the day AFTER its date, compared in IST so a
 * device in another timezone agrees with the server.
 */
export function isTaskOverdue(task: OverdueTaskLike, now: Date = new Date()): boolean {
  if (task.status !== "open") return false // done (or rolled) tasks are never overdue
  if (task.due_at) return new Date(task.due_at).getTime() < now.getTime()
  if (task.due_date) return task.due_date < istDateOf(now)
  return false
}

function dueSortKey(task: OverdueTaskLike): number {
  if (task.due_at) return new Date(task.due_at).getTime()
  if (task.due_date) return new Date(`${task.due_date}T00:00:00+05:30`).getTime()
  return Number.POSITIVE_INFINITY
}

/**
 * Sort: overdue first (longest overdue on top), then other open tasks by
 * deadline (undated last), then done tasks. Stable for equal keys.
 */
export function sortOverdueFirst<T extends OverdueTaskLike>(tasks: T[], now: Date = new Date()): T[] {
  const rank = (t: T) => (t.status === "done" ? 2 : isTaskOverdue(t, now) ? 0 : 1)
  return tasks
    .map((task, index) => ({ task, index }))
    .sort((a, b) => {
      const ra = rank(a.task)
      const rb = rank(b.task)
      if (ra !== rb) return ra - rb
      const ka = dueSortKey(a.task)
      const kb = dueSortKey(b.task)
      if (ka !== kb) return ka < kb ? -1 : 1
      return a.index - b.index
    })
    .map((x) => x.task)
}
