import { supabase } from "@/lib/supabase"
import type { Enums, Tables } from "@/types/database"

// ══════════════════════════════════════════════════════════════════════
// ADM-32 Notifications Center
// ══════════════════════════════════════════════════════════════════════
export type NotificationRow = Tables<"notifications">

export async function listAllMyNotifications(
  orgId: string,
  userId: string,
  role: Enums<"user_role">,
  filters: { type?: string; readStatus?: "read" | "unread" }
): Promise<NotificationRow[]> {
  let ownQuery = supabase.from("notifications").select("*").eq("org_id", orgId).eq("user_id", userId)
  let roleQuery = supabase.from("notifications").select("*").eq("org_id", orgId).eq("role", role)

  if (filters.type) {
    ownQuery = ownQuery.eq("type", filters.type)
    roleQuery = roleQuery.eq("type", filters.type)
  }
  if (filters.readStatus) {
    const isRead = filters.readStatus === "read"
    ownQuery = ownQuery.eq("is_read", isRead)
    roleQuery = roleQuery.eq("is_read", isRead)
  }

  const [ownRes, roleRes] = await Promise.all([
    ownQuery.order("created_at", { ascending: false }).limit(200),
    roleQuery.order("created_at", { ascending: false }).limit(200),
  ])
  if (ownRes.error) throw ownRes.error
  if (roleRes.error) throw roleRes.error

  const merged = [...(ownRes.data ?? []), ...(roleRes.data ?? [])]
  merged.sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime())
  return merged
}

/** Unfiltered distinct notification types for the type-filter dropdown, so picking a type doesn't collapse the option list to just that type. */
export async function listMyNotificationTypes(orgId: string, userId: string, role: Enums<"user_role">): Promise<string[]> {
  const [ownRes, roleRes] = await Promise.all([
    supabase.from("notifications").select("type").eq("org_id", orgId).eq("user_id", userId).limit(1000),
    supabase.from("notifications").select("type").eq("org_id", orgId).eq("role", role).limit(1000),
  ])
  if (ownRes.error) throw ownRes.error
  if (roleRes.error) throw roleRes.error
  return [...new Set([...(ownRes.data ?? []), ...(roleRes.data ?? [])].map((r) => r.type))].sort()
}

/**
 * Lightweight unread count for the header bell badge — row-count only (no
 * data fetched). Notifications previously only surfaced on navigating to
 * the Notifications Center itself (no badge, no polling), so a real event
 * (e.g. a technician assignment, a customer's AMC self-book) could sit
 * unseen indefinitely. Paired with a refetchInterval on the hook side.
 */
export async function countUnreadNotifications(orgId: string, userId: string, role: Enums<"user_role">): Promise<number> {
  const [ownRes, roleRes] = await Promise.all([
    supabase.from("notifications").select("*", { count: "exact", head: true }).eq("org_id", orgId).eq("user_id", userId).eq("is_read", false),
    supabase.from("notifications").select("*", { count: "exact", head: true }).eq("org_id", orgId).eq("role", role).eq("is_read", false),
  ])
  if (ownRes.error) throw ownRes.error
  if (roleRes.error) throw roleRes.error
  return (ownRes.count ?? 0) + (roleRes.count ?? 0)
}

export async function markNotificationRead(id: string, isRead = true): Promise<void> {
  const { error } = await supabase.from("notifications").update({ is_read: isRead }).eq("id", id)
  if (error) throw error
}

export async function markAllNotificationsRead(ids: string[]): Promise<void> {
  if (!ids.length) return
  const { error } = await supabase.from("notifications").update({ is_read: true }).in("id", ids)
  if (error) throw error
}

// ══════════════════════════════════════════════════════════════════════
// ADM-33 Approvals Queue
// ══════════════════════════════════════════════════════════════════════
export type ApprovalRow = Tables<"approvals">
export type ApprovalListItem = ApprovalRow & {
  requester: { full_name: string } | null
  approver: { full_name: string } | null
}

export async function listApprovals(orgId: string, filters: { type?: string; status?: string }): Promise<ApprovalListItem[]> {
  let query = supabase
    .from("approvals")
    .select("*, requester:requested_by(full_name), approver:approver_id(full_name)")
    .eq("org_id", orgId)
  if (filters.type) query = query.eq("type", filters.type as Enums<"approval_type">)
  if (filters.status) query = query.eq("status", filters.status as Enums<"approval_status">)
  // pending first, then most recent
  const { data, error } = await query.order("status", { ascending: true }).order("created_at", { ascending: false })
  if (error) throw error
  return (data ?? []) as unknown as ApprovalListItem[]
}

