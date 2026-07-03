import { supabase } from "@/lib/supabase"
import type { Enums, Tables } from "@/types/database"

export type InvoiceRow = Tables<"invoices">
export type InvoiceItemRow = Tables<"invoice_items">

export type SaleCartSpareItem = { itemId: string; qty: number }
export type SaleCartProductItem = {
  itemId: string
  qty: number
  warranty: boolean
  warrantyMonths?: number
  installation: boolean
}
export type SaleCart = {
  spareItems: SaleCartSpareItem[]
  productItems: SaleCartProductItem[]
  amc: { productId: string; planId: string } | null
  discountPercent: number
  giftId: string | null
  paymentMethod: Enums<"payment_method">
  txnId: string | null
  paymentDescription: string | null
}

export type SaleResult = {
  spare_invoice_id: string | null
  product_invoice_id: string | null
  amc_invoice_id: string | null
  warranty_ids: string[]
  ticket_ids: string[]
  approval_id: string | null
}

export async function createSale(
  orgId: string,
  customerId: string,
  cart: SaleCart,
  quotationId?: string | null
): Promise<SaleResult> {
  const { data, error } = await supabase.rpc("create_sale", {
    p_org_id: orgId,
    p_customer_id: customerId,
    p_cart: {
      spare_items: cart.spareItems.map((i) => ({ item_id: i.itemId, qty: i.qty })),
      product_items: cart.productItems.map((i) => ({
        item_id: i.itemId,
        qty: i.qty,
        warranty: i.warranty,
        warranty_months: i.warrantyMonths ?? null,
        installation: i.installation,
      })),
      amc: cart.amc ? { product_id: cart.amc.productId, plan_id: cart.amc.planId } : null,
      discount_percent: cart.discountPercent,
      gift_id: cart.giftId,
      payment_method: cart.paymentMethod,
      txn_id: cart.txnId,
      payment_description: cart.paymentDescription,
    },
    p_quotation_id: quotationId ?? null,
  })
  if (error) throw error
  return data as SaleResult
}

export type InvoiceListItem = InvoiceRow & { customers: { name: string; mobile: string } | null }

export async function listInvoices(orgId: string): Promise<InvoiceListItem[]> {
  const { data, error } = await supabase
    .from("invoices")
    .select("*, customers(name,mobile)")
    .eq("org_id", orgId)
    .order("created_at", { ascending: false })
  if (error) throw error
  return (data ?? []) as InvoiceListItem[]
}

async function itemNameLookup(orgId: string, items: { item_type: Enums<"item_type">; item_id: string }[]) {
  const productIds = [...new Set(items.filter((i) => i.item_type === "product").map((i) => i.item_id))]
  const spareIds = [...new Set(items.filter((i) => i.item_type === "spare").map((i) => i.item_id))]
  const [productsRes, sparesRes] = await Promise.all([
    productIds.length
      ? supabase.from("products").select("id,name,brands(name),models(name)").eq("org_id", orgId).in("id", productIds)
      : Promise.resolve({ data: [], error: null }),
    spareIds.length ? supabase.from("spares").select("id,name").eq("org_id", orgId).in("id", spareIds) : Promise.resolve({ data: [], error: null }),
  ])
  if (productsRes.error) throw productsRes.error
  if (sparesRes.error) throw sparesRes.error

  const names = new Map<string, string>()
  for (const p of productsRes.data ?? []) {
    const row = p as { id: string; name: string; brands: { name: string } | null; models: { name: string } | null }
    names.set(row.id, [row.brands?.name, row.models?.name, row.name].filter(Boolean).join(" · "))
  }
  for (const s of sparesRes.data ?? []) names.set((s as { id: string; name: string }).id, (s as { name: string }).name)
  return names
}

export type InvoiceDetail = InvoiceRow & {
  customers: { name: string; mobile: string } | null
  gifts: { name: string } | null
  invoice_items: (InvoiceItemRow & { itemName: string })[]
}

export async function getInvoice(orgId: string, id: string): Promise<InvoiceDetail> {
  const { data, error } = await supabase
    .from("invoices")
    .select("*, customers(name,mobile), gifts(name), invoice_items(*)")
    .eq("id", id)
    .single()
  if (error) throw error

  const names = await itemNameLookup(orgId, data.invoice_items)
  return {
    ...data,
    invoice_items: data.invoice_items.map((it) => ({ ...it, itemName: names.get(it.item_id) ?? "—" })),
  } as InvoiceDetail
}

export async function getWarrantiesForInvoice(invoiceId: string) {
  const { data, error } = await supabase.from("warranties").select("*").eq("invoice_id", invoiceId)
  if (error) throw error
  return data
}

export async function getTicketsForInvoice(invoiceId: string) {
  const { data, error } = await supabase.from("service_tickets").select("*").eq("invoice_id", invoiceId)
  if (error) throw error
  return data
}

export async function getAmcContractForInvoice(invoiceId: string) {
  const { data, error } = await supabase.from("amc_contracts").select("*, amc_plans(name,years)").eq("invoice_id", invoiceId).maybeSingle()
  if (error) throw error
  return data
}

export async function getOrganization(orgId: string) {
  const { data, error } = await supabase.from("organizations").select("name,gst_no").eq("id", orgId).single()
  if (error) throw error
  return data
}
