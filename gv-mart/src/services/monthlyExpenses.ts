import { supabase } from "@/lib/supabase"
import type { Tables, TablesInsert } from "@/types/database"
import type { DateRange } from "./reports"

// Monthly Expenses spec (GVMART_MONTHLY_EXPENSES_SPEC.md) — mobile recharge,
// bike petrol/maintenance reimbursement, own-bike incentive. See that
// document and the Section 2 report for why each table/column/RLS choice
// matches (or deliberately departs from) the spec's own proposals.

/** Cast helper for RPC names added after the last `database.ts` regen (same
 *  pattern as techniciansAdmin.ts's `rpc()`). */
function rpc(name: string, args: Record<string, unknown>) {
  return supabase.rpc(name as never, args as never)
}

export type TechnicianVehicleRow = Tables<"technician_vehicles">
export type TechnicianKmLogRow = Tables<"technician_km_log">
export type ExpenseClaimRow = Tables<"expense_claims">
export type PersonAllowanceRow = Tables<"person_allowances">
export type MonthlyAdjustmentRow = Tables<"monthly_adjustments">

// ── Unit 1: bike ownership / petrol rate ──────────────────────────────────

export async function listTechnicianVehicleHistory(technicianId: string): Promise<TechnicianVehicleRow[]> {
  const { data, error } = await supabase
    .from("technician_vehicles")
    .select("*")
    .eq("technician_id", technicianId)
    .order("effective_from", { ascending: false })
  if (error) throw error
  return data ?? []
}

export async function setTechnicianVehicle(input: TablesInsert<"technician_vehicles">): Promise<TechnicianVehicleRow> {
  const { data, error } = await supabase.from("technician_vehicles").insert(input).select().single()
  if (error) throw error
  return data
}

/** Ends the currently-open vehicle row (effective_to = the day before
 *  `newEffectiveFrom`) so a new row can start without overlapping — the
 *  caller does this, then setTechnicianVehicle, as two steps rather than
 *  one RPC, since the EXCLUDE constraint is what actually guards
 *  correctness either way. */
export async function closeTechnicianVehicleRow(id: string, effectiveTo: string): Promise<void> {
  const { error } = await supabase.from("technician_vehicles").update({ effective_to: effectiveTo }).eq("id", id)
  if (error) throw error
}

export async function getTechnicianOwnBikeDays(orgId: string, technicianId: string, period: string): Promise<number> {
  const { data, error } = await rpc("technician_own_bike_days", { p_org_id: orgId, p_technician_id: technicianId, p_period: period })
  if (error) throw error
  return data as number
}

// ── Unit 2: kilometre log ──────────────────────────────────────────────────

export async function listKmLogEntries(technicianId: string, range: DateRange): Promise<TechnicianKmLogRow[]> {
  const { data, error } = await supabase
    .from("technician_km_log")
    .select("*")
    .eq("technician_id", technicianId)
    .gte("entry_date", range.from)
    .lte("entry_date", range.to)
    .order("entry_date", { ascending: false })
  if (error) throw error
  return data ?? []
}

/** Append-only — there is deliberately no update/delete function here; a
 *  mistaken entry is corrected with a new compensating entry (§1.5). */
export async function addKmLogEntry(input: TablesInsert<"technician_km_log">): Promise<TechnicianKmLogRow> {
  const { data, error } = await supabase.from("technician_km_log").insert(input).select().single()
  if (error) throw error
  return data
}

export async function getKmLogMonthlySum(orgId: string, technicianId: string, period: string): Promise<number> {
  const { data, error } = await rpc("technician_km_log_sum", { p_org_id: orgId, p_technician_id: technicianId, p_period: period })
  if (error) throw error
  return data as number
}

/** Reference-only approximate distance from the GPS trail already recorded
 *  by live tracking — never replaces the manual log, displayed alongside it. */
export async function getApproxDistanceKm(orgId: string, technicianId: string, period: string): Promise<number> {
  const { data, error } = await rpc("technician_approx_distance_km", { p_org_id: orgId, p_technician_id: technicianId, p_period: period })
  if (error) throw error
  return data as number
}