/**
 * Resolve what an approval's `ref_id` points to, for display context.
 * `type = 'discount'` -> invoices row (BuildSpec §create_sale: a 5-10%
 * discount inserts an approvals row with ref_id = the invoice id).
 * `type = 'po'` -> purchase_orders row (Phase 9, concurrently in flight).
 * `price_override` / `leave` -> nothing produces these yet; handled
 * generically (no dedicated join, ref_id shown raw) rather than building
 * dead-end UI for types nothing writes.
 */
export async function resolveApprovalRef(type: Enums<"approval_type">, refId: string): Promise<string> {
  if (type === "discount") {
    const { data, error } = await supabase.from("invoices").select("id, total, customers(name)").eq("id", refId).maybeSingle()
    if (error || !data) return refId
    const row = data as unknown as { total: number; customers: { name: string } | null }
    return `${row.customers?.name ?? "—"} · ₹${row.total.toLocaleString("en-IN")}`
  }
  if (type === "po") {
    const { data, error } = await supabase.from("purchase_orders").select("id, total, suppliers(name)").eq("id", refId).maybeSingle()
    if (error || !data) return refId
    const row = data as unknown as { total: number; suppliers: { name: string } | null }
    return `${row.suppliers?.name ?? "—"} · ₹${row.total.toLocaleString("en-IN")}`
  }
  return refId
}

/**
 * Approve/reject is a status-only, audit-trail action here: the
 * underlying sale/discount already completed synchronously when it was
 * made (this app has no async pending-approval checkout gate). This just
 * flips `status` and records `approver_id`.
 */
export async function decideApproval(id: string, approverId: string, status: "approved" | "rejected"): Promise<void> {
  const { error } = await supabase.from("approvals").update({ status, approver_id: approverId }).eq("id", id)
  if (error) throw error
}

/**
 * Build Order C2: approving a `type = 'po'` approval must actually release
 * the linked draft purchase order (transition to `sent` + dispatch), which
 * `decideApproval` above does not do — it only flips the approvals row.
 * Rejecting a PO approval still goes through `decideApproval`: the PO simply
 * stays `draft` forever, already the correct terminal state.
 */
export async function approvePurchaseOrder(approvalId: string): Promise<void> {
  const { error } = await supabase.rpc("approve_purchase_order", { p_approval_id: approvalId })
  if (error) throw error
}

// ══════════════════════════════════════════════════════════════════════
// ADM-34 Complaints & Escalations (read-only view over service_tickets)
// ══════════════════════════════════════════════════════════════════════
export type OverdueTicket = {
  id: string
  name_of_complaint: string | null
  priority: Enums<"priority_level">
  status: Enums<"ticket_status">
  sla_due_at: string | null
  created_at: string
  customer_id: string
  customers: { name: string; mobile: string } | null
  product_id: string | null
  products: { name: string } | null
}

export async function listOverdueSlaTickets(orgId: string): Promise<OverdueTicket[]> {
  const nowIso = new Date().toISOString()
  const { data, error } = await supabase
    .from("service_tickets")
    .select("id, name_of_complaint, priority, status, sla_due_at, created_at, customer_id, customers(name, mobile), product_id, products(name)")
    .eq("org_id", orgId)
    .lt("sla_due_at", nowIso)
    .not("status", "in", "(completed,cancelled)")
    .order("sla_due_at", { ascending: true })
  if (error) throw error
  return (data ?? []) as unknown as OverdueTicket[]
}

/** Same customer_id + product_id appearing more than once within a trailing window = repeat complaint. */
export async function listRepeatComplaintTickets(orgId: string, lookbackDays = 90): Promise<OverdueTicket[]> {
  const since = new Date(Date.now() - lookbackDays * 86_400_000).toISOString()
  const { data, error } = await supabase
    .from("service_tickets")
    .select("id, name_of_complaint, priority, status, sla_due_at, created_at, customer_id, customers(name, mobile), product_id, products(name)")
    .eq("org_id", orgId)
    .gte("created_at", since)
    .not("product_id", "is", null)
    .order("created_at", { ascending: false })
  if (error) throw error
  const rows = (data ?? []) as unknown as OverdueTicket[]

  const counts = new Map<string, number>()
  for (const r of rows) {
    const key = `${r.customer_id}:${r.product_id}`
    counts.set(key, (counts.get(key) ?? 0) + 1)
  }
  return rows.filter((r) => (counts.get(`${r.customer_id}:${r.product_id}`) ?? 0) > 1)
}

// ══════════════════════════════════════════════════════════════════════
// ADM-35 Campaign Manager (new `campaigns` table)
// ══════════════════════════════════════════════════════════════════════
export type CampaignStatus = "draft" | "active" | "completed"
export type CampaignRow = Tables<"campaigns">

export async function listCampaigns(orgId: string): Promise<CampaignRow[]> {
  const { data, error } = await supabase
    .from("campaigns")
    .select("*")
    .eq("org_id", orgId)
    .order("created_at", { ascending: false })
  if (error) throw error
  return data ?? []
}

