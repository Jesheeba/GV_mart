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
  /** Referral points to redeem as a flat ₹ discount (settings.referral_point_value per point). create_sale re-validates this against the customer's actual ledger balance server-side — never trust this number, it's only ever a UX convenience here. */
  redeemPoints: number
}

export type SaleResult = {
  spare_invoice_id: string | null
  product_invoice_id: string | null
  amc_invoice_id: string | null
  warranty_ids: string[]
  ticket_ids: string[]
  approval_id: string | null
  redeemed_points: number
  redeemed_amount: number
}

export async function createSale(
  orgId: string,
  customerId: string,
  cart: SaleCart,
  quotationId?: string | null,
  /** Rewards spec (2026-08-04) — optional finder-credit referral for a walk-in sale with no pre-existing lead/quotation. Ignored server-side if the id doesn't resolve to a technician in this org. */
  referredByTechnicianId?: string | null,
  /** Whole-cart amount actually collected — create_sale allocates it across however many of {spare,product,amc} invoices the cart produces and derives each one's payment_status from it. Omitted/undefined defaults server-side to "fully paid" (create_sale's p_amount_paid default). */
  amountPaid?: number | null
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
    p_redeem_points: cart.redeemPoints ?? 0,
    p_referred_by_technician_id: referredByTechnicianId ?? null,
    p_amount_paid: amountPaid ?? null,
  })
  if (error) throw error
  return data as SaleResult
}

// ── Referral wallet (admin/sales-side balance check ahead of redemption) ──
// RLS: referral_points_select_staff permits any org staff to read the full
// ledger directly, same table the customer app reads its own rows from
// (services/customerApp.ts's listMyReferralPoints) — no RPC needed.
export async function getCustomerReferralBalance(customerId: string): Promise<number> {
  const { data, error } = await supabase.from("referral_points").select("points").eq("customer_id", customerId)
  if (error) throw error
  return (data ?? []).reduce((sum, r) => sum + r.points, 0)
}

export type InvoiceListItem = InvoiceRow & {
  customers: { name: string; mobile: string } | null
  /** Human-readable summary of the invoice's line items, e.g. "Kent RO · Grand" or "RO Filter Set +2 more". Built from a real invoice_items → product/spare name lookup, not mock data. */
  itemsSummary: string
}

export async function listInvoices(orgId: string): Promise<InvoiceListItem[]> {
  const { data, error } = await supabase
    .from("invoices")
    .select("*, customers(name,mobile), invoice_items(item_type,item_id,qty)")
    .eq("org_id", orgId)
    .order("created_at", { ascending: false })
  if (error) throw error

  const rows = (data ?? []) as (InvoiceRow & {
    customers: { name: string; mobile: string } | null
    invoice_items: { item_type: Enums<"item_type">; item_id: string; qty: number }[]
  })[]

  const names = await itemNameLookup(orgId, rows.flatMap((r) => r.invoice_items))
  return rows.map(({ invoice_items, ...r }) => {
    const itemNames = invoice_items.map((it) => names.get(it.item_id) ?? "—")
    const itemsSummary = itemNames.length === 0 ? "—" : itemNames.length === 1 ? itemNames[0] : `${itemNames[0]} +${itemNames.length - 1} more`
    return { ...r, itemsSummary }
  })
}

/** Exported for reuse by services/customers.ts (customer-level invoice history needs the same item→name join). */
export async function itemNameLookup(orgId: string, items: { item_type: Enums<"item_type">; item_id: string }[]) {
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

export type InvoiceAddress = { door_no: string | null; flat_no: string | null; street_cross: string | null; area: string | null; pincode: string | null; is_primary: boolean }

export type InvoiceDetail = InvoiceRow & {
  customers: { name: string; mobile: string; addresses: InvoiceAddress[] } | null
  gifts: { name: string } | null
  invoice_items: (InvoiceItemRow & { itemName: string })[]
}

export async function getInvoice(orgId: string, id: string): Promise<InvoiceDetail> {
  const { data, error } = await supabase
    .from("invoices")
    .select("*, customers(name,mobile,addresses(door_no,flat_no,street_cross,area,pincode,is_primary)), gifts(name), invoice_items(*)")
    .eq("id", id)
    .single()
  if (error) throw error

  const names = await itemNameLookup(orgId, data.invoice_items)
  return {
    ...data,
    invoice_items: data.invoice_items.map((it) => ({ ...it, itemName: names.get(it.item_id) ?? "—" })),
  } as InvoiceDetail
}

/** Top up a partial/due invoice with a follow-up payment — the only settlement path besides UPI's record_upi_payment (which is UPI-only and always jumps straight to fully-paid). Server re-derives payment_status from the new amount_paid; never trust a client-computed status. */
export async function recordAdditionalPayment(
  orgId: string,
  invoiceId: string,
  amount: number,
  paymentMethod: Enums<"payment_method">,
  txnId?: string | null,
  paymentDescription?: string | null
): Promise<InvoiceRow> {
  const { data, error } = await supabase.rpc("record_additional_payment", {
    p_org_id: orgId,
    p_invoice_id: invoiceId,
    p_amount: amount,
    p_payment_method: paymentMethod,
    p_txn_id: txnId ?? null,
    p_payment_description: paymentDescription ?? null,
  })
  if (error) throw error
  return data as InvoiceRow
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
  const { data, error } = await supabase.from("organizations").select("name,gst_no,address,phone,business_hours").eq("id", orgId).single()
  if (error) throw error
  return data
}

export async function updateOrganization(
  orgId: string,
  patch: { gst_no: string | null; address: string | null; phone: string | null; business_hours: string | null }
) {
  const { error } = await supabase.from("organizations").update(patch).eq("id", orgId)
  if (error) throw error
}
