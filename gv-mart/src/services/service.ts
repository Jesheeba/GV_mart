import { supabase } from "@/lib/supabase"
import type { Enums, Tables } from "@/types/database"

// `settings.sla_hours_very_urgent/urgent/normal` were added in migration
// 20260702110000_service_amc_schema.sql, after src/types/database.ts was
// last regenerated (that file is regenerated centrally by the orchestrating
// session, not edited here — see Phase 6 file-ownership rules). Extending
// the generated row type locally keeps this typed without touching the
// shared file; `getSlaSettings` below supplies safe fallbacks at runtime in
// case the columns aren't live yet.
export type SettingsWithSla = Tables<"settings"> & {
  sla_hours_very_urgent: number
  sla_hours_urgent: number
  sla_hours_normal: number
}

export async function getSlaSettings(orgId: string): Promise<SettingsWithSla> {
  const { data, error } = await supabase.from("settings").select("*").eq("org_id", orgId).single()
  if (error) throw error
  const row = data as unknown as Partial<SettingsWithSla> & Tables<"settings">
  return {
    ...row,
    sla_hours_very_urgent: row.sla_hours_very_urgent ?? 4,
    sla_hours_urgent: row.sla_hours_urgent ?? 24,
    sla_hours_normal: row.sla_hours_normal ?? 48,
  }
}

export type ServiceTicketRow = Tables<"service_tickets">
export type AppointmentRow = Tables<"appointments">
export type ServiceVisitRow = Tables<"service_visits">
export type TicketType = Enums<"ticket_type">
export type PriorityLevel = Enums<"priority_level">
export type TicketStatus = Enums<"ticket_status">
export type AppointmentMode = Enums<"appointment_mode">
export type AppointmentStatus = Enums<"appointment_status">

export type TicketListItem = ServiceTicketRow & {
  customers: { name: string; mobile: string } | null
  products: { name: string } | null
  brands: { name: string } | null
  models: { name: string } | null
  addresses: { area: string | null } | null
  appointments: {
    id: string
    scheduled_at: string | null
    mode: AppointmentMode
    status: AppointmentStatus
    technician_id: string | null
    technicians: { id: string; profiles: { full_name: string } | null } | null
  }[]
}

export type TicketFiltersInput = {
  status?: string
  priority?: string
  type?: string
  technicianId?: string
  date?: string
  area?: string
  search?: string
}

const TICKET_SELECT = `
  *,
  customers(name, mobile),
  products(name),
  brands(name),
  models(name),
  addresses(area),
  appointments(id, scheduled_at, mode, status, technician_id, technicians(id, profiles(full_name)))
`

export async function listTickets(orgId: string, filters: TicketFiltersInput): Promise<TicketListItem[]> {
  let query = supabase.from("service_tickets").select(TICKET_SELECT).eq("org_id", orgId).order("created_at", { ascending: false })

  if (filters.status) query = query.eq("status", filters.status as TicketStatus)
  if (filters.priority) query = query.eq("priority", filters.priority as PriorityLevel)
  if (filters.type) query = query.eq("type", filters.type as TicketType)
  if (filters.search?.trim()) {
    const term = filters.search.trim().replace(/[%,]/g, "")
    query = query.ilike("name_of_complaint", `%${term}%`)
  }

  const { data, error } = await query.limit(200)
  if (error) throw error
  let rows = (data ?? []) as unknown as TicketListItem[]

  // Filters that reach through the joined appointment/address rows can't be
  // expressed as a single PostgREST `.eq()` on the base table — applied
  // client-side after the fetch instead (dataset is org-scoped + capped).
  if (filters.technicianId) {
    rows = rows.filter((r) => r.appointments.some((a) => a.technician_id === filters.technicianId))
  }
  if (filters.area) {
    rows = rows.filter((r) => r.addresses?.area === filters.area)
  }
  if (filters.date) {
    rows = rows.filter((r) => r.appointments.some((a) => a.scheduled_at?.slice(0, 10) === filters.date))
  }

  return rows
}

export async function getTicket(id: string) {
  const { data, error } = await supabase
    .from("service_tickets")
    .select(
      `${TICKET_SELECT}, service_visits(*, service_spares_used(*, spares(name)), ro_checklists(*), ratings(*))`
    )
    .eq("id", id)
    .single()
  if (error) throw error
  return data
}

