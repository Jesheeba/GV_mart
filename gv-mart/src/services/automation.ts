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
  category: Enums<"expense_category">
}) {
  const { data, error } = await supabase.rpc("create_bill_entry", {
    p_org_id: input.orgId,
    p_supplier_id: input.supplierId,
    p_po_id: input.poId,
    p_items: input.items.map((i) => ({ item_type: i.itemType, item_id: i.itemId, qty: i.qty, price: i.price })),
    p_gst: input.gst,
    p_bill_date: input.billDate,
    p_bill_image_url: input.billImageUrl,
    p_category: input.category,
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

// ── Bill Entry prefill (reuse last bill's supplier/items) ───────────────
export type LastBillEntry = {
  supplierId: string
  items: PoItemInput[]
}

/**
 * Most recently filed bill for the org, so Bill Entry can default to
 * "repeat the last bill" instead of always starting blank.
 *
 * `purchase_bills` has no line-item table of its own — `create_bill_entry`
 * (20260702170400_bill_entry_fix.sql) applies each item's qty/price
 * straight to `inventory` + `inventory_movements` and never persists a
 * per-bill item breakdown. The only durable record of what a bill actually
 * contained is `po_items` on the bill's linked `po_id`. So items can only
 * be prefilled when the last bill was linked to a PO; a PO-less last bill
 * still prefills the supplier but returns an empty item list (caller falls
 * back to a blank row, same as the no-history case).
 */
export async function getLastBillEntry(orgId: string): Promise<LastBillEntry | null> {
  const { data: bill, error } = await supabase
    .from("purchase_bills")
    .select("supplier_id, po_id")
    .eq("org_id", orgId)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle()
  if (error) throw error
  if (!bill) return null

  let items: PoItemInput[] = []
  if (bill.po_id) {
    const { data: poItems, error: poItemsError } = await supabase
      .from("po_items")
      .select("item_type, item_id, qty, price")
      .eq("po_id", bill.po_id)
    if (poItemsError) throw poItemsError
    items = (poItems ?? []).map((i) => ({ itemType: i.item_type, itemId: i.item_id, qty: i.qty, price: i.price }))
  }

  return { supplierId: bill.supplier_id, items }
}

// ── Purchase Order quote-first flow (GV.md 3.1/3.2) ──────────────────────
// See supabase/migrations/20260725120000_po_quotation_first_with_timeout_
// safeguard.sql for the full behavior this UI drives: on a reorder crossing,
// a quote request goes to every known supplier of the item instead of an
// immediate PO; an admin logs supplier replies by hand (suppliers aren't app
// users); resolve_purchase_quote_requests (called on this page's mount, no
// pg_cron in this stack) closes out any request whose timeout has passed —
// lowest logged reply wins, or last-known-cheapest if nobody replied.
export type PurchaseQuoteRequestRow = Tables<"purchase_quote_requests">
export type PurchaseQuoteReplyRow = Tables<"purchase_quote_replies">
export type PurchaseQuoteRequestListItem = PurchaseQuoteRequestRow & { itemName: string }

async function attachQuoteRequestItemNames(rows: PurchaseQuoteRequestRow[]): Promise<PurchaseQuoteRequestListItem[]> {
  const productIds = rows.filter((r) => r.item_type === "product").map((r) => r.item_id)
  const spareIds = rows.filter((r) => r.item_type === "spare").map((r) => r.item_id)
  const [{ data: products }, { data: spares }] = await Promise.all([
    productIds.length ? supabase.from("products").select("id,name").in("id", productIds) : Promise.resolve({ data: [] as { id: string; name: string }[] }),
    spareIds.length ? supabase.from("spares").select("id,name").in("id", spareIds) : Promise.resolve({ data: [] as { id: string; name: string }[] }),
  ])
  const nameMap = new Map([...(products ?? []), ...(spares ?? [])].map((r) => [r.id, r.name]))
  return rows.map((r) => ({ ...r, itemName: nameMap.get(r.item_id) ?? "—" }))
}

/** Still-open requests (timeout not yet resolved) — what the admin can log replies against right now. */
export async function listOpenPurchaseQuoteRequests(orgId: string): Promise<PurchaseQuoteRequestListItem[]> {
  const { data, error } = await supabase
    .from("purchase_quote_requests")
    .select("*")
    .eq("org_id", orgId)
    .eq("status", "open")
    .order("requested_at", { ascending: true })
  if (error) throw error
  return attachQuoteRequestItemNames(data ?? [])
}

/** Most recently resolved requests, so the admin can see the outcome (reply/fallback/no_supplier) of anything that just timed out. */
export async function listResolvedPurchaseQuoteRequests(orgId: string, limit = 20): Promise<PurchaseQuoteRequestListItem[]> {
  const { data, error } = await supabase
    .from("purchase_quote_requests")
    .select("*")
    .eq("org_id", orgId)
    .eq("status", "resolved")
    .order("resolved_at", { ascending: false })
    .limit(limit)
  if (error) throw error
  return attachQuoteRequestItemNames(data ?? [])
}

export async function listPurchaseQuoteReplies(requestId: string): Promise<(PurchaseQuoteReplyRow & { suppliers: { name: string } | null })[]> {
  const { data, error } = await supabase
    .from("purchase_quote_replies")
    .select("*, suppliers(name)")
    .eq("request_id", requestId)
    .order("price", { ascending: true })
  if (error) throw error
  return (data ?? []) as unknown as (PurchaseQuoteReplyRow & { suppliers: { name: string } | null })[]
}

/** Resolve-on-view: closes out any request whose timeout has passed. Safe to call on every page load — a no-op when nothing has timed out. */
export async function resolvePurchaseQuoteRequests(orgId: string): Promise<number> {
  const { data, error } = await supabase.rpc("resolve_purchase_quote_requests", { p_org_id: orgId })
  if (error) throw error
  return data ?? 0
}

export async function logPurchaseQuoteReply(input: { requestId: string; supplierId: string; price: number; note?: string | null }) {
  const { data, error } = await supabase.rpc("log_purchase_quote_reply", {
    p_request_id: input.requestId,
    p_supplier_id: input.supplierId,
    p_price: input.price,
    p_note: input.note ?? null,
  })
  if (error) throw error
  return data
}
