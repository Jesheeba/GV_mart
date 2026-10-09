import { supabase } from "@/lib/supabase"
import type { Database, Enums, Tables, TablesInsert, TablesUpdate } from "@/types/database"

// Lead follow-ups (Phase 1). Reads go through list_followups / lead_timeline
// (SECURITY DEFINER, master + sales_admin only); every write is an RPC —
// lead_followups and lead_activities have no client write policies.

export type LeadOutcomeRow = Tables<"lead_outcomes">
export type LeadFollowupRow = Tables<"lead_followups">
export type FollowupType = Enums<"lead_followup_type">
export type FollowupListItem = Database["public"]["Functions"]["list_followups"]["Returns"][number]
export type TimelineEvent = Database["public"]["Functions"]["lead_timeline"]["Returns"][number]
export type LeadWithoutFollowup = Database["public"]["Functions"]["list_leads_without_followup"]["Returns"][number]
export type FollowupBucket = "overdue" | "today" | "upcoming"
export type FollowupCounts = { overdue: number; today: number; total: number; by_person: { id: string; name: string; overdue: number; today: number }[] }
/** My Day scope: "auto" = master all / sales_admin own + unassigned. "person:<uuid>" is master-only. */
export type FollowupScope = "auto" | "all" | "mine" | "unassigned" | "mine_unassigned" | `person:${string}`

export type LeadSchedule = {
  lead_work_days: number[]
  lead_work_start: string
  lead_work_end: string
  lead_stuck_postpones: number
  lead_reminder_minutes: number
}

export const DEFAULT_LEAD_SCHEDULE: LeadSchedule = {
  lead_work_days: [1, 2, 3, 4, 5, 6],
  lead_work_start: "09:30",
  lead_work_end: "19:00",
  lead_stuck_postpones: 3,
  lead_reminder_minutes: 15,
}

// ── outcomes ─────────────────────────────────────────────────────────────
export async function listLeadOutcomes(orgId: string): Promise<LeadOutcomeRow[]> {
  const { data, error } = await supabase.from("lead_outcomes").select("*").eq("org_id", orgId).order("sort_order")
  if (error) throw error
  return data ?? []
}
export async function createLeadOutcome(row: TablesInsert<"lead_outcomes">) {
  const { data, error } = await supabase.from("lead_outcomes").insert(row).select().single()
  if (error) throw error
  return data
}
export async function updateLeadOutcome(id: string, patch: TablesUpdate<"lead_outcomes">) {
  const { data, error } = await supabase.from("lead_outcomes").update(patch).eq("id", id).select().single()
  if (error) throw error
  return data
}

// ── schedule (settings.lead_*) ───────────────────────────────────────────
export async function getLeadSchedule(orgId: string): Promise<LeadSchedule> {
  const { data, error } = await supabase
    .from("settings")
    .select("lead_work_days, lead_work_start, lead_work_end, lead_stuck_postpones, lead_reminder_minutes")
    .eq("org_id", orgId)
    .maybeSingle()
  if (error) throw error
  if (!data) return DEFAULT_LEAD_SCHEDULE
  return { ...data, lead_work_start: data.lead_work_start.slice(0, 5), lead_work_end: data.lead_work_end.slice(0, 5) }
}
export async function updateLeadSchedule(orgId: string, patch: Partial<LeadSchedule>) {
  const { error } = await supabase.from("settings").update(patch).eq("org_id", orgId)
  if (error) throw error
}

// ── reads ────────────────────────────────────────────────────────────────
export type FollowupFilters = {
  bucket?: FollowupBucket | "all"
  stage?: Enums<"lead_status">
  source?: string
  kind?: string
  stuckOnly?: boolean
  scope?: FollowupScope
}

function scopeArgs(scope: FollowupScope | undefined): { p_scope?: string; p_assignee?: string } {
  if (!scope || scope === "auto") return {}
  if (scope.startsWith("person:")) return { p_scope: "person", p_assignee: scope.slice(7) }
  return { p_scope: scope }
}

export async function listFollowups(filters: FollowupFilters = {}): Promise<FollowupListItem[]> {
  const { data, error } = await supabase.rpc("list_followups", {
    p_bucket: filters.bucket ?? "all",
    p_stage: filters.stage ?? null,
    p_source: filters.source ?? null,
    p_kind: filters.kind ?? null,
    p_stuck_only: filters.stuckOnly ?? false,
    ...scopeArgs(filters.scope),
  })
  if (error) throw error
  return data ?? []
}

export async function getFollowupCounts(): Promise<FollowupCounts> {
  const { data, error } = await supabase.rpc("followup_counts")
  if (error) throw error
  const c = (data ?? {}) as Partial<FollowupCounts>
  return { overdue: c.overdue ?? 0, today: c.today ?? 0, total: c.total ?? 0, by_person: c.by_person ?? [] }
}

export async function getLeadTimeline(leadId: string): Promise<TimelineEvent[]> {
  const { data, error } = await supabase.rpc("lead_timeline", { p_lead_id: leadId })
  if (error) throw error
  return data ?? []
}

export async function getOpenFollowup(leadId: string): Promise<LeadFollowupRow | null> {
  const { data, error } = await supabase.from("lead_followups").select("*").eq("lead_id", leadId).eq("status", "open").maybeSingle()
  if (error) throw error
  return data
}