/** Sets/changes a ticket's service address after creation (e.g. it was created with none). */
export async function updateTicketAddress(ticketId: string, addressId: string | null) {
  const { data, error } = await supabase.from("service_tickets").update({ address_id: addressId }).eq("id", ticketId).select().single()
  if (error) throw error
  return data
}

/** Repeat-complaint flag (ADM-09): >1 ticket for the same customer within the lookback window. */
export async function customersWithRepeatComplaints(orgId: string, lookbackDays = 90): Promise<Set<string>> {
  const since = new Date(Date.now() - lookbackDays * 86_400_000).toISOString()
  const { data, error } = await supabase
    .from("service_tickets")
    .select("customer_id")
    .eq("org_id", orgId)
    .gte("created_at", since)
  if (error) throw error
  const counts = new Map<string, number>()
  for (const row of data ?? []) counts.set(row.customer_id, (counts.get(row.customer_id) ?? 0) + 1)
  return new Set([...counts.entries()].filter(([, count]) => count > 1).map(([id]) => id))
}

export async function detectTicketType(orgId: string, customerId: string, productId: string | null) {
  const { data, error } = await supabase.rpc("_detect_ticket_type", {
    p_org_id: orgId,
    p_customer_id: customerId,
    p_product_id: productId,
  })
  if (error) throw error
  return data as {
    type: TicketType
    reason_key: string
    amc_contract_id?: string
    amc_expiry_date?: string
    amc_start_date?: string
    warranty_id?: string
    warranty_expiry_date?: string
    warranty_start_date?: string
  }
}

export type CreateComplaintInput = {
  orgId: string
  customerId: string
  addressId: string | null
  productId: string | null
  brandId: string | null
  modelId: string | null
  nameOfComplaint: string
  natureOfComplaint: string | null
  priority: PriorityLevel
  channel: Enums<"ticket_channel">
  appointmentMode: AppointmentMode | null
  scheduledAt: string | null
  autoAssign: boolean
}

export async function createComplaintTicket(input: CreateComplaintInput) {
  const { data, error } = await supabase.rpc("create_complaint_ticket", {
    p_org_id: input.orgId,
    p_customer_id: input.customerId,
    p_address_id: input.addressId,
    p_product_id: input.productId,
    p_brand_id: input.brandId,
    p_model_id: input.modelId,
    p_name_of_complaint: input.nameOfComplaint,
    p_nature_of_complaint: input.natureOfComplaint,
    p_priority: input.priority,
    p_channel: input.channel,
    p_appointment_mode: input.appointmentMode,
    p_scheduled_at: input.scheduledAt,
    p_auto_assign: input.autoAssign,
  })
  if (error) throw error
  return data as { ticket_id: string; appointment_id: string | null; detected_type: unknown; assign_result: unknown }
}

export async function autoAssignTicket(ticketId: string) {
  const { data, error } = await supabase.rpc("auto_assign_ticket", { p_ticket_id: ticketId })
  if (error) throw error
  return data as { assigned: boolean; reason_key?: string; technician_id?: string; appointment_id?: string }
}

export async function assignTicketTechnician(appointmentId: string, technicianId: string, force = false) {
  const { data, error } = await supabase.rpc("assign_ticket_technician", {
    p_appointment_id: appointmentId,
    p_technician_id: technicianId,
    p_force: force,
  })
  if (error) throw error
  return data as { assigned: boolean; reason_key?: string; conflict_appointment_id?: string; technician_id?: string }
}

export async function completeAppointment(appointmentId: string) {
  const { error } = await supabase.rpc("complete_appointment", { p_appointment_id: appointmentId })
  if (error) throw error
}

export async function updateAppointmentSchedule(id: string, patch: { scheduled_at?: string | null; mode?: AppointmentMode }) {
  const { data, error } = await supabase.from("appointments").update(patch).eq("id", id).select().single()
  if (error) throw error
  return data
}

export async function unassignAppointment(id: string) {
  const { data, error } = await supabase.from("appointments").update({ technician_id: null }).eq("id", id).select().single()
  if (error) throw error
  return data
}

