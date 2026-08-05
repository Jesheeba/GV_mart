import { supabase } from "@/lib/supabase"
import type { Enums, Tables } from "@/types/database"

export type AmcContractRow = Tables<"amc_contracts">
export type WarrantyRow = Tables<"warranties">
export type AmcStatus = Enums<"amc_status">

export type AmcContractListItem = AmcContractRow & {
  customers: { name: string; mobile: string } | null
  products: { name: string } | null
  amc_plans: { name: string; years: number; price: number; price_per_year: number | null } | null
}

export type WarrantyListItem = WarrantyRow & {
  customers: { name: string; mobile: string } | null
  products: { name: string } | null
}

export async function listAmcContracts(orgId: string): Promise<AmcContractListItem[]> {
  const { data, error } = await supabase
    .from("amc_contracts")
    .select("*, customers(name, mobile), products(name), amc_plans(name, years, price, price_per_year)")
    .eq("org_id", orgId)
    .order("expiry_date")
  if (error) throw error
  return (data ?? []) as unknown as AmcContractListItem[]
}

export async function listWarranties(orgId: string): Promise<WarrantyListItem[]> {
  const { data, error } = await supabase
    .from("warranties")
    .select("*, customers(name, mobile), products(name)")
    .eq("org_id", orgId)
    .order("expiry_date")
  if (error) throw error
  return (data ?? []) as unknown as WarrantyListItem[]
}

export async function refreshAmcStatuses(orgId: string) {
  const { error } = await supabase.rpc("refresh_amc_statuses", { p_org_id: orgId })
  if (error) throw error
}

export type SellAmcInput = {
  orgId: string
  customerId: string
  productId: string
  planId: string
  startDate: string
  /** Fix 1: choose a duration other than the plan's own default `years`.
   * Optional — sell_amc_plan falls back to the plan's own years when
   * omitted, for backward compatibility. */
  years?: number
  /** Rewards spec (2026-08-04) — optional finder-credit referral. Ignored server-side if the id doesn't resolve to a technician in this org. */
  referredByTechnicianId?: string | null
}

export async function sellAmcPlan(input: SellAmcInput) {
  const { data, error } = await supabase.rpc("sell_amc_plan", {
    p_org_id: input.orgId,
    p_customer_id: input.customerId,
    p_product_id: input.productId,
    p_plan_id: input.planId,
    p_start_date: input.startDate,
    p_years: input.years ?? null,
    p_referred_by_technician_id: input.referredByTechnicianId ?? null,
  })
  if (error) throw error
  return data as { contract_id: string; ticket_ids: string[]; expiry_date: string }
}

export type AmcContractDetail = AmcContractListItem

export async function getAmcContract(id: string): Promise<AmcContractDetail> {
  const { data, error } = await supabase
    .from("amc_contracts")
    .select("*, customers(name, mobile), products(name), amc_plans(name, years, price, price_per_year)")
    .eq("id", id)
    .single()
  if (error) throw error
  return data as unknown as AmcContractDetail
}

export type AmcContractVisit = {
  id: string
  name_of_complaint: string | null
  status: Enums<"ticket_status">
  appointments: { id: string; scheduled_at: string | null; status: Enums<"appointment_status"> }[]
}

/** All visit tickets `sell_amc_plan`/`renew_amc_plan` scheduled for one contract (IMPROVEMENT #4). */
export async function listAmcContractVisits(contractId: string): Promise<AmcContractVisit[]> {
  // `contract_id` (migration 20260713090000) predates the next regeneration of
  // types/database.ts, so the generated service_tickets Row type doesn't know
  // it yet — cast the column name so `.eq()` accepts the real, live column.
  const { data, error } = await supabase
    .from("service_tickets")
    .select("id, name_of_complaint, status, appointments(id, scheduled_at, status)")
    .eq("contract_id" as "id", contractId)
    .order("created_at")
  if (error) throw error
  return (data ?? []) as unknown as AmcContractVisit[]
}

/** RO products only — AMC (Design Deltas §14/17) is sold only on RO. */
export async function listRoProducts(orgId: string) {
  const { data, error } = await supabase
    .from("products")
    .select("id, name, brands(name), models(name)")
    .eq("org_id", orgId)
    .eq("category", "ro")
    // Task 6 (2026-07-30): don't offer an admin-disabled product for a new
    // AMC sale — see 20260730170000_product_spare_mapping_and_active_flags.sql.
    .eq("is_active", true)
    .order("name")
  if (error) throw error
  return data ?? []
}
