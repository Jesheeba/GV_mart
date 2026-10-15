import { supabase } from "@/lib/supabase"
import { getIstNow } from "@/lib/ist"
import type { Enums, Tables } from "@/types/database"

export type TaskRow = Tables<"tasks">
export type PriorityLevel = Enums<"priority_level">

export type AssignableProfile = { id: string; full_name: string; role: Enums<"user_role"> }

// The assignment pool: every staff role + technician. Customers are
// intentionally excluded — this is an internal task tool, not a
// customer-facing one (see Phase 0's design decision).
export async function listAssignableProfiles(orgId: string): Promise<AssignableProfile[]> {
  const { data, error } = await supabase
    .from("profiles")
    .select("id, full_name, role")
    .eq("org_id", orgId)
    .in("role", ["master", "operation_admin", "sales_admin", "technician"])
    .order("full_name", { ascending: true })
  if (error) throw error
  return data ?? []
}

export type OrgTask = TaskRow & {
  // colour: profiles.colour (20261102100000) — null means "pick one for me", not "no colour"; see lib/user-colour.ts.
  assignee: { id: string; full_name: string; role: Enums<"user_role">; colour: string | null } | null
  assigner: { id: string; full_name: string } | null
}

// Task list for the admin Tasks section. Since 20261103100000 (P3), tasks_select_internal narrows this to every
// task in the org for master/operation_admin, and to "assignee or assigner is me" for everyone else — so this one
// query already IS "my day" for a non-ops role, just not grouped that way (see MyDayView, which filters this same
// list rather than issuing a second query). Two FKs point at `profiles` (assignee_id, assigned_by), so each embed
// must be disambiguated by constraint name.
export async function listOrgTasks(orgId: string): Promise<OrgTask[]> {
  const { data, error } = await supabase
    .from("tasks")
    .select("*, assignee:profiles!tasks_assignee_id_fkey(id, full_name, role, colour), assigner:profiles!tasks_assigned_by_fkey(id, full_name)")
    .eq("org_id", orgId)
    .order("due_date", { ascending: true, nullsFirst: false })
  if (error) throw error
  return (data ?? []) as unknown as OrgTask[]
}

export type AssignTaskInput = {
  orgId: string
  assignedBy: string
  assigneeId: string
  title: string
  description: string | null
  priority: PriorityLevel
  dueDate: string | null
  dueAt: string | null
  // Requires dueDate — advance_recurring_tasks (20260922110000) advances
  // this same due_date by 1 month each cycle, so there's no base date to
  // advance from without one. Enforced client-side (dialog disables the
  // checkbox with no due date) and server-side (tasks_recurring_needs_due_date).
  isRecurring: boolean
  // Optional back-link to the thing this task came from (e.g. a daily-huddle
  // issue: refType 'meeting_issue').
  refType?: string | null
  refId?: string | null
}

export async function assignTask(input: AssignTaskInput): Promise<TaskRow> {
  const { data, error } = await supabase
    .from("tasks")
    .insert({
      org_id: input.orgId,
      assignee_id: input.assigneeId,
      assigned_by: input.assignedBy,
      title: input.title,
      description: input.description,
      priority: input.priority,
      due_date: input.dueDate,
      due_at: input.dueAt,
      is_recurring: input.isRecurring,
      ref_type: input.refType ?? null,
      ref_id: input.refId ?? null,
      source: "assigned",
    })
    .select()
    .single()
  if (error) throw error
  return data
}

export type UpdateTaskInput = {
  id: string
  title: string
  description: string | null
  assigneeId: string
  // Set whenever assigneeId changes, so the tasks_notify_assigned trigger
  // (UPDATE OF assignee_id) attributes the reassignment to whoever made it
  // and skips the notification if they reassigned it to themselves.
  assignedBy: string
  priority: PriorityLevel
  dueDate: string | null
  dueAt: string | null
  isRecurring: boolean
}

export async function updateTask(input: UpdateTaskInput): Promise<TaskRow> {
  const { data, error } = await supabase
    .from("tasks")
    .update({
      title: input.title,
      description: input.description,
      assignee_id: input.assigneeId,
      assigned_by: input.assignedBy,
      priority: input.priority,
      due_date: input.dueDate,
      due_at: input.dueAt,
      is_recurring: input.isRecurring,
    })
    .eq("id", input.id)
    .select()
    .single()
  if (error) throw error
  return data
}

// Ops-only under RLS (tasks_delete_ops) — the UI also hides the delete
// action for anyone else, but the database is the real gate.
export async function deleteTask(id: string): Promise<void> {
  const { error } = await supabase.from("tasks").delete().eq("id", id)
  if (error) throw error
}

// Moved here from services/workspace.ts (P3 — My Workspace merged into Tasks): the done/open toggle is not
// Workspace-specific, every Tasks view uses it.
export async function setTaskStatus(id: string, status: Enums<"task_status">): Promise<TaskRow> {
  const { data, error } = await supabase.from("tasks").update({ status }).eq("id", id).select().single()
  if (error) throw error
  return data
}

// P3: replaces the old lazy "rollover on read" (listMyWorkspaceTasks silently rewrote due_date on every fetch).
// This is the same column effect (original_due_date preserved via coalesce, due_date -> today, rolled_count + 1),
// but now only on an explicit "Move to today" click — a read never mutates data any more.
export async function moveTaskToToday(task: Pick<TaskRow, "id" | "due_date" | "original_due_date" | "rolled_count">): Promise<TaskRow> {
  const { data, error } = await supabase
    .from("tasks")
    .update({
      original_due_date: task.original_due_date ?? task.due_date,
      due_date: getIstNow().date,
      rolled_count: (task.rolled_count ?? 0) + 1,
    })
    .eq("id", task.id)
    .select()
    .single()
  if (error) throw error
  return data
}