/** Owner revision: km x rate is a REFERENCE figure only, not the payment —
 *  the verified claim amount is what's paid (see submitExpenseClaim/
 *  verifyExpenseClaim below). Priced per log entry at whatever rate was
 *  effective on that entry's own date, so a rate change mid-month doesn't
 *  re-price earlier entries. Shown on the verification queue next to the
 *  submitted/verified amounts so the admin has something to check against. */
export async function getPetrolReferenceAmount(orgId: string, technicianId: string, period: string): Promise<number> {
  const { data, error } = await rpc("technician_petrol_reference_amount", { p_org_id: orgId, p_technician_id: technicianId, p_period: period })
  if (error) throw error
  return data as number
}

// ── Unit 3: bill submission and verification ──────────────────────────────

const EXPENSE_CLAIM_PHOTO_BUCKET = "expense-claim-photos"

export async function uploadExpenseClaimPhoto(orgId: string, technicianId: string, file: File): Promise<string> {
  const ext = file.type === "image/png" ? "png" : file.type === "image/webp" ? "webp" : "jpg"
  const path = `${orgId}/${technicianId}/${crypto.randomUUID()}.${ext}`
  const { error } = await supabase.storage.from(EXPENSE_CLAIM_PHOTO_BUCKET).upload(path, file, { contentType: file.type })
  if (error) throw error
  return path
}

export async function expenseClaimPhotoSignedUrl(storagePath: string): Promise<string> {
  const { data, error } = await supabase.storage.from(EXPENSE_CLAIM_PHOTO_BUCKET).createSignedUrl(storagePath, 3600)
  if (error) throw error
  return data.signedUrl
}

export async function submitExpenseClaim(input: {
  orgId: string
  claimType: "petrol" | "maintenance"
  submittedAmount: number
  billPhotoPath: string
  period: string
}): Promise<ExpenseClaimRow> {
  const { data, error } = await rpc("submit_expense_claim", {
    p_org_id: input.orgId,
    p_claim_type: input.claimType,
    p_submitted_amount: input.submittedAmount,
    p_bill_photo_path: input.billPhotoPath,
    p_period: input.period,
  })
  if (error) throw error
  return data as unknown as ExpenseClaimRow
}

/** `p_reason` is required by the database whenever `verifiedAmount` differs
 *  from what was submitted (including verifying at 0, which behaves as a
 *  rejection — §1.4) — this just forwards whatever the admin typed. */
export async function verifyExpenseClaim(claimId: string, verifiedAmount: number, reason: string | null): Promise<ExpenseClaimRow> {
  const { data, error } = await rpc("verify_expense_claim", { p_claim_id: claimId, p_verified_amount: verifiedAmount, p_reason: reason })
  if (error) throw error
  return data as unknown as ExpenseClaimRow
}

export async function listExpenseClaimsForVerification(orgId: string): Promise<(ExpenseClaimRow & { technicians: { profiles: { full_name: string } | null } | null })[]> {
  const { data, error } = await supabase
    .from("expense_claims")
    .select("*, technicians(profiles(full_name))")
    .eq("org_id", orgId)
    .is("verified_amount", null)
    .order("submitted_at", { ascending: true })
  if (error) throw error
  return (data ?? []) as unknown as (ExpenseClaimRow & { technicians: { profiles: { full_name: string } | null } | null })[]
}

export async function listMyExpenseClaims(technicianId: string): Promise<ExpenseClaimRow[]> {
  const { data, error } = await supabase
    .from("expense_claims")
    .select("*")
    .eq("technician_id", technicianId)
    .order("submitted_at", { ascending: false })
  if (error) throw error
  return data ?? []
}

// ── Unit 4: allowances and adjustments ─────────────────────────────────────

export async function listPersonAllowanceHistory(profileId: string): Promise<PersonAllowanceRow[]> {
  const { data, error } = await supabase
    .from("person_allowances")
    .select("*")
    .eq("profile_id", profileId)
    .order("effective_from", { ascending: false })
  if (error) throw error
  return data ?? []
}