export type CreateCampaignInput = {
  orgId: string
  name: string
  channel: string
  targetSegment: string | null
  startDate: string | null
  endDate: string | null
  message: string | null
}

export async function createCampaign(input: CreateCampaignInput): Promise<CampaignRow> {
  const { data, error } = await supabase
    .from("campaigns")
    .insert({
      org_id: input.orgId,
      name: input.name,
      channel: input.channel,
      target_segment: input.targetSegment,
      start_date: input.startDate,
      end_date: input.endDate,
      message: input.message,
    })
    .select()
    .single()
  if (error) throw error
  return data
}

export async function updateCampaignStatus(id: string, status: CampaignStatus): Promise<CampaignRow> {
  const { data, error } = await supabase.from("campaigns").update({ status }).eq("id", id).select().single()
  if (error) throw error
  return data
}

export async function deleteCampaign(id: string): Promise<void> {
  const { error } = await supabase.from("campaigns").delete().eq("id", id)
  if (error) throw error
}

// ══════════════════════════════════════════════════════════════════════
// ADM-37 Returns / Replacement (new `returns` table)
// ══════════════════════════════════════════════════════════════════════
export type ReturnStatus = "requested" | "approved" | "completed" | "rejected"
export type ReturnRow = Tables<"returns">
export type ReturnListItem = ReturnRow & { invoices: { customers: { name: string } | null } | null }

export async function listReturns(orgId: string): Promise<ReturnListItem[]> {
  const { data, error } = await supabase
    .from("returns")
    .select("*, invoices(customers(name))")
    .eq("org_id", orgId)
    .order("created_at", { ascending: false })
  if (error) throw error
  return (data ?? []) as unknown as ReturnListItem[]
}

export type CreateReturnInput = {
  orgId: string
  invoiceId: string
  itemType: Enums<"item_type">
  itemId: string
  qty: number
  reason: string | null
  isReplacement: boolean
}

export async function createReturn(input: CreateReturnInput): Promise<ReturnRow> {
  const { data, error } = await supabase
    .from("returns")
    .insert({
      org_id: input.orgId,
      invoice_id: input.invoiceId,
      item_type: input.itemType,
      item_id: input.itemId,
      qty: input.qty,
      reason: input.reason,
      is_replacement: input.isReplacement,
    })
    .select()
    .single()
  if (error) throw error
  return data
}

export async function updateReturnStatus(id: string, status: ReturnStatus): Promise<ReturnRow> {
  const { data, error } = await supabase.from("returns").update({ status }).eq("id", id).select().single()
  if (error) throw error
  return data
}

/** Invoice picker for the Returns form — recent invoices with their line items. */
export async function listInvoicesForPicker(orgId: string) {
  const { data, error } = await supabase
    .from("invoices")
    .select("id, type, total, created_at, customers(name), invoice_items(id, item_type, item_id, qty)")
    .eq("org_id", orgId)
    .order("created_at", { ascending: false })
    .limit(100)
  if (error) throw error
  return data ?? []
}

// ══════════════════════════════════════════════════════════════════════
// ADM-38 Audit Log viewer
// ══════════════════════════════════════════════════════════════════════
export type AuditLogRow = Tables<"audit_log"> & { actor: { full_name: string } | null }

export type AuditLogFilters = { tableName?: string; actorId?: string; from?: string; to?: string; search?: string }

export async function listAuditLog(orgId: string, filters: AuditLogFilters): Promise<AuditLogRow[]> {
  let query = supabase.from("audit_log").select("*, actor:actor_id(full_name)").eq("org_id", orgId)
  if (filters.tableName) query = query.eq("table_name", filters.tableName)
  if (filters.actorId) query = query.eq("actor_id", filters.actorId)
  if (filters.from) query = query.gte("created_at", new Date(`${filters.from}T00:00:00`).toISOString())
  if (filters.to) query = query.lte("created_at", new Date(`${filters.to}T23:59:59.999`).toISOString())

  const { data, error } = await query.order("created_at", { ascending: false }).limit(300)
  if (error) throw error
  let rows = (data ?? []) as unknown as AuditLogRow[]

  if (filters.search?.trim()) {
    const term = filters.search.trim().toLowerCase()
    rows = rows.filter(
      (r) =>
        r.action.toLowerCase().includes(term) ||
        r.table_name.toLowerCase().includes(term) ||
        (r.row_id ?? "").toLowerCase().includes(term) ||
        (r.actor?.full_name ?? "").toLowerCase().includes(term)
    )
  }
  return rows
}

export async function listAuditLogTableNames(orgId: string): Promise<string[]> {
  const { data, error } = await supabase.from("audit_log").select("table_name").eq("org_id", orgId).limit(1000)
  if (error) throw error
  return [...new Set((data ?? []).map((r) => r.table_name))].sort()
}
