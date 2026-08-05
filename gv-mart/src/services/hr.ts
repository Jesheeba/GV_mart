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

// ── ADM-24: Salary ─────────────────────────────────────────────────────────

export type SalaryListItem = SalaryRow & { technicians: { id: string; profiles: { full_name: string } | null } | null }

export async function listSalaries(orgId: string, period: string): Promise<SalaryListItem[]> {
  const { data, error } = await supabase
    .from("salaries")
    .select("*, technicians(id, profiles(full_name))")
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
}

export async function listIncentivesEarned(orgId: string, period: string): Promise<IncentiveEarnedListItem[]> {
  const { data, error } = await supabase
    .from("incentives_earned")
    .select("*, technicians(id, profiles(full_name)), incentive_rules(type, threshold, amount)")
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