// ── writes (RPC only) ────────────────────────────────────────────────────
export type LogOutcomeInput = {
  leadId: string
  outcomeId: string
  note?: string | null
  channel?: "call" | "whatsapp" | "visit" | "meeting"
  nextDueAt?: string | null
  nextType?: FollowupType | null
  nextNote?: string | null
  nextIsExact?: boolean
  lostReason?: string | null
}
export type LogOutcomeResult = {
  activity_id: string
  followup_id: string | null
  next_due_at: string | null
  status: Enums<"lead_status">
  postpone_count: number
}

export async function logLeadOutcome(i: LogOutcomeInput): Promise<LogOutcomeResult> {
  const { data, error } = await supabase.rpc("log_lead_outcome", {
    p_lead_id: i.leadId,
    p_outcome_id: i.outcomeId,
    p_note: i.note ?? null,
    p_channel: i.channel ?? "call",
    p_next_due_at: i.nextDueAt ?? null,
    p_next_type: i.nextType ?? null,
    p_next_note: i.nextNote ?? null,
    p_next_is_exact: i.nextIsExact ?? false,
    p_lost_reason: i.lostReason ?? null,
  })
  if (error) throw error
  return data as unknown as LogOutcomeResult
}

export async function rescheduleFollowup(i: {
  leadId: string
  newDueAt: string
  reason: string
  type?: FollowupType | null
  note?: string | null
  isExact?: boolean
}) {
  const { data, error } = await supabase.rpc("reschedule_followup", {
    p_lead_id: i.leadId,
    p_new_due_at: i.newDueAt,
    p_reason: i.reason,
    p_type: i.type ?? null,
    p_note: i.note ?? null,
    p_is_exact: i.isExact ?? false,
  })
  if (error) throw error
  return data as unknown as { followup_id: string; next_due_at: string; postpone_count: number }
}

export async function setLeadFollowup(i: { leadId: string; dueAt: string; type?: FollowupType; note?: string | null; isExact?: boolean }) {
  const { data, error } = await supabase.rpc("set_lead_followup", {
    p_lead_id: i.leadId,
    p_due_at: i.dueAt,
    p_type: i.type ?? "call",
    p_note: i.note ?? null,
    p_is_exact: i.isExact ?? false,
  })
  if (error) throw error
  return data as string
}

export async function reopenLead(i: { leadId: string; nextDueAt: string; reason: string; type?: FollowupType; note?: string | null; isExact?: boolean }) {
  const { data, error } = await supabase.rpc("reopen_lead", {
    p_lead_id: i.leadId,
    p_next_due_at: i.nextDueAt,
    p_reason: i.reason,
    p_type: i.type ?? "call",
    p_note: i.note ?? null,
    p_is_exact: i.isExact ?? false,
  })
  if (error) throw error
  return data as unknown as { followup_id: string; next_due_at: string; status: Enums<"lead_status">; stage_was_known: boolean }
}

export async function addLeadNote(leadId: string, note: string) {
  const { data, error } = await supabase.rpc("add_lead_note", { p_lead_id: leadId, p_note: note, p_type: "note" })
  if (error) throw error
  return data as string
}

// ── assignment ───────────────────────────────────────────────────────────
export type LeadAssignee = { id: string; full_name: string; role: Enums<"user_role"> }

/** Active masters + sales_admins of the organisation: the only people a lead can be assigned to. */
export async function listLeadAssignees(orgId: string): Promise<LeadAssignee[]> {
  const { data, error } = await supabase
    .from("profiles")
    .select("id, full_name, role")
    .eq("org_id", orgId)
    .eq("is_active", true)
    .in("role", ["master", "sales_admin"])
    .order("full_name", { ascending: true })
  if (error) throw error
  return (data ?? []) as LeadAssignee[]
}

export async function assignLead(i: { leadId: string; assigneeId: string | null; reason?: string | null }) {
  const { data, error } = await supabase.rpc("assign_lead", { p_lead_id: i.leadId, p_assignee: i.assigneeId, p_reason: i.reason ?? null })
  if (error) throw error
  return data as unknown as { lead_id: string; assigned_to: string | null; previous: string | null }
}

// ── leads without a follow-up ("No follow-up" tab) ───────────────────────
export type NoFollowupFilters = {
  stage?: Enums<"lead_status">
  source?: string
  kind?: string
  scope?: FollowupScope
}

/** Open leads that have no open follow-up, oldest first, within the caller's scope (same rules as My Day). */
export async function listLeadsWithoutFollowup(filters: NoFollowupFilters = {}): Promise<LeadWithoutFollowup[]> {
  const { data, error } = await supabase.rpc("list_leads_without_followup", {
    p_stage: filters.stage ?? null,
    p_source: filters.source ?? null,
    p_kind: filters.kind ?? null,
    ...scopeArgs(filters.scope),
  })
  if (error) throw error
  return data ?? []
}

export type BulkFollowupResult = {
  created: number
  skipped: { lead_id: string; reason: string }[]
  per_day: number | null
  first_day: string | null
  last_day: string | null
}

/** Schedule one follow-up per lead. perDay set = spread N a day over working days (oldest lead first); null = everyone at dueAt. */
export async function setLeadFollowupsBulk(i: { leadIds: string[]; dueAt: string; type?: FollowupType; note?: string | null; perDay?: number | null }) {
  const { data, error } = await supabase.rpc("set_lead_followups_bulk", {
    p_lead_ids: i.leadIds,
    p_due_at: i.dueAt,
    p_type: i.type ?? "call",
    p_note: i.note ?? null,
    p_per_day: i.perDay ?? null,
  })
  if (error) throw error
  return data as unknown as BulkFollowupResult
}
