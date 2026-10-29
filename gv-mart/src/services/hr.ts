import { supabase } from "@/lib/supabase"
import type { Tables } from "@/types/database"

// New file — HR/Payroll (ADM-24 Salary, ADM-25 Incentives, ADM-26 Rewards).
// Master-only per RLS (salaries/incentives_earned/expenses are master-read,
// rewards is staff-read/ops-write) and per nav.ts's existing `hr` gate.
//
// compute_salary/compute_incentives/reward_candidates (migration
// 20260702200200_hr_functions.sql) and technicians.is_active (migration
// 20260702200000_technicians_admin_schema.sql) post-date
// src/types/database.ts — see the equivalent header note in
// src/services/techniciansAdmin.ts for why this file doesn't edit that
// generated file and instead casts narrowly at the call site.

// Monthly Expenses spec (GVMART_MONTHLY_EXPENSES_SPEC.md) — Unit 6's four
// itemised reimbursement lines on `salaries`, and Unit 5's own-bike-
// allowance marker on `incentives_earned`, post-date this file's last real
// codegen the same way credit_source/installation_incentive_credits did
// before being added above — widened locally here rather than editing
// database.ts.
export type SalaryRow = Tables<"salaries"> & {
  recharge_amount: number
  recharge_reason: string | null
  petrol_km: number
  petrol_rate: number
  // Owner revision: the verified claim pays, km x rate is a reference only
  // — see petrol_reference_amount vs petrol_amount in the migration header.
  petrol_reference_amount: number
  petrol_amount: number
  maintenance_amount: number
  bike_allowance_base: number
  bike_allowance_extra: number
  bike_allowance_reason: string | null
  bike_allowance_amount: number
  // Incentive audit, Finding H-03 (payroll-fixes, 2026-10-29) — post-dates this
  // file's last real codegen the same way the other fields above do.
  locked_at: string | null
  logged_expense_id: string | null
  // Connection-map follow-up, Finding F-01 (payroll-fixes2, 2026-10-29) — net
  // is floored at zero; this is the amount the floor absorbed (0 when nothing
  // was floored). Shown on the HR Salary screen, never hidden.
  shortfall_amount: number
}
export type IncentiveEarnedRow = Tables<"incentives_earned"> & { is_bike_allowance: boolean }
export type IncentiveRuleRow = Tables<"incentive_rules">
export type RewardRow = Tables<"rewards">
export type InstallationCreditRow = Tables<"installation_incentive_credits">

/** Cast helper for RPC names added after the last `database.ts` regen. */
function rpc(name: string, args: Record<string, unknown>) {
  return supabase.rpc(name as never, args as never)
}

export type TechnicianOption = { id: string; full_name: string }

export async function listActiveTechnicians(orgId: string): Promise<TechnicianOption[]> {
  const { data, error } = await supabase
    .from("technicians")
    .select("id, is_active, profiles(full_name)")
    .eq("org_id", orgId)
    .eq("is_active" as "is_on_duty", true)
  if (error) throw error
  return ((data ?? []) as unknown as { id: string; profiles: { full_name: string } | null }[]).map((t) => ({
    id: t.id,
    full_name: t.profiles?.full_name ?? "—",
  }))
}

/** Staff Salary (item 1, 2026-09-24 change request) — the non-technician
 * roles, which have no `technicians` row and so never go through
 * compute_salary(). These get a plain manual amount entry instead, per
 * period, written to `expenses` (category='salary', staff_id=profiles.id)
 * the exact same way the technician path's "Log to Accounts" action does. */
export type StaffOption = { id: string; full_name: string; role: "master" | "operation_admin" | "sales_admin"; staff_role_key: string | null; is_active: boolean; receives_new_leads: boolean }

export async function listNonTechnicianStaff(orgId: string): Promise<StaffOption[]> {
  const { data, error } = await supabase
    .from("profiles")
    .select("id, full_name, role, staff_role_key, is_active, receives_new_leads")
    .eq("org_id", orgId)
    .in("role", ["master", "operation_admin", "sales_admin"])
    .order("full_name", { ascending: true })
  if (error) throw error
  return (data ?? []) as StaffOption[]
}

/** Master-only (RLS + guard trigger): activate or deactivate another staff login. */
export async function setStaffActive(profileId: string, isActive: boolean) {
  const { error } = await supabase.from("profiles").update({ is_active: isActive }).eq("id", profileId)
  if (error) throw error
}

/** Link a staff member to a role_base_salaries row (master-only, enforced by
 * a DB trigger). Pass null to unlink. */
