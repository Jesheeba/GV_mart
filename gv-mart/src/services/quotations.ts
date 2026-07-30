import { supabase } from "@/lib/supabase"
import type { Enums, Tables } from "@/types/database"
import type { DateRange } from "./reports"

export type QuotationRow = Tables<"quotations">
export type QuotationItemRow = Tables<"quotation_items">

export type QuotationListItem = QuotationRow & { customers: { name: string; mobile: string } | null }

/** `dateRange` is optional and additive (Owner request 2026-07-29, Sales
 *  Dashboard's period-filtered quotation stats) — every existing caller
 *  (QuotationsListPage, SalesListPage) keeps getting all-time quotations. */
export async function listQuotations(orgId: string, dateRange?: DateRange): Promise<QuotationListItem[]> {
  let query = supabase
    .from("quotations")
    .select("*, customers(name,mobile)")
    .eq("org_id", orgId)
    .order("created_at", { ascending: false })
  if (dateRange) {
    query = query.gte("created_at", `${dateRange.from}T00:00:00`).lte("created_at", `${dateRange.to}T23:59:59.999`)
  }
  const { data, error } = await query
  if (error) throw error
  return (data ?? []) as QuotationListItem[]
}

export type QuotationDetail = QuotationRow & {
  customers: { name: string; mobile: string } | null
  quotation_items: (QuotationItemRow & { itemName: string })[]
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

export async function getQuotation(orgId: string, id: string): Promise<QuotationDetail> {
  const { data, error } = await supabase
    .from("quotations")
    .select("*, customers(name,mobile), quotation_items(*)")
    .eq("id", id)
    .single()
  if (error) throw error

  const names = await itemNameLookup(orgId, data.quotation_items)
  return {
    ...data,
    quotation_items: data.quotation_items.map((it) => ({ ...it, itemName: names.get(it.item_id) ?? "—" })),
  } as QuotationDetail
}

export type QuotationCartItem = { itemType: Enums<"item_type">; itemId: string; qty: number }

export async function createQuotation(
  orgId: string,
  customerId: string | null,
  validUntil: string | null,
  items: QuotationCartItem[],
  leadId: string | null = null
): Promise<string> {
  const { data, error } = await supabase.rpc("create_quotation", {
    p_org_id: orgId,
    p_customer_id: customerId,
    p_valid_until: validUntil,
    p_items: items.map((i) => ({ item_type: i.itemType, item_id: i.itemId, qty: i.qty })),
    p_lead_id: leadId,
  })
  if (error) throw error
  return data as string
}

export async function markQuotationLost(id: string, reason: string) {
  const { error } = await supabase.from("quotations").update({ status: "lost", lost_reason: reason }).eq("id", id)
  if (error) throw error
}
