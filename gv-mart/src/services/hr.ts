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

export type SalaryRow = Tables<"salaries">
export type IncentiveEarnedRow = Tables<"incentives_earned">
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
  phone?: string
  role: "sales_admin" | "operation_admin"
  /** Optional job title (1-80 characters). */
  designation?: string
  /** Optional postal address (up to 300 characters). */
  address?: string
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
