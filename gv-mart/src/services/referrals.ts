import { supabase } from "@/lib/supabase"

// Referral incentives — merged service file (owner-requested merge of 3 parallel UI streams'
// identically-named src/services/referrals.ts: ui-forms [listActiveReferrers], masters-report
// [getReferralBonusReport], tech-app [getReferralBonusPreview]). Kept byte-identical across all
// 3 branches on purpose so a git merge between them sees no conflict on this file.
//
// All 3 RPCs (`list_active_referrers`, `referral_bonus_report`, `referral_bonus_preview`) are
// built and committed on the DB side (feat/referral-incentives, packages 1-2) but not yet applied
// to the live database — these calls will start working the moment that apply happens. Cast
// narrowly at the call site (same pattern as src/services/hr.ts's `rpc()` helper) since these
// RPC names post-date the last real `database.ts` codegen.

function rpc(name: string, args: Record<string, unknown>) {
  return supabase.rpc(name as never, args as never)
}

// ── list_active_referrers (ui-forms stream: customer + lead "Referred by" picker) ───────────
//
// kind='technician' rows are active technicians (technicians.is_active + profiles.is_active,
// same filter as listActiveTechnicians in services/hr.ts); kind='staff' rows are active
// non-technician staff. Both already excluded to active-only server-side per plan.md §1.5/§3.2 —
// this picker must NOT repeat the "no active filter" trap the existing NewSalePage/SellAmcPanel/
// NewComplaintPage "Referred by technician" pickers have (listTechnicians, services/service.ts)
// — those three screens are a separate, already-approved PR, untouched by this feature.

export type ActiveReferrer = { id: string; full_name: string; kind: "technician" | "staff" }

export async function listActiveReferrers(orgId: string): Promise<ActiveReferrer[]> {
  const { data, error } = await rpc("list_active_referrers", { p_org_id: orgId })
  if (error) throw error
  return (data ?? []) as unknown as ActiveReferrer[]
}

// ── Shared referral-bonus report/preview types (masters-report stream's richer shape, which
// matches the actual live referral_bonus_report RPC response exactly — confirmed against the DB
// stream's package 2 migration, including month_locked per row and pending_no_rate in summary,
// which an earlier draft of the tech-app stream's own types was missing) ──────────────────────

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
  // null for a technician caller (the RPC only computes this org-wide, for staff/master).
  pending_no_rate: number | null
}

export type ReferralBonusReport = {
  summary: ReferralBonusReportSummary
  rows: ReferralBonusReportRow[]
}

// ── referral_bonus_report (masters-report stream: HR/Masters report + rate card screens) ────
//
// `p_period` is a calendar-month date (e.g. "2026-11-01"), same IST-month idiom every other
// incentives RPC in this codebase uses. `p_technician_id` omitted/undefined → org-wide (master);
// a technician caller always sees only their own rows regardless of what id is passed (RLS,
// mirrors `referral_overview`).

export async function getReferralBonusReport(period: string, technicianId?: string | null): Promise<ReferralBonusReport> {
  const { data, error } = await rpc("referral_bonus_report", { p_period: period, p_technician_id: technicianId ?? null })
  if (error) throw error
  return (data ?? { summary: { total_events: 0, pending: 0, approved: 0, paid: 0, voided: 0, pending_month_locked: 0, pending_no_rate: null }, rows: [] }) as unknown as ReferralBonusReport
}

// ── referral_bonus_preview (tech-app stream: technician's own Profile "this month so far") ──
//
// Same response shape as referral_bonus_report, but scoped server-side to the calling
// technician (no technician-id param needed/accepted) and always the current open IST month.
// Reuses ReferralBonusReport — do not redeclare a separate preview-only type.

export async function getReferralBonusPreview(orgId: string): Promise<ReferralBonusReport> {
  const { data, error } = await rpc("referral_bonus_preview", { p_org_id: orgId })
  if (error) throw error
  return (data ?? { summary: { total_events: 0, pending: 0, approved: 0, paid: 0, voided: 0, pending_month_locked: 0, pending_no_rate: null }, rows: [] }) as unknown as ReferralBonusReport
}

// ── Package 5: show the resolved referrer to staff (customer/lead detail, "Referred by" column
// in both lists). Two batch RPCs, max 200 ids each (enforced server-side) -- a row is simply
// absent from the result for an id with no referrer, a cross-org id, or beyond the cap, so the
// caller only needs to look up by id and treat a miss as "no referrer", never as an error. ─────

export type ReferrerSourceLabel = "direct" | "from earlier lead"

export type CustomerReferrer = {
  customer_id: string
  referrer_id: string
  referrer_name: string
  referrer_role: string
  source_label: ReferrerSourceLabel
}

export type LeadReferrer = {
  lead_id: string
  referrer_id: string
  referrer_name: string
  referrer_role: string
}

const MAX_REFERRER_BATCH_IDS = 200

export async function getReferrersForCustomers(customerIds: string[]): Promise<CustomerReferrer[]> {
  if (customerIds.length === 0) return []
  const { data, error } = await rpc("get_referrers_for_customers", { p_customer_ids: customerIds.slice(0, MAX_REFERRER_BATCH_IDS) })
  if (error) throw error
  return (data ?? []) as unknown as CustomerReferrer[]
}

export async function getReferrersForLeads(leadIds: string[]): Promise<LeadReferrer[]> {
  if (leadIds.length === 0) return []
  const { data, error } = await rpc("get_referrers_for_leads", { p_lead_ids: leadIds.slice(0, MAX_REFERRER_BATCH_IDS) })
  if (error) throw error
  return (data ?? []) as unknown as LeadReferrer[]
}
