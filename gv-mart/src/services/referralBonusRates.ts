import { supabase } from "@/lib/supabase"

// Referral incentives — Stage 2, DB package 1 (schema + guards + rates table).
// `referral_bonus_rates` + `set_referral_bonus_rate()` are drafted + rehearsed
// (DRYRUN-OK) at gv-mart/supabase/migrations/20261202100000_referral_bonus_schema.sql
// in the feat/referral-incentives worktree but NOT YET APPLIED to the live DB —
// this file is written against the pinned contract in
// _local_only/reports/referral_incentives/stage2_corrections_addendum.md so it
// works the moment that migration lands. The table/RPC post-date this file's
// last real `database.ts` codegen, so every call here casts narrowly at the
// call site, same pattern as src/services/hr.ts's `rpc()` helper.

export type ReferralSource = "sale" | "amc" | "service"

export type ReferralBonusRate = {
  id: string
  org_id: string
  referral_source: ReferralSource | null // null = applies to all sources
  amount: number
  effective_from: string // date, IST
  effective_to: string | null // null = currently active
  created_by: string | null
  created_at: string
  updated_at: string
}

/** Cast helper — table/RPC not yet in the generated types (not applied live yet). */
function rpc(name: string, args: Record<string, unknown>) {
  return supabase.rpc(name as never, args as never)
}

/** Every rate row for this org, newest `effective_from` first. The currently
 *  active row (if any) is the one with `effective_to === null`; everything
 *  else is history. Master-only via RLS (package 1). */
export async function listReferralBonusRates(orgId: string): Promise<ReferralBonusRate[]> {
  const { data, error } = await supabase
    .from("referral_bonus_rates" as never)
    .select("*")
    .eq("org_id", orgId)
    .order("effective_from", { ascending: false })
  if (error) throw error
  return (data ?? []) as unknown as ReferralBonusRate[]
}

export type SetReferralBonusRateInput = {
  orgId: string
  amount: number
  referralSource?: ReferralSource | null
  effectiveFrom?: string | null // date, IST; RPC defaults to today IST when omitted
}

/** master-only RPC: closes the current active row for this
 *  (org, referral_source) pair and inserts a new one — never an in-place
 *  UPDATE (so history is preserved). */
export async function setReferralBonusRate(input: SetReferralBonusRateInput): Promise<void> {
  const { error } = await rpc("set_referral_bonus_rate", {
    p_org_id: input.orgId,
    p_amount: input.amount,
    p_referral_source: input.referralSource ?? null,
    p_effective_from: input.effectiveFrom ?? null,
  })
  if (error) throw error
}
