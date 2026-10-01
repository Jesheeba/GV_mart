import { supabase } from "@/lib/supabase"
import { getOpsResolutionKpi, getSalesServiceReport } from "@/services/reports"
import type { Tables } from "@/types/database"

export type MeetingLog = Tables<"meeting_logs">
export type MeetingIssue = Tables<"meeting_issues">
export type IssueStatus = "open" | "solved"

/** Today in IST as yyyy-mm-dd — the business runs on IST, and the reminder RPC
 * also keys "today" off Asia/Kolkata, so the UI must agree with it. */
export function todayIst(): string {
  return new Date(Date.now() + 5.5 * 3_600_000).toISOString().slice(0, 10)
}

export async function getMeetingLog(orgId: string, date: string): Promise<MeetingLog | null> {
  const { data, error } = await supabase.from("meeting_logs").select("*").eq("org_id", orgId).eq("meeting_date", date).maybeSingle()
  if (error) throw error
  return data
}

/** Creates the day's log on first save (manual creation — a day nobody met has
 * no row). The unique (org_id, meeting_date) makes a double-click race a no-op:
 * we fall back to reading the winner's row. */
export async function ensureMeetingLog(orgId: string, date: string, userId: string): Promise<MeetingLog> {
  const existing = await getMeetingLog(orgId, date)
  if (existing) return existing
  const { data, error } = await supabase.from("meeting_logs").insert({ org_id: orgId, meeting_date: date, recorded_by: userId }).select().single()
  if (error) {
    const raced = await getMeetingLog(orgId, date)
    if (raced) return raced
    throw error
  }
  return data
}

export async function saveMeetingNotes(orgId: string, date: string, userId: string, notes: string): Promise<MeetingLog> {
  const log = await ensureMeetingLog(orgId, date, userId)
  const { data, error } = await supabase.from("meeting_logs").update({ general_notes: notes.trim() || null }).eq("id", log.id).select().single()
  if (error) throw error
  return data
}

/** Issues for a day's agenda: raised in that meeting, still-open ones carried
 * forward from any day (carry-forward is a query, not a copy), and ones that
 * were solved on that date. */
export async function listAgendaIssues(orgId: string, date: string, meetingId: string | null): Promise<MeetingIssue[]> {
  const clauses = ["status.eq.open", `date_solved.eq.${date}`]
  if (meetingId) clauses.push(`meeting_id.eq.${meetingId}`)
  const { data, error } = await supabase
    .from("meeting_issues")
    .select("*")
    .eq("org_id", orgId)
    .or(clauses.join(","))
    .order("date_raised", { ascending: true })
    .order("created_at", { ascending: true })
  if (error) throw error
  return data ?? []
}

export type IssueInput = {
  description: string
  rootCause: string
  solution: string
  ownerId: string | null
}

export async function createIssue(orgId: string, date: string, userId: string, input: IssueInput): Promise<MeetingIssue> {
  const log = await ensureMeetingLog(orgId, date, userId)
  const { data, error } = await supabase
    .from("meeting_issues")
    .insert({
      org_id: orgId,
      meeting_id: log.id,
      description: input.description.trim(),
      root_cause: input.rootCause.trim() || null,
      solution: input.solution.trim() || null,
      owner_id: input.ownerId,
      raised_by: userId,
      date_raised: date,
    })
    .select()
    .single()
  if (error) throw error
  return data
}

export async function updateIssue(id: string, input: IssueInput): Promise<MeetingIssue> {
  const { data, error } = await supabase
    .from("meeting_issues")
    .update({
      description: input.description.trim(),
      root_cause: input.rootCause.trim() || null,
      solution: input.solution.trim() || null,
      owner_id: input.ownerId,
    })
    .eq("id", id)
    .select()
    .single()
  if (error) throw error
  return data
}

export async function setIssueStatus(id: string, status: IssueStatus, date: string): Promise<MeetingIssue> {
  const { data, error } = await supabase
    .from("meeting_issues")
    .update({ status, date_solved: status === "solved" ? date : null })
    .eq("id", id)
    .select()
    .single()
  if (error) throw error
  return data
}