// ── Technicians (for filters / assignment panel) ─────────────────────────
export type TechnicianOption = { id: string; full_name: string; is_on_duty: boolean }

export async function listTechnicians(orgId: string): Promise<TechnicianOption[]> {
  const { data, error } = await supabase
    .from("technicians")
    .select("id, is_on_duty, profiles(full_name)")
    .eq("org_id", orgId)
  if (error) throw error
  return (data ?? []).map((t) => ({ id: t.id, is_on_duty: t.is_on_duty, full_name: t.profiles?.full_name ?? "—" }))
}

// ── Owned equipment (ADM-10 "Equipment auto-shown if owned") ─────────────
// Sourced from whatever the customer has bought/registered: invoice_items
// (product sales), warranties, and amc_contracts all reference a product —
// unioned and de-duplicated by product_id so the New Complaint stepper can
// offer "you already have these" before falling back to a fresh
// product→brand→model pick.
export type OwnedEquipment = {
  productId: string
  productName: string
  brandId: string | null
  brandName: string | null
  modelId: string | null
  modelName: string | null
}

export async function listOwnedEquipment(orgId: string, customerId: string): Promise<OwnedEquipment[]> {
  const [invoicesRes, warrantiesRes, amcRes] = await Promise.all([
    supabase
      .from("invoice_items")
      .select("item_id, invoices!inner(customer_id, org_id, type)")
      .eq("invoices.customer_id", customerId)
      .eq("invoices.org_id", orgId)
      .eq("invoices.type", "product")
      .eq("item_type", "product"),
    supabase.from("warranties").select("product_id").eq("org_id", orgId).eq("customer_id", customerId),
    supabase.from("amc_contracts").select("product_id").eq("org_id", orgId).eq("customer_id", customerId),
  ])
  if (invoicesRes.error) throw invoicesRes.error
  if (warrantiesRes.error) throw warrantiesRes.error
  if (amcRes.error) throw amcRes.error

  const productIds = new Set<string>([
    ...(invoicesRes.data ?? []).map((r) => r.item_id),
    ...(warrantiesRes.data ?? []).map((r) => r.product_id),
    ...(amcRes.data ?? []).map((r) => r.product_id),
  ])
  if (productIds.size === 0) return []

  const { data: products, error } = await supabase
    .from("products")
    .select("id, name, brand_id, model_id, brands(name), models(name)")
    .in("id", [...productIds])
  if (error) throw error

  return (products ?? []).map((p) => ({
    productId: p.id,
    productName: p.name,
    brandId: p.brand_id,
    brandName: p.brands?.name ?? null,
    modelId: p.model_id,
    modelName: p.models?.name ?? null,
  }))
}

export async function listCustomerAddresses(customerId: string) {
  const { data, error } = await supabase
    .from("addresses")
    .select("id, area, door_no, address_type, is_primary")
    .eq("customer_id", customerId)
    .order("is_primary", { ascending: false })
  if (error) throw error
  return data ?? []
}

// ── Appointments for calendar/timeline (ADM-11) ───────────────────────────
export type AppointmentListItem = AppointmentRow & {
  service_tickets: {
    id: string
    name_of_complaint: string | null
    priority: PriorityLevel
    type: TicketType | null
    customer_id: string
    customers: { name: string } | null
  } | null
  technicians: { id: string; profiles: { full_name: string } | null } | null
}

export async function listAppointments(orgId: string, fromDate: string, toDate: string): Promise<AppointmentListItem[]> {
  // mode="always" appointments have scheduled_at = null — `NULL >= x` and
  // `NULL <= x` both evaluate to NULL in Postgres, so a plain .gte/.lte range
  // filter silently excludes every "always" appointment from the board. Also
  // match rows with mode="always" regardless of scheduled_at.
  const { data, error } = await supabase
    .from("appointments")
    .select(
      "*, service_tickets(id, name_of_complaint, priority, type, customer_id, customers(name)), technicians(id, profiles(full_name))"
    )
    .eq("org_id", orgId)
    .or(`and(scheduled_at.gte.${fromDate},scheduled_at.lte.${toDate}),mode.eq.always`)
    .order("scheduled_at")
  if (error) throw error
  return (data ?? []) as unknown as AppointmentListItem[]
}
