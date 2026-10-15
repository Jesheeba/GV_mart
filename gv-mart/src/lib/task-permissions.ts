import type { UserRole } from "@/lib/roles"

type TaskLike = { assignee_id: string | null; status: string; ref_type: string | null }

/**
 * Mirrors the database rule (guard_task_status_change, 20261025100000) so the
 * toggle is not offered where the database would refuse it. The database is the
 * real gate; this only avoids a dead button.
 *  - complete: only the assignee; a purchase-order task also needs master
 *    (the role that may approve / mark-pay purchase orders)
 *  - reopen: the assignee, or master / operation_admin
 */
export function canToggleTaskStatus(task: TaskLike, userId: string | undefined, role: UserRole | undefined): boolean {
  if (!userId || !role) return false
  const isAssignee = task.assignee_id === userId
  if (task.status === "done") return isAssignee || role === "master" || role === "operation_admin"
  if (!isAssignee) return false
  if (task.ref_type === "purchase_order") return role === "master"
  return true
}
