import { supabase } from "@/lib/supabase"

// Referral incentives — Stage 2, DB package 2 (compute_incentives block +
// report RPCs). `referral_bonus_report()` is NOT YET BUILT on the DB side
// (see _local_only/reports/referral_incentives/stage2_corrections_addendum.md,
// package 2) — this file is written against the pinned contract so it works
// the moment that RPC lands. Cast narrowly at the call site, same pattern as
// src/services/hr.ts's `rpc()` helper, since this post-dates the last real
// `database.ts` codegen (it doesn't exist at all yet).

export type ReferrerKind = "technician" | "staff"
export type ReferralSource = "sale" | "amc" | "service"
export type ReferralBonusStatus = "pending" | "approved" | "paid" | "voided"

export type ReferralBonusReportRow = {
  referral_bonus_event_id: string
  referred_by_user_id: string
  referrer_name: string
  referrer_kind: ReferrerKind
  customer_id: string
  customer_name: string
  source: ReferralSource
  qualifying_ref_id: string
  qualified_at: string
  rate_amount: number
  status: ReferralBonusStatus
  month_locked: boolean
  incentives_earned_id: string | null
}

export type ReferralBonusReportSummary = {
  total_events: number
  pending: number
  approved: number
  paid: number
  voided: number
  pending_month_locked: number
  // null for a technician caller (RPC only computes this org-wide, for staff/master) — see
  // DB package 2's referral_bonus_report.
  pending_no_rate: number | null
}

export type ReferralBonusReport = {
  summary: ReferralBonusReportSummary
  rows: ReferralBonusReportRow[]
}

function rpc(name: string, args: Record<string, unknown>) {
  return supabase.rpc(name as never, args as never)
}

/** `p_period` is a calendar-month date (e.g. "2026-11-01"), same IST-month
 *  idiom every other incentives RPC in this codebase uses.
 *  `p_technician_id` omitted/undefined → org-wide (master); a technician
 *  caller always sees only their own rows regardless of what id is passed
 *  (RLS, mirrors `referral_overview`). */
export async function getReferralBonusReport(period: string, technicianId?: string | null): Promise<ReferralBonusReport> {
  const { data, error } = await rpc("referral_bonus_report", { p_period: period, p_technician_id: technicianId ?? null })
  if (error) throw error
  return (data ?? { summary: { total_events: 0, pending: 0, approved: 0, paid: 0, voided: 0, pending_month_locked: 0 }, rows: [] }) as unknown as ReferralBonusReport
}