export async function setStaffRoleKey(profileId: string, staffRoleKey: string | null) {
  const { error } = await supabase.from("profiles").update({ staff_role_key: staffRoleKey }).eq("id", profileId)
  if (error) throw error
}

// ── ADM-24: Salary ─────────────────────────────────────────────────────────

export type SalaryListItem = SalaryRow & { technicians: { id: string; profiles: { id: string; full_name: string } | null } | null }

export async function listSalaries(orgId: string, period: string): Promise<SalaryListItem[]> {
  const { data, error } = await supabase
    .from("salaries")
    .select("*, technicians(id, profiles(id, full_name))")
    .eq("org_id", orgId)
    .eq("period", period)
    .order("net", { ascending: false })
  if (error) throw error
  return (data ?? []) as unknown as SalaryListItem[]
}

export async function computeSalary(orgId: string, technicianId: string, period: string) {
  const { data, error } = await rpc("compute_salary", {
    p_org_id: orgId,
    p_technician_id: technicianId,
    p_period: period,
  })
  if (error) throw error
  return data as unknown as SalaryRow
}

// ── Incentive audit, Findings H-01/H-03 (payroll-fixes, 2026-10-29) ────────
// "Log to Accounts" now goes through log_salary_to_accounts() instead of a bare
// `expenses` insert — master-only, idempotent (a double-click or a retry is a
// clean no-op, never a raised error), and for the technician path it locks the
// `salaries` row in the same transaction. reopenSalaryPosting() is the only way
// to undo that lock (master-only, a reason is required, voids the posted expense
// and writes one audit row). See
// supabase/migrations/20261117100000_salary_log_to_accounts_idempotent.sql and
// 20261117100001_salary_lock_after_posting_reopen.sql.

export type LogSalaryToAccountsResult = {
  inserted: boolean
  expense_id: string | null
  already_logged_at: string | null
  message: string
}

export async function logSalaryToAccounts(input: {
  orgId: string
  staffId: string
  amount: number
  date: string
  note?: string | null
  salaryId?: string | null
}): Promise<LogSalaryToAccountsResult> {
  const { data, error } = await rpc("log_salary_to_accounts", {
    p_org_id: input.orgId,
    p_staff_id: input.staffId,
    p_amount: input.amount,
    p_date: input.date,
    p_note: input.note ?? null,
    p_salary_id: input.salaryId ?? null,
  })
  if (error) throw error
  return data as unknown as LogSalaryToAccountsResult
}

export type ReopenSalaryPostingResult = {
  salary_id: string
  locked_at: string | null
  reversed_expense_id: string | null
}

/** Master only; reason is required (enforced server-side too). Unlocks the
 * salary row and voids the expense it was posted as, in one transaction, and
 * writes one append-only audit row to `salary_reopen_audit`. */
export async function reopenSalaryPosting(salaryId: string, reason: string): Promise<ReopenSalaryPostingResult> {
  const { data, error } = await rpc("reopen_salary_posting", { p_salary_id: salaryId, p_reason: reason })
  if (error) throw error
  return data as unknown as ReopenSalaryPostingResult
}

// ── ADM-25: Incentives (earned preview) ───────────────────────────────────

export type IncentiveEarnedListItem = IncentiveEarnedRow & {
  technicians: { id: string; profiles: { full_name: string } | null } | null
  incentive_rules: { type: string; threshold: number; amount: number } | null
  installation_incentive_rates: { category: string | null; capacity: string | null; configuration: string | null; flat_amount: number } | null
}

export async function listIncentivesEarned(orgId: string, period: string): Promise<IncentiveEarnedListItem[]> {
  const { data, error } = await supabase
    .from("incentives_earned")
    .select("*, technicians(id, profiles(full_name)), incentive_rules(type, threshold, amount), installation_incentive_rates(category, capacity, configuration, flat_amount)")
    .eq("org_id", orgId)
    .eq("period", period)
    .order("amount", { ascending: false })
  if (error) throw error
  return (data ?? []) as unknown as IncentiveEarnedListItem[]
}

export async function computeIncentives(orgId: string, period: string) {
  const { data, error } = await rpc("compute_incentives", { p_org_id: orgId, p_period: period })
  if (error) throw error
  return (data ?? []) as unknown as IncentiveEarnedRow[]
}

// ── ADM-26: Rewards ────────────────────────────────────────────────────────

export type RewardCategory = "attendance" | "highest_review" | "highest_revenue" | "highest_referral"

export type RewardCandidate = { category: RewardCategory; technician_id: string; metric: number }

