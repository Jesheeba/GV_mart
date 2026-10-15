import { supabase } from "@/lib/supabase"
import { getIstNow, istDayStartIso, istDayEndIso } from "@/lib/ist"
import type { Tables } from "@/types/database"

export type TaskRow = Tables<"tasks">
export type NotificationRow = Tables<"notifications">

function todayIso() {
  return getIstNow().date
}

// P3 (My Workspace merged into Tasks, 2026-11): the to-do checklist, its lazy rollover, its own quick-add and its
// embedded notifications feed all moved — see src/app/admin/tasks/MyDayView.tsx (reads the same useOrgTasks list
// every Tasks tab uses, filtered to the caller), src/services/tasks.ts (setTaskStatus, moveTaskToToday — an
// explicit action now, not a silent mutation on every read) and the dedicated Notifications pages (which never
// used listMyNotificationsFeed in the first place). What's left here is specific to appointments and the
// technician day-sheet, neither of which belonged to the to-do list.

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
  const tomorrow = new Date(Date.parse(today) + 24 * 60 * 60 * 1000).toISOString().slice(0, 10)
  const fromIso = istDayStartIso(today)
  const toIso = istDayEndIso(tomorrow)

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
  const dayStartIso = istDayStartIso(date)
  const dayEndIso = istDayEndIso(date)

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
