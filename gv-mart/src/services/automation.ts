import { supabase } from "@/lib/supabase"
import type { Enums, Tables, TablesInsert, TablesUpdate } from "@/types/database"
import type { DateRange } from "./reports"

// ── Leads (ADM-22) ────────────────────────────────────────────────────────
export type LeadRow = Tables<"leads">
export type LeadStatus = Enums<"lead_status">
export type LeadActivityRow = Tables<"lead_activities">

export type LeadListItem = LeadRow & {
  customers: { name: string; mobile: string } | null
  technicians: { profiles: { full_name: string } | null } | null
  // Spare Enquiry multi-product line items (2026-08-05) — every product/
  // spare the lead's enquiry asked for, used to seed the quotation cart
  // with more than one item (see LeadDetailPanel / QuotationFormPage).
  lead_items: {
    id: string
    product_id: string | null
    spare_id: string | null
    qty: number
    products: { name: string; price: number } | null
    spares: { name: string; price: number } | null
  }[]
}

export type LeadFilters = {
  source?: Enums<"lead_source">
  enquiryType?: Enums<"enquiry_type">
  kind?: Enums<"lead_kind">
  /** Owner request 2026-07-29: scopes to leads created within this range,
   *  for the dashboard's period-filtered Lead→Sale Conversion tile. Optional
   *  and additive — every existing caller keeps returning all-time leads. */
  dateRange?: DateRange
  /** Technician-referral surfacing (2026-08-04): CustomerDetailPage's
   *  "referred by" chip filters by customerId, TechnicianDetailPage's and
   *  the technician app's own Referrals list filter by ownerId — both
   *  combined with source: "referral". */
  ownerId?: string
  customerId?: string
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
    .select("*, customers(name, mobile), technicians(profiles(full_name)), lead_items(id, product_id, spare_id, qty, products(name, price), spares(name, price))")
    .eq("org_id", orgId)
    .order("created_at", { ascending: false })
  if (filters.source) query = query.eq("source", filters.source)
  if (filters.enquiryType) query = query.eq("enquiry_type", filters.enquiryType)
  if (filters.kind) query = query.eq("kind", filters.kind)
  if (filters.ownerId) query = query.eq("owner_id", filters.ownerId)
  if (filters.customerId) query = query.eq("customer_id", filters.customerId)
  if (filters.dateRange) {
    query = query.gte("created_at", `${filters.dateRange.from}T00:00:00`).lte("created_at", `${filters.dateRange.to}T23:59:59.999`)
  }
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

export async function listFailedWhatsappOutbox(orgId: string, limit = 50): Promise<WhatsappOutboxRow[]> {
  const { data, error } = await supabase
    .from("whatsapp_outbox")
    .select("*")
    .eq("org_id", orgId)
    .eq("status", "failed")
    .order("created_at", { ascending: false })
    .limit(limit)
  if (error) throw error
  return data ?? []
}

/** Customer-scoped history for CustomerDetailPage's WhatsApp tab — same
 * table as the ops-side Conversations/Failed-Sends views, filtered to one
 * person's number instead of org-wide. */
export async function listWhatsappOutboxForCustomer(orgId: string, mobile: string, limit = 50): Promise<WhatsappOutboxRow[]> {
  const { data, error } = await supabase
    .from("whatsapp_outbox")
    .select("*")
    .eq("org_id", orgId)
    .or(`to_mobile.eq.${mobile},payload->>from.eq.${mobile}`)
    .order("created_at", { ascending: false })
    .limit(limit)
  if (error) throw error
  return data ?? []
}

// ── Conversations (Phase 4 ops surface) ─────────────────────────────────
export type WhatsappConversationRow = Tables<"whatsapp_conversations">
export type WhatsappConversationListItem = WhatsappConversationRow & { customers: { name: string } | null }

export async function listWhatsappConversations(orgId: string, limit = 100): Promise<WhatsappConversationListItem[]> {
  const { data, error } = await supabase
    .from("whatsapp_conversations")
    .select("*, customers(name)")
    .eq("org_id", orgId)
    .order("last_message_at", { ascending: false })
    .limit(limit)
  if (error) throw error
  return (data ?? []) as unknown as WhatsappConversationListItem[]
}

/** Full transcript for one phone number — every inbound/outbound row this
 * conversation's bot turns and the raw Meta deliveries produced, oldest
 * first (reading order). */
export async function listWhatsappTranscript(orgId: string, phone: string): Promise<WhatsappOutboxRow[]> {
  const { data, error } = await supabase
    .from("whatsapp_outbox")
    .select("*")
    .eq("org_id", orgId)
    .or(`to_mobile.eq.${phone},payload->>from.eq.${phone}`)
    .order("created_at", { ascending: true })
  if (error) throw error
  return data ?? []
}

// ── Templates (Phase 4 ops surface) ─────────────────────────────────────
export type WhatsappTemplateRow = Tables<"whatsapp_templates">

export async function listWhatsappTemplates(orgId: string): Promise<WhatsappTemplateRow[]> {
  const { data, error } = await supabase.from("whatsapp_templates").select("*").eq("org_id", orgId).order("name")
  if (error) throw error
  return data ?? []
}
export async function createWhatsappTemplate(row: { org_id: string; name: string; category: string; approval_status: string; body: string; variable_map: Record<string, string> }) {
  const { data, error } = await supabase.from("whatsapp_templates").insert(row).select().single()
  if (error) throw error
  return data
}
export async function updateWhatsappTemplate(id: string, patch: Partial<{ name: string; category: string; approval_status: string; body: string; variable_map: Record<string, string> }>) {
  const { data, error } = await supabase.from("whatsapp_templates").update(patch).eq("id", id).select().single()
  if (error) throw error
  return data
}
export async function deleteWhatsappTemplate(id: string) {
  const { error } = await supabase.from("whatsapp_templates").delete().eq("id", id)
  if (error) throw error
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

/** item_type/item_id is polymorphic (product | spare | gift), not a real
 * foreign key PostgREST can embed-join on — `.select("*, products(name),
 * spares(name)")` throws PGRST200 ("no relationship found"). Resolved the
 * same way attachQuoteRequestItemNames (purchase_quote_requests) already
 * does: separate lookups per item_type, merged client-side. Kept the
 * `products`/`spares` field shape existing callers (PurchaseOrdersTab,
 * PoApprovalPromptModal) already read, so this fixes the query without
 * touching either of them. */
export async function listPoItems(
  poId: string
): Promise<(PoItemRow & { products: { name: string } | null; spares: { name: string } | null; gifts: { name: string } | null })[]> {
  const { data, error } = await supabase.from("po_items").select("*").eq("po_id", poId)
  if (error) throw error
  const rows = data ?? []

  const productIds = rows.filter((r) => r.item_type === "product").map((r) => r.item_id)
  const spareIds = rows.filter((r) => r.item_type === "spare").map((r) => r.item_id)
  const giftIds = rows.filter((r) => r.item_type === "gift").map((r) => r.item_id)
  const [{ data: products }, { data: spares }, { data: gifts }] = await Promise.all([
    productIds.length ? supabase.from("products").select("id,name").in("id", productIds) : Promise.resolve({ data: [] as { id: string; name: string }[] }),
    spareIds.length ? supabase.from("spares").select("id,name").in("id", spareIds) : Promise.resolve({ data: [] as { id: string; name: string }[] }),
    giftIds.length ? supabase.from("gifts").select("id,name").in("id", giftIds) : Promise.resolve({ data: [] as { id: string; name: string }[] }),
  ])
  const productMap = new Map((products ?? []).map((r) => [r.id, r.name]))
  const spareMap = new Map((spares ?? []).map((r) => [r.id, r.name]))
  const giftMap = new Map((gifts ?? []).map((r) => [r.id, r.name]))

  return rows.map((r) => ({
    ...r,
    products: productMap.has(r.item_id) ? { name: productMap.get(r.item_id)! } : null,
    spares: spareMap.has(r.item_id) ? { name: spareMap.get(r.item_id)! } : null,
    gifts: giftMap.has(r.item_id) ? { name: giftMap.get(r.item_id)! } : null,
  }))
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
    // Bill Entry's manual form only represents product/spare lines (see
    // lib/validation/automation.ts's poItemSchema) — a gift line on the last
    // bill (reachable now that gifts reorder through this same quote-
    // request-to-PO path) is simply left out of the prefill rather than
    // breaking the type it's assigned to; the admin can't add a gift line
    // by hand here anyway, so there's nothing useful to prefill it into.
    items = (poItems ?? [])
      .filter((i): i is typeof i & { item_type: "product" | "spare" } => i.item_type === "product" || i.item_type === "spare")
      .map((i) => ({ itemType: i.item_type, itemId: i.item_id, qty: i.qty, price: i.price }))
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
  const giftIds = rows.filter((r) => r.item_type === "gift").map((r) => r.item_id)
  const [{ data: products }, { data: spares }, { data: gifts }] = await Promise.all([
    productIds.length ? supabase.from("products").select("id,name").in("id", productIds) : Promise.resolve({ data: [] as { id: string; name: string }[] }),
    spareIds.length ? supabase.from("spares").select("id,name").in("id", spareIds) : Promise.resolve({ data: [] as { id: string; name: string }[] }),
    giftIds.length ? supabase.from("gifts").select("id,name").in("id", giftIds) : Promise.resolve({ data: [] as { id: string; name: string }[] }),
  ])
  const nameMap = new Map([...(products ?? []), ...(spares ?? []), ...(gifts ?? [])].map((r) => [r.id, r.name]))
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

// ── Supplier Monthly RFQ pipeline (2026-09-01), Phase 2 ──────────────────
export type PurchaseQuoteDismissalRow = Tables<"purchase_quote_dismissals">

/** Suppliers an admin has settled as "not going to reply" for an open
 * request — purely a display concern (see the migration's own comment):
 * resolution already only ever considers logged replies, dismissed or not. */
export async function listQuoteDismissals(requestId: string): Promise<PurchaseQuoteDismissalRow[]> {
  const { data, error } = await supabase.from("purchase_quote_dismissals").select("*").eq("request_id", requestId)
  if (error) throw error
  return data ?? []
}

export async function markQuoteSupplierNoResponse(input: { requestId: string; supplierId: string }) {
  const { data, error } = await supabase.rpc("mark_quote_supplier_no_response", {
    p_request_id: input.requestId,
    p_supplier_id: input.supplierId,
  })
  if (error) throw error
  return data
}

/** PDF-generation piece of the supplier document-quote-request work
 * (compliance investigation, 2026-09-03) — see generate-quote-pdf/index.ts's
 * own header comment for why this is standalone rather than wired into the
 * WhatsApp send path yet. Builds (or regenerates) the letterhead PDF for one
 * quote request and stores its public URL on the request row. */
export async function generateQuoteRequestPdf(requestId: string): Promise<{ url: string }> {
  const { data, error } = await supabase.functions.invoke<{ url: string }>("generate-quote-pdf", { body: { requestId } })
  if (error) {
    // supabase-js buries the Edge Function's own JSON error body in
    // error.context — surface it if present so the admin sees the real
    // reason (e.g. "Quote request not found") instead of a generic
    // "non-2xx status code" message.
    const context = (error as { context?: Response }).context
    let message: string | null = null
    if (context) {
      try {
        const body = await context.clone().json()
        if (body?.error) message = body.error
      } catch {
        // non-JSON body — fall through to the generic error below
      }
    }
    throw message ? new Error(message) : error
  }
  if (!data) throw new Error("No response from generate-quote-pdf")
  return data
}

// ── Supplier Monthly RFQ pipeline (2026-09-01), Phase 3 ──────────────────
/** Superset of approve_purchase_order — applies quantity edits (if any)
 * before releasing the draft PO. See the RPC's own comment for why the
 * approval claim happens before the edits, not after. */
export async function updatePoItemsAndApprove(input: { approvalId: string; items: { id: string; qty: number }[] }) {
  const { error } = await supabase.rpc("update_po_items_and_approve", {
    p_approval_id: input.approvalId,
    p_items: input.items,
  })
  if (error) throw error
}

// ── Supplier Monthly RFQ pipeline (2026-09-01), Phase 4 ──────────────────
/** Receipt confirmation — calls the SAME create_bill_entry RPC BillEntryTab's
 * from-scratch form uses, just from a different-shaped entry point: items
 * come pre-populated from the PO's own po_items (already typed with the
 * real item_type enum, product|spare|gift), where BillEntryTab's PoItemInput
 * is deliberately narrower (product|spare only, matching its item-type
 * picker UI) — reusing it here would mis-type a gift line item were one
 * ever on a supplier PO. create_bill_entry itself now guards against
 * double-submission (Phase 4 migration) — see its own comment. */
export async function confirmPoReceipt(input: {
  orgId: string
  supplierId: string
  poId: string
  items: { itemType: Enums<"item_type">; itemId: string; qty: number; price: number }[]
  gst: number
}) {
  const { data, error } = await supabase.rpc("create_bill_entry", {
    p_org_id: input.orgId,
    p_supplier_id: input.supplierId,
    p_po_id: input.poId,
    p_items: input.items.map((i) => ({ item_type: i.itemType, item_id: i.itemId, qty: i.qty, price: i.price })),
    p_gst: input.gst,
    p_bill_date: new Date().toISOString().slice(0, 10),
    p_bill_image_url: null,
    p_category: "purchase",
  })
  if (error) throw error
  return data
}

// ── WhatsApp bot phrase manager (2026-08-28) ────────────────────────────
// Flat org-level list, same shape entityHooks already covers elsewhere —
// additive staff-added phrases on top of the hardcoded baseline the bot's
// Edge Functions ship with (see whatsapp-status-answers.ts / whatsapp-
// journeys.ts). Scoped to the 13-value wa_trigger_category enum only —
// mechanics/greetings/red-flag phrases have no row shape here at all.
export type WaCustomTriggerPhraseRow = Tables<"wa_custom_trigger_phrases">
export type WaTriggerCategory = Enums<"wa_trigger_category">

export async function listWaCustomTriggerPhrases(orgId: string) {
  const { data, error } = await supabase.from("wa_custom_trigger_phrases").select("*").eq("org_id", orgId).order("created_at", { ascending: false })
  if (error) throw error
  return data
}
export async function createWaCustomTriggerPhrase(row: TablesInsert<"wa_custom_trigger_phrases">) {
  const { data, error } = await supabase.from("wa_custom_trigger_phrases").insert(row).select().single()
  if (error) throw error
  return data
}
export async function updateWaCustomTriggerPhrase(id: string, patch: TablesUpdate<"wa_custom_trigger_phrases">) {
  const { data, error } = await supabase.from("wa_custom_trigger_phrases").update(patch).eq("id", id).select().single()
  if (error) throw error
  return data
}
export async function deleteWaCustomTriggerPhrase(id: string) {
  const { error } = await supabase.from("wa_custom_trigger_phrases").delete().eq("id", id)
  if (error) throw error
}