export async function getRewardCandidates(orgId: string, period: string): Promise<RewardCandidate[]> {
  const { data, error } = await rpc("reward_candidates", { p_org_id: orgId, p_period: period })
  if (error) throw error
  return (data ?? []) as unknown as RewardCandidate[]
}

export type RewardListItem = RewardRow & {
  technicians: { id: string; profiles: { full_name: string } | null } | null
}

export async function listRewards(orgId: string, period: string): Promise<RewardListItem[]> {
  const { data, error } = await supabase
    .from("rewards")
    .select("*, technicians(id, profiles(full_name))")
    .eq("org_id", orgId)
    .eq("period", period)
    .order("given_at", { ascending: false })
  if (error) throw error
  return (data ?? []) as unknown as RewardListItem[]
}

export type LogRewardInput = {
  orgId: string
  category: RewardCategory
  period: string
  winnerId: string
  givenBy: string
  note?: string | null
}

export async function logReward(input: LogRewardInput) {
  const { data, error } = await supabase
    .from("rewards")
    .insert({
      org_id: input.orgId,
      category: input.category,
      period: input.period,
      winner_id: input.winnerId,
      given_by: input.givenBy,
      note: input.note ?? null,
    })
    .select()
    .single()
  if (error) throw error
  return data
}

/** Calls a master-only staff Edge Function. supabase-js buries the function's own JSON error body in error.context (a Response): surface it if readable. */
async function invokeStaffFunction<T>(name: string, body: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.functions.invoke(name, { body })
  if (error) {
    const context = (error as { context?: unknown }).context as { clone?: () => Response; json?: () => Promise<{ error?: string }> } | undefined
    let message: string | null = null
    try {
      const res = typeof context?.clone === "function" ? context.clone() : context
      if (res && typeof res.json === "function") message = ((await res.json()) as { error?: string })?.error ?? null
    } catch {
      // body unreadable - fall through to the generic error
    }
    throw new Error(message || error.message)
  }
  return data as T
}

/** Master-only: set a new password for an operation_admin / sales_admin login. A generated password is returned once, never stored. */
export async function resetStaffPassword(profileId: string, password?: string): Promise<{ password?: string }> {
  return invokeStaffFunction<{ password?: string }>("admin-reset-staff-password", { profileId, password })
}

export type CreateStaffInput = {
  fullName: string
  email: string
  /** 10-digit mobile number, required. */
  phone: string
  designation: string
  /** Full postal address. */
  address: string
  role: "sales_admin" | "operation_admin"
  /** Typed password; omit to have the server generate one (returned once). */
  password?: string
  /** Optional one-line reason, stored in the audit row. */
  reason?: string
}

/** Master-only: create an office-staff login (email = login). The password is shared in person; a generated one is returned once. */
export async function createStaff(input: CreateStaffInput): Promise<{ id: string; email: string; generated: boolean; password?: string }> {
  return invokeStaffFunction("admin-create-staff", { ...input })
}

// ── Installation-ticket credits (batch-2 item 3) ───────────────────────────
// One credit per completed installation ticket: charge snapshot x units logged. Created pending by create_service_invoice;
// the master approves or voids each one, and Compute counts only approved credits.

export type InstallationCreditListItem = InstallationCreditRow & {
  technicians: { id: string; profiles: { full_name: string } | null } | null
  products: { name: string } | null
}

export async function listInstallationCredits(orgId: string, status?: InstallationCreditRow["status"]): Promise<InstallationCreditListItem[]> {
  let q = supabase
    .from("installation_incentive_credits")
    .select("*, technicians(id, profiles(full_name)), products(name)")
    .eq("org_id", orgId)
    .order("created_at", { ascending: false })
    .limit(200)
  if (status) q = q.eq("status", status)
  const { data, error } = await q
  if (error) throw error
  return (data ?? []) as unknown as InstallationCreditListItem[]
}

export async function approveInstallationCredit(creditId: string) {
  const { error } = await rpc("approve_installation_credit", { p_credit_id: creditId })
  if (error) throw error
}

export async function voidInstallationCredit(creditId: string, reason: string) {
  const { error } = await rpc("void_installation_credit", { p_credit_id: creditId, p_reason: reason })
  if (error) throw error
}

/** Master only; installation tickets that are not yet completed/cancelled. `null` clears the charge. */
export async function setTicketInstallationCharge(ticketId: string, amount: number | null) {
  const { error } = await rpc("set_ticket_installation_charge", { p_ticket_id: ticketId, p_amount: amount })
  if (error) throw error
}