export type IssueSearch = { q: string; status: "all" | IssueStatus; from: string; to: string }

// PostgREST .or() splits on commas/parens, so strip them (and the ilike
// wildcards) from the user's keyword rather than let it corrupt the filter.
function sanitizeKeyword(q: string) {
  return q.replace(/[,()%_*\\]/g, " ").trim()
}

export async function searchIssues(orgId: string, f: IssueSearch): Promise<MeetingIssue[]> {
  let query = supabase.from("meeting_issues").select("*").eq("org_id", orgId)
  const kw = sanitizeKeyword(f.q)
  if (kw) query = query.or(`description.ilike.%${kw}%,root_cause.ilike.%${kw}%,solution.ilike.%${kw}%`)
  if (f.status !== "all") query = query.eq("status", f.status)
  if (f.from) query = query.gte("date_raised", f.from)
  if (f.to) query = query.lte("date_raised", f.to)
  const { data, error } = await query.order("date_raised", { ascending: false }).limit(200)
  if (error) throw error
  return data ?? []
}

/** Past huddles, newest first (technician read-only list). */
export async function listRecentMeetings(orgId: string, limit = 14): Promise<MeetingLog[]> {
  const { data, error } = await supabase.from("meeting_logs").select("*").eq("org_id", orgId).order("meeting_date", { ascending: false }).limit(limit)
  if (error) throw error
  return data ?? []
}

export type IssueTask = {
  id: string
  title: string
  status: string
  due_date: string | null
  ref_id: string
  assignee: { full_name: string } | null
}

/** Action-item tasks linked back to issues (ref_type='meeting_issue'). */
export async function listIssueTasks(orgId: string, issueIds: string[]): Promise<IssueTask[]> {
  if (issueIds.length === 0) return []
  const { data, error } = await supabase
    .from("tasks")
    .select("id, title, status, due_date, ref_id, assignee:profiles!tasks_assignee_id_fkey(full_name)")
    .eq("org_id", orgId)
    .eq("ref_type", "meeting_issue")
    .in("ref_id", issueIds)
  if (error) throw error
  return (data ?? []) as unknown as IssueTask[]
}

export type HuddlePerformance = {
  /** Previous calendar day's numbers — what the team is actually discussing. */
  date: string
  collected: number
  invoiced: number
  completedVisits: number
  resolvedWithin24hPercent: number | null
  openTickets: number
}

function previousDay(date: string): string {
  const d = new Date(`${date}T00:00:00Z`)
  d.setUTCDate(d.getUTCDate() - 1)
  return d.toISOString().slice(0, 10)
}

/** Live from existing report queries — nothing stored, so there's no second
 * copy of the numbers to drift. Staff-only (reports may be RLS-limited). */
export async function getHuddlePerformance(orgId: string, meetingDate: string): Promise<HuddlePerformance> {
  const date = previousDay(meetingDate)
  const range = { from: date, to: date }
  const [sales, ops, open] = await Promise.all([
    getSalesServiceReport(orgId, range),
    getOpsResolutionKpi(orgId, range),
    supabase.from("service_tickets").select("id", { count: "exact", head: true }).eq("org_id", orgId).in("status", ["open", "assigned", "in_progress"]),
  ])
  if (open.error) throw open.error
  return {
    date,
    collected: sales.totalCollected,
    invoiced: sales.totalRevenue,
    completedVisits: ops.totalCompleted,
    resolvedWithin24hPercent: ops.percent,
    openTickets: open.count ?? 0,
  }
}

export async function getHuddleReminderTime(orgId: string): Promise<string | null> {
  const { data, error } = await supabase.from("settings").select("huddle_reminder_time").eq("org_id", orgId).maybeSingle()
  if (error) throw error
  return data?.huddle_reminder_time ?? null
}

export async function setHuddleReminderTime(orgId: string, time: string | null): Promise<void> {
  const { error } = await supabase.from("settings").update({ huddle_reminder_time: time }).eq("org_id", orgId)
  if (error) throw error
}
