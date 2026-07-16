import { supabase } from "@/lib/supabase"
import type { Enums, Tables } from "@/types/database"

// ── Leads (ADM-22) ────────────────────────────────────────────────────────
export type LeadRow = Tables<"leads">
export type LeadStatus = Enums<"lead_status">
export type LeadActivityRow = Tables<"lead_activities">

export type LeadListItem = LeadRow & {
  customers: { name: string; mobile: string } | null
  technicians: { profiles: { full_name: string } | null } | null
}

export type LeadFilters = {
  source?: Enums<"lead_source">
  enquiryType?: Enums<"enquiry_type">
  kind?: Enums<"lead_kind">
}

/**
 * `enquiryType` filters on `leads.enquiry_type` — a Product-Enquiry topic
 * tag (online/price/quality/customization/water_premium/budget). `kind`
 * filters on `leads.kind` — the broad Service/Spare/Product/AMC category
 * (added by the lead-pipeline-completeness migration; nullable, since older
 * or ambiguous leads may not cleanly map to one). `source` is the channel
 * discriminator ("which channel did this come from").
 */
export async function listLeads(orgId: string, filters: LeadFilters = {}): Promise<LeadListItem[]> {
  let query = supabase
    .from("leads")
    .select("*, customers(name, mobile), technicians(profiles(full_name))")
    .eq("org_id", orgId)
    .order("created_at", { ascending: false })
  if (filters.source) query = query.eq("source", filters.source)
  if (filters.enquiryType) query = query.eq("enquiry_type", filters.enquiryType)
  if (filters.kind) query = query.eq("kind", filters.kind)
  const { data, error } = await query
  if (error) throw error
  return (data ?? []) as unknown as LeadListItem[]
}

export async function createLead(row: {
  org_id: string
  name: string
  mobile: string | null
  source: Enums<"lead_source">
  enquiry_type: Enums<"enquiry_type"> | null
  kind?: Enums<"lead_kind"> | null
}) {
  const { data, error } = await supabase.from("leads").insert(row).select().single()
  if (error) throw error
  return data
}

export async function listLeadActivities(leadId: string): Promise<LeadActivityRow[]> {
  const { data, error } = await supabase.from("lead_activities").select("*").eq("lead_id", leadId).order("at", { ascending: false })
  if (error) throw error
  return data ?? []
}

export async function logLeadActivity(leadId: string, type: string, note: string | null) {
  const { data, error } = await supabase.rpc("log_lead_activity", { p_lead_id: leadId, p_type: type, p_note: note })
  if (error) throw error
  return data
}

export async function updateLeadStatus(leadId: string, status: LeadStatus) {
  const { error } = await supabase.rpc("update_lead_status", { p_lead_id: leadId, p_status: status })
  if (error) throw error
}

export async function awardReferralPoints(input: { orgId: string; customerId: string; points: number; reason: string | null; refId: string | null }) {
  const { data, error } = await supabase.rpc("award_referral_points", {
    p_org_id: input.orgId,
    p_customer_id: input.customerId,
    p_points: input.points,
    p_reason: input.reason,
    p_ref_id: input.refId,
  })
  if (error) throw error
  return data
}

// ── WhatsApp/AI flow builder (ADM-23) ───────────────────────────────────
export type AutomationFlowRow = Tables<"automation_flows">
export type VideoLibraryRow = Tables<"video_library">
export type WhatsappOutboxRow = Tables<"whatsapp_outbox">

export async function listAutomationFlows(orgId: string): Promise<AutomationFlowRow[]> {
  const { data, error } = await supabase.from("automation_flows").select("*").eq("org_id", orgId).order("trigger")
  if (error) throw error
  return data ?? []
}
export async function createAutomationFlow(row: { org_id: string; trigger: Enums<"enquiry_type">; action: Enums<"automation_action">; asset_url: string | null; is_active: boolean }) {
  const { data, error } = await supabase.from("automation_flows").insert(row).select().single()
  if (error) throw error
  return data
}
export async function updateAutomationFlow(id: string, patch: Partial<{ trigger: Enums<"enquiry_type">; action: Enums<"automation_action">; asset_url: string | null; is_active: boolean }>) {
  const { data, error } = await supabase.from("automation_flows").update(patch).eq("id", id).select().single()
  if (error) throw error
  return data
}
export async function deleteAutomationFlow(id: string) {
  const { error } = await supabase.from("automation_flows").delete().eq("id", id)
  if (error) throw error
}