export async function setPersonAllowance(input: TablesInsert<"person_allowances">): Promise<PersonAllowanceRow> {
  const { data, error } = await supabase.from("person_allowances").insert(input).select().single()
  if (error) throw error
  return data
}

export async function closePersonAllowanceRow(id: string, effectiveTo: string): Promise<void> {
  const { error } = await supabase.from("person_allowances").update({ effective_to: effectiveTo }).eq("id", id)
  if (error) throw error
}

// Owner revision: petrol/maintenance no longer use monthly_adjustments at
// all — the verified claim amount is the payment, and verifying at 0 is
// the refusal (Fix 4). Only recharge and bike_allowance use this mechanism.
export type AdjustmentTarget = "recharge" | "bike_allowance"

export async function addMonthlyAdjustment(input: {
  orgId: string
  profileId: string
  period: string
  target: AdjustmentTarget
  type: "top_up" | "exclude"
  amount: number | null
  reason: string
}): Promise<MonthlyAdjustmentRow> {
  const { data, error } = await supabase
    .from("monthly_adjustments")
    .insert({
      org_id: input.orgId,
      profile_id: input.profileId,
      period: input.period,
      adjustment_target: input.target,
      adjustment_type: input.type,
      amount: input.amount,
      reason: input.reason,
    })
    .select()
    .single()
  if (error) throw error
  return data
}

export async function listMonthlyAdjustments(orgId: string, period: string): Promise<(MonthlyAdjustmentRow & { profiles: { full_name: string } | null })[]> {
  const { data, error } = await supabase
    .from("monthly_adjustments")
    .select("*, profiles(full_name)")
    .eq("org_id", orgId)
    .eq("period", period)
    .order("created_at", { ascending: false })
  if (error) throw error
  return (data ?? []) as unknown as (MonthlyAdjustmentRow & { profiles: { full_name: string } | null })[]
}

export async function setOwnBikeAllowanceBase(orgId: string, amount: number): Promise<void> {
  const { error } = await supabase.from("settings").update({ own_bike_allowance_base: amount } as never).eq("org_id", orgId)
  if (error) throw error
}

// ── Unit 7: monthly report — reads already-computed `salaries` rows, so it
// reconciles with the salary breakdown by construction (same source of
// truth, same convention as every other report tab's client-side
// aggregation — see Section 2 report point 4). ─────────────────────────────

export type MonthlyExpensesReportRow = {
  technicianId: string
  technicianName: string
  rechargeAmount: number
  petrolAmount: number
  maintenanceAmount: number
  bikeAllowanceAmount: number
}

export type MonthlyExpensesReportRpcRow = {
  technician_id: string
  recharge_amount: number
  petrol_amount: number
  maintenance_amount: number
  bike_allowance_amount: number
  technicians: { profiles: { full_name: string } | null } | null
}

/** Pure row shaper, split out from the fetch so it can be unit-tested without
 *  a Supabase client (see monthlyExpenses.test.ts). */
export function mapMonthlyExpensesReport(rows: MonthlyExpensesReportRpcRow[]): MonthlyExpensesReportRow[] {
  return rows.map((r) => ({
    technicianId: r.technician_id,
    technicianName: r.technicians?.profiles?.full_name ?? "—",
    rechargeAmount: r.recharge_amount,
    petrolAmount: r.petrol_amount,
    maintenanceAmount: r.maintenance_amount,
    bikeAllowanceAmount: r.bike_allowance_amount,
  }))
}

export async function getMonthlyExpensesReport(orgId: string, period: string): Promise<MonthlyExpensesReportRow[]> {
  const { data, error } = await supabase
    .from("salaries")
    .select("technician_id, recharge_amount, petrol_amount, maintenance_amount, bike_allowance_amount, technicians(profiles(full_name))")
    .eq("org_id", orgId)
    .eq("period", period)
  if (error) throw error
  return mapMonthlyExpensesReport((data ?? []) as unknown as MonthlyExpensesReportRpcRow[])
}
