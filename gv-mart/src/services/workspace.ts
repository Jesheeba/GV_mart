import { supabase } from "@/lib/supabase"
import type { Enums, Tables } from "@/types/database"

export type TaskRow = Tables<"tasks">
export type NotificationRow = Tables<"notifications">

export type TaskRowWithRollover = TaskRow

function todayIso() {
  return new Date().toISOString().slice(0, 10)
}

// ── ADM-31 Workspace: to-do checklist over `tasks` ───────────────────────
// Genuine lazy rollover: there is no cron/scheduled-job infrastructure in
// this project, so "carrying a task forward" happens the first time an
// overdue-but-not-done task is actually fetched. For every row still
// matching due_date < today, this stamps original_due_date (the first-ever
// due date, preserved via coalesce so repeated rolls don't lose it),
// bumps due_date to today, and increments rolled_count — a real state
// mutation, not just a display filter. Because due_date becomes today as
// part of the roll, the very next fetch that same day no longer matches
// `due_date < today`, so a task is never re-rolled twice in one day without
// needing any extra "already rolled today" bookkeeping column.
async function rollOverOverdueTasks(rows: TaskRowWithRollover[]): Promise<TaskRowWithRollover[]> {
  const today = todayIso()
  const overdue = rows.filter((r) => r.status !== "done" && !!r.due_date && r.due_date < today)
  if (overdue.length === 0) return rows

  const rolled = await Promise.all(
    overdue.map(async (task) => {
      const { data, error } = await supabase
        .from("tasks")
        .update({
          original_due_date: task.original_due_date ?? task.due_date,
          due_date: today,
          rolled_count: (task.rolled_count ?? 0) + 1,
        })
        .eq("id", task.id)
        .select()
        .single()
      if (error) throw error
      return data
    })
  )

  const rolledById = new Map(rolled.map((r) => [r.id, r]))
  return rows.map((r) => rolledById.get(r.id) ?? r)
}

// "Today's list" = due_date <= today AND status != 'done'. Any row that's
// still overdue (due_date < today) is rolled forward via
// rollOverOverdueTasks before the list is returned, so the UI always shows
// a task's *current* due_date (today, once rolled) plus rolled_count/
// original_due_date for the "rolled over Nx" treatment.
export async function listMyWorkspaceTasks(orgId: string, assigneeId: string): Promise<TaskRowWithRollover[]> {
  const { data, error } = await supabase
    .from("tasks")
    .select("*")
    .eq("org_id", orgId)
    .eq("assignee_id", assigneeId)
    .lte("due_date", todayIso())
    .neq("status", "done")
    .order("due_date", { ascending: true })
  if (error) throw error
  return rollOverOverdueTasks(data ?? [])
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

// ── "AI confirmation-call" list, per-appointment (ADM-31) ─────────────────
// No real telephony/AI exists in this app — this is still a manual "Mark
// confirmed" action that just logs it (BuildSpec), the only change is that
// it's now tied to a specific appointment instead of one generic button.
export type AppointmentRow = Tables<"appointments">
export type UpcomingAppointmentForConfirmation = AppointmentRow & {
  service_tickets: {
    id: string
    name_of_complaint: string | null
    customers: { name: string } | null
  } | null
}

// "Upcoming" here mirrors the today/tomorrow window a confirmation call is
// actually useful for (call the customer shortly before the technician is
// dispatched, not days in advance). Uses the same
// `new Date(\`${date}T00:00:00\`).toISOString()` day-boundary convention
// getDaySheetSummary below already relies on. confirmation_called_at isn't
// filterable server-side without widening the query builder's column-name
// generic (it's constrained to keyof Row for .is/.gte/.lte), so — same as
// getSlaSettings's locally-widened-row approach — the "not yet called" cut
// is applied client-side after casting the response.
export async function listUpcomingAppointmentsForConfirmation(orgId: string): Promise<UpcomingAppointmentForConfirmation[]> {
  const today = todayIso()
  const tomorrow = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString().slice(0, 10)
  const fromIso = new Date(`${today}T00:00:00`).toISOString()
  const toIso = new Date(`${tomorrow}T23:59:59.999`).toISOString()

  const { data, error } = await supabase
    .from("appointments")
    .select("*, service_tickets(id, name_of_complaint, customers(name))")
    .eq("org_id", orgId)
    .eq("status", "scheduled")
    .gte("scheduled_at", fromIso)
    .lte("scheduled_at", toIso)
    .order("scheduled_at", { ascending: true })
  if (error) throw error
  const rows = data ?? []
  return rows.filter((a) => !a.confirmation_called_at)
}

export async function markAppointmentConfirmationCalled(
  orgId: string,
  userId: string,
  appointmentId: string,
  ticketLabel: string
): Promise<void> {
  const { error: apptError } = await supabase
    .from("appointments")
    .update({ confirmation_called_at: new Date().toISOString() })
    .eq("id", appointmentId)
    .eq("org_id", orgId)
  if (apptError) throw apptError

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