export async function listVideoLibrary(orgId: string): Promise<VideoLibraryRow[]> {
  const { data, error } = await supabase.from("video_library").select("*").eq("org_id", orgId).order("topic")
  if (error) throw error
  return data ?? []
}
export async function createVideoLibraryEntry(row: { org_id: string; topic: Enums<"enquiry_type">; url: string }) {
  const { data, error } = await supabase.from("video_library").insert(row).select().single()
  if (error) throw error
  return data
}
export async function updateVideoLibraryEntry(id: string, patch: Partial<{ topic: Enums<"enquiry_type">; url: string }>) {
  const { data, error } = await supabase.from("video_library").update(patch).eq("id", id).select().single()
  if (error) throw error
  return data
}
export async function deleteVideoLibraryEntry(id: string) {
  const { error } = await supabase.from("video_library").delete().eq("id", id)
  if (error) throw error
}

export async function listWhatsappOutbox(orgId: string, limit = 50): Promise<WhatsappOutboxRow[]> {
  const { data, error } = await supabase
    .from("whatsapp_outbox")
    .select("*")
    .eq("org_id", orgId)
    .order("created_at", { ascending: false })
    .limit(limit)
  if (error) throw error
  return data ?? []
}

export async function simulateInboundWhatsapp(input: { orgId: string; fromMobile: string; body: string }) {
  const { data, error } = await supabase.rpc("simulate_inbound_whatsapp", {
    p_org_id: input.orgId,
    p_from_mobile: input.fromMobile,
    p_body: input.body,
  })
  if (error) throw error
  return data
}

// ── Purchase Orders & Bill Entry (ADM-20/21) ─────────────────────────────
export type PurchaseOrderRow = Tables<"purchase_orders">
export type PoItemRow = Tables<"po_items">
export type PurchaseBillRow = Tables<"purchase_bills">

export type PurchaseOrderListItem = PurchaseOrderRow & {
  suppliers: { name: string } | null
}

export async function listPurchaseOrders(orgId: string): Promise<PurchaseOrderListItem[]> {
  const { data, error } = await supabase
    .from("purchase_orders")
    .select("*, suppliers(name)")
    .eq("org_id", orgId)
    .order("created_at", { ascending: false })
  if (error) throw error
  return (data ?? []) as unknown as PurchaseOrderListItem[]
}

export async function listPoItems(poId: string): Promise<(PoItemRow & { products: { name: string } | null; spares: { name: string } | null })[]> {
  const { data, error } = await supabase.from("po_items").select("*, products(name), spares(name)").eq("po_id", poId)
  if (error) throw error
  return (data ?? []) as unknown as (PoItemRow & { products: { name: string } | null; spares: { name: string } | null })[]
}

export type PoItemInput = { itemType: "product" | "spare"; itemId: string; qty: number; price: number }

export async function createPurchaseOrder(input: { orgId: string; supplierId: string; items: PoItemInput[] }) {
  const { data, error } = await supabase.rpc("create_purchase_order", {
    p_org_id: input.orgId,
    p_supplier_id: input.supplierId,
    p_items: input.items.map((i) => ({ item_type: i.itemType, item_id: i.itemId, qty: i.qty, price: i.price })),
  })
  if (error) throw error
  return data
}

export async function createBillEntry(input: {
  orgId: string
  supplierId: string
  poId: string | null
  items: PoItemInput[]
  gst: number
  billDate: string
  billImageUrl: string | null
}) {
  const { data, error } = await supabase.rpc("create_bill_entry", {
    p_org_id: input.orgId,
    p_supplier_id: input.supplierId,
    p_po_id: input.poId,
    p_items: input.items.map((i) => ({ item_type: i.itemType, item_id: i.itemId, qty: i.qty, price: i.price })),
    p_gst: input.gst,
    p_bill_date: input.billDate,
    p_bill_image_url: input.billImageUrl,
  })
  if (error) throw error
  return data
}

export async function listPurchaseBills(orgId: string): Promise<(PurchaseBillRow & { suppliers: { name: string } | null })[]> {
  const { data, error } = await supabase
    .from("purchase_bills")
    .select("*, suppliers(name)")
    .eq("org_id", orgId)
    .order("created_at", { ascending: false })
  if (error) throw error
  return (data ?? []) as unknown as (PurchaseBillRow & { suppliers: { name: string } | null })[]
}
