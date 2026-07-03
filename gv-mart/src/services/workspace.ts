import { supabase } from "@/lib/supabase"
import type { Enums, Tables } from "@/types/database"

export type TaskRow = Tables<"tasks">
export type NotificationRow = Tables<"notifications">

function todayIso() {
  return new Date().toISOString().slice(0, 10)
}

// ── ADM-31 Workspace: to-do checklist over `tasks` ───────────────────────
// "Today's list" = due_date <= today AND status != 'done'. Anything with
// due_date < today AND status still 'open' is shown with a "rolled over"
// visual treatment client-side — there is no midnight cron flipping
// status to 'rolled' (BuildSpec explicitly says this isn't required yet;
// the enum value is a hook for a future scheduled job).
export async function listMyWorkspaceTasks(orgId: string, assigneeId: string): Promise<TaskRow[]> {
  const { data, error } = await supabase
    .from("tasks")
    .select("*")
    .eq("org_id", orgId)
    .eq("assignee_id", assigneeId)
    .lte("due_date", todayIso())
    .neq("status", "done")
    .order("due_date", { ascending: true })
  if (error) throw error
  return data ?? []
}

export async function listUpcomingWorkspaceTasks(orgId: string, assigneeId: string): Promise<TaskRow[]> {
  const { data, error } = await supabase
    .from("tasks")
    .select("*")
    .eq("org_id", orgId)
    .eq("assignee_id", assigneeId)
    .gt("due_date", todayIso())
    .neq("status", "done")
    .order("due_date", { ascending: true })
  if (error) throw error
  return data ?? []
}

export async function listCompletedWorkspaceTasks(orgId: string, assigneeId: string): Promise<TaskRow[]> {
  const { data, error } = await supabase
    .from("tasks")
    .select("*")
    .eq("org_id", orgId)
    .eq("assignee_id", assigneeId)
    .eq("status", "done")
    .order("updated_at", { ascending: false })
    .limit(50)
  if (error) throw error
  return data ?? []
}

export type CreateTaskInput = { orgId: string; assigneeId: string; title: string; dueDate: string | null; source?: string }

export async function createTask(input: CreateTaskInput): Promise<TaskRow> {
  const { data, error } = await supabase
    .from("tasks")
    .insert({ org_id: input.orgId, assignee_id: input.assigneeId, title: input.title, due_date: input.dueDate, source: input.source ?? "manual" })
    .select()
    .single()
  if (error) throw error
  return data
}

export async function setTaskStatus(id: string, status: Enums<"task_status">): Promise<TaskRow> {
  const { data, error } = await supabase.from("tasks").update({ status }).eq("id", id).select().single()
  if (error) throw error
  return data
}

// ── Notifications feed (embedded in Workspace, plus the dedicated
// Notifications Center page reuses the same reads) ────────────────────────
export async function listMyNotificationsFeed(orgId: string, userId: string, role: Enums<"user_role">, limit = 20): Promise<NotificationRow[]> {
  const [ownRes, roleRes] = await Promise.all([
    supabase.from("notifications").select("*").eq("org_id", orgId).eq("user_id", userId).order("created_at", { ascending: false }).limit(limit),
    supabase.from("notifications").select("*").eq("org_id", orgId).eq("role", role).order("created_at", { ascending: false }).limit(limit),
  ])
  if (ownRes.error) throw ownRes.error
  if (roleRes.error) throw roleRes.error
  const merged = [...(ownRes.data ?? []), ...(roleRes.data ?? [])]
  merged.sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime())
  return merged.slice(0, limit)
}

// ── "AI confirmation-call" card stub (ADM-31) ─────────────────────────────
// No real telephony/AI exists in this app (BuildSpec: build as a manual
// card with a "Mark confirmed" button that just logs the action). Logged as
// a lead_activities-style note is not always applicable (not every
// dispatch has a lead), so this logs a notifications row instead — visible
// in both the Workspace feed and the Notifications Center.
export async function logConfirmationCallAction(orgId: string, userId: string, ticketLabel: string): Promise<void> {
  const { error } = await supabase.from("notifications").insert({
    org_id: orgId,
    user_id: userId,
    type: "confirmation_call_stub",
    title: "Confirmation call marked",
    body: `Manually marked "confirmed with customer before dispatch" for ${ticketLabel}. (No real telephony/AI is wired up — this is a manual log.)`,
  })
  if (error) throw error
}

// ── TECH-11 Day-Sheet ──────────────────────────────────────────────────────
// Reuses the same "today's earnings" arithmetic TechnicianHomePage/ProfilePage
// already rely on elsewhere (sum of service_visits.service_charge), just
// scoped to today instead of a trailing 30 days. Attendance status reads the
// same `attendance` row TECH-01 writes.
export type DaySheetSummary = {
  jobsDone: number
  jobsPending: number
  earningsToday: number
  attendance: Tables<"attendance"> | null
}

export async function getDaySheetSummary(orgId: string, technicianId: string): Promise<DaySheetSummary> {
  const date = todayIso()
  const dayStartIso = new Date(`${date}T00:00:00`).toISOString()
  const dayEndIso = new Date(`${date}T23:59:59.999`).toISOString()

  const [doneRes, pendingRes, attendanceRes] = await Promise.all([
    supabase
      .from("service_visits")
      .select("service_charge, timer_start")
      .eq("org_id", orgId)
      .eq("technician_id", technicianId)
      .gte("timer_start", dayStartIso)
      .lte("timer_start", dayEndIso),
    supabase
      .from("appointments")
      .select("id, status", { count: "exact", head: true })
      .eq("org_id", orgId)
      .eq("technician_id", technicianId)
      .gte("scheduled_at", dayStartIso)
      .lte("scheduled_at", dayEndIso)
      .in("status", ["scheduled", "in_progress"]),
    supabase.from("attendance").select("*").eq("org_id", orgId).eq("technician_id", technicianId).eq("date", date).maybeSingle(),
  ])
  if (doneRes.error) throw doneRes.error
  if (pendingRes.error) throw pendingRes.error
  if (attendanceRes.error) throw attendanceRes.error

  const jobsDone = (doneRes.data ?? []).length
  const earningsToday = (doneRes.data ?? []).reduce((sum, v) => sum + (v.service_charge ?? 0), 0)

  return {
    jobsDone,
    jobsPending: pendingRes.count ?? 0,
    earningsToday,
    attendance: attendanceRes.data,
  }
}
