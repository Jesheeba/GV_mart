// Task rules shared by every task screen. The database is the authority (guard_task_completion, migration 20261101100000);
// these helpers only keep the screen from offering what the database will refuse, and style / order overdue work.

export type TaskLike = {
  status: string
  due_date: string | null
  due_at: string | null
  assignee_id: string | null
  ref_type: string | null
}

export type ActorLike = { id: string; role: string }

/** The calendar day (YYYY-MM-DD) a task is due, in IST, from due_at when it has one, else due_date. */
export function taskDueDay(task: Pick<TaskLike, "due_date" | "due_at">): string | null {
  if (task.due_at) {
    const d = new Date(task.due_at)
    if (!Number.isNaN(d.getTime())) {
      // IST = UTC+5:30, fixed offset, no DST
      const ist = new Date(d.getTime() + 330 * 60_000)
      return ist.toISOString().slice(0, 10)
    }
  }
  return task.due_date
}

/** A task is overdue when it is not finished and its due day is before today (IST). `todayIst` is YYYY-MM-DD. */
export function isTaskOverdue(task: TaskLike, todayIst: string): boolean {
  if (task.status === "done") return false
  const day = taskDueDay(task)
  return day != null && day < todayIst
}

/** Overdue first (oldest due day first), then the rest by due day, undated last; finished tasks always last. */
export function compareTasksOverdueFirst(a: TaskLike, b: TaskLike, todayIst: string): number {
  const rank = (t: TaskLike) => (t.status === "done" ? 3 : isTaskOverdue(t, todayIst) ? 0 : taskDueDay(t) ? 1 : 2)
  const ra = rank(a)
  const rb = rank(b)
  if (ra !== rb) return ra - rb
  const da = taskDueDay(a) ?? "9999-12-31"
  const db = taskDueDay(b) ?? "9999-12-31"
  return da < db ? -1 : da > db ? 1 : 0
}

export type CompleteBlockReason = "not_assignee" | "po_needs_master" | "unassigned"

/** Why the finish control is disabled for this person (null when they may finish it), so the screen can explain instead of failing silently. */
export function completeBlockReason(task: Pick<TaskLike, "assignee_id" | "ref_type">, actor: ActorLike | null | undefined): CompleteBlockReason | null {
  if (!actor) return "not_assignee"
  const isOps = actor.role === "master" || actor.role === "operation_admin"
  if (task.assignee_id) {
    if (task.assignee_id !== actor.id) return "not_assignee"
  } else if (!isOps) {
    return "unassigned"
  }
  if (task.ref_type === "purchase_order" && actor.role !== "master") return "po_needs_master"
  return null
}

/** Mirrors guard_task_completion: only the assignee finishes a task (operations, when it has no assignee);
 *  a purchase-order task additionally needs a master. Master and operations may reassign but never finish for someone else. */
export function canCompleteTask(task: Pick<TaskLike, "assignee_id" | "ref_type">, actor: ActorLike | null | undefined): boolean {
  if (!actor) return false
  const isOps = actor.role === "master" || actor.role === "operation_admin"
  if (task.assignee_id) {
    if (task.assignee_id !== actor.id) return false
  } else if (!isOps) {
    return false
  }
  if (task.ref_type === "purchase_order" && actor.role !== "master") return false
  return true
}
