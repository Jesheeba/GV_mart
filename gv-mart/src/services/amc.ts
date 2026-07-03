import { supabase } from "@/lib/supabase"
import type { Enums, Tables } from "@/types/database"

export type AmcContractRow = Tables<"amc_contracts">
export type WarrantyRow = Tables<"warranties">
export type AmcStatus = Enums<"amc_status">

export type AmcContractListItem = AmcContractRow & {
  customers: { name: string; mobile: string } | null
  products: { name: string } | null
  amc_plans: { name: string; years: number } | null
}

export type WarrantyListItem = WarrantyRow & {
  customers: { name: string; mobile: string } | null
  products: { name: string } | null
}

export async function listAmcContracts(orgId: string): Promise<AmcContractListItem[]> {
  const { data, error } = await supabase
    .from("amc_contracts")
    .select("*, customers(name, mobile), products(name), amc_plans(name, years)")
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
}

export async function sellAmcPlan(input: SellAmcInput) {
  const { data, error } = await supabase.rpc("sell_amc_plan", {
    p_org_id: input.orgId,
    p_customer_id: input.customerId,
    p_product_id: input.productId,
    p_plan_id: input.planId,
    p_start_date: input.startDate,
  })
  if (error) throw error
  return data as { contract_id: string; ticket_ids: string[]; expiry_date: string }
}

/** RO products only — AMC (Design Deltas §14/17) is sold only on RO. */
export async function listRoProducts(orgId: string) {
  const { data, error } = await supabase
    .from("products")
    .select("id, name, brands(name), models(name)")
    .eq("org_id", orgId)
    .eq("category", "ro")
    .order("name")
  if (error) throw error
  return data ?? []
}
