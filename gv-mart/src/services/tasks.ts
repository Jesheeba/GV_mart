import { supabase } from "@/lib/supabase"
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
  assignee: { id: string; full_name: string; role: Enums<"user_role"> } | null
  assigner: { id: string; full_name: string } | null
}

// Org-wide task list for the admin Tasks section — every staff role and
// technician can see every task in the org (tasks_select_internal RLS),
// which is what makes this a shared calendar/board rather than a personal
// list. Two FKs point at `profiles` (assignee_id, assigned_by), so each
// embed must be disambiguated by constraint name.
export async function listOrgTasks(orgId: string): Promise<OrgTask[]> {
  const { data, error } = await supabase
    .from("tasks")
    .select("*, assignee:profiles!tasks_assignee_id_fkey(id, full_name, role), assigner:profiles!tasks_assigned_by_fkey(id, full_name)")
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
