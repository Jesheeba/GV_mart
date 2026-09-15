import { supabase } from "@/lib/supabase"
import type { Enums, Tables } from "@/types/database"

export type RentalContractRow = Tables<"rental_contracts">
export type RentalStatus = Enums<"rental_status">

export type RentalContractListItem = RentalContractRow & {
  customers: { name: string; mobile: string } | null
  products: { name: string } | null
  rental_plans: { name: string; monthly_rate: number; visits_per_year: number } | null
}

export async function listRentalContracts(orgId: string): Promise<RentalContractListItem[]> {
  const { data, error } = await supabase
    .from("rental_contracts")
    .select("*, customers(name, mobile), products(name), rental_plans(name, monthly_rate, visits_per_year)")
    .eq("org_id", orgId)
    .order("start_date", { ascending: false })
  if (error) throw error
  return (data ?? []) as unknown as RentalContractListItem[]
}

/** A customer's own active rental(s), for Customer Detail's Rent section. */
export async function listCustomerRentalContracts(customerId: string): Promise<RentalContractListItem[]> {
  const { data, error } = await supabase
    .from("rental_contracts")
    .select("*, customers(name, mobile), products(name), rental_plans(name, monthly_rate, visits_per_year)")
    .eq("customer_id", customerId)
    .order("start_date", { ascending: false })
  if (error) throw error
  return (data ?? []) as unknown as RentalContractListItem[]
}

export type CreateRentalInput = {
  orgId: string
  customerId: string
  productId: string
  planId: string
  addressId: string
  startDate: string
  paymentMethod: Enums<"payment_method">
  txnId?: string | null
  paymentDescription?: string | null
}

export async function createRental(input: CreateRentalInput) {
  const { data, error } = await supabase.rpc("create_rental", {
    p_org_id: input.orgId,
    p_customer_id: input.customerId,
    p_product_id: input.productId,
    p_plan_id: input.planId,
    p_address_id: input.addressId,
    p_start_date: input.startDate,
    p_payment_method: input.paymentMethod,
    p_txn_id: input.txnId ?? null,
    p_payment_description: input.paymentDescription ?? null,
  })
  if (error) throw error
  return data as { contract_id: string; invoice_id: string; install_ticket_id: string; visit_ticket_id: string }
}

export async function markRentalReturned(orgId: string, contractId: string) {
  const { error } = await supabase.rpc("mark_rental_returned", { p_org_id: orgId, p_contract_id: contractId })
  if (error) throw error
}
