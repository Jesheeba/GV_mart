import { supabase } from "@/lib/supabase"
import type { Enums, Tables } from "@/types/database"

/**
 * Customer-app-facing service layer (Phase 8). Deliberately separate from
 * services/customers.ts (the admin/staff-managing-customers file) even
 * though several queries touch the same tables — keeps staff-facing and
 * self-service code paths from being confused, per the build brief.
 */

export type AddressRow = Tables<"addresses">
export type CustomerRow = Tables<"customers">
export type ServiceTicketRow = Tables<"service_tickets">
export type AppointmentRow = Tables<"appointments">
export type AmcContractRow = Tables<"amc_contracts">
export type WarrantyRow = Tables<"warranties">
// price_per_year post-dates the last database.ts regen — see the AMC
// section below for why this is widened locally instead of editing that file.
export type AmcPlanRow = Tables<"amc_plans"> & { price_per_year: number | null }
export type ProductRow = Tables<"products">
export type LeadRow = Tables<"leads">
export type VideoLibraryRow = Tables<"video_library">
export type ReferralPointRow = Tables<"referral_points">
export type TechnicianLocationRow = Tables<"technician_locations">
export type InvoiceRow = Tables<"invoices">
export type SettingsRow = Tables<"settings">

// ── Profile / customer record ─────────────────────────────────────────────

export async function getMyCustomerRecord(customerId: string) {
  const { data, error } = await supabase
    .from("customers")
    .select("*, addresses(*), customer_members(*)")
    .eq("id", customerId)
    .order("is_primary", { referencedTable: "addresses", ascending: false })
    .order("is_primary", { referencedTable: "customer_members", ascending: false })
    .single()
  if (error) throw error
  return data
}

export async function updateMyProfession(customerId: string, profession: string) {
  const { error } = await supabase.from("customers").update({ profession }).eq("id", customerId)
  if (error) throw error
}

// ── Addresses (CUST-01 fill/confirm, CUST-08 multiple addresses) ─────────

export async function listMyAddresses(customerId: string) {
  const { data, error } = await supabase
    .from("addresses")
    .select("*")
    .eq("customer_id", customerId)
    .order("is_primary", { ascending: false })
    .order("created_at", { ascending: false })
  if (error) throw error
  return data
}

export type AddressInput = {
  doorNo: string
  flatNo?: string
  streetCross?: string
  area: string
  pincode: string
  landmark?: string
  district?: string
  state?: string
  // Root-cause fix (technician map location bug) — see AddressForm.tsx's
  // map-picker integration and customerAddressSchema's doc comment.
  lat?: number
  lng?: number
  addressType: Enums<"address_type">
  ownership: Enums<"ownership_type">
}

function addressRow(input: AddressInput) {
  return {
    door_no: input.doorNo,
    flat_no: input.flatNo || null,
    street_cross: input.streetCross || null,
    area: input.area,
    pincode: input.pincode,
    landmark: input.landmark || null,
    district: input.district || null,
    state: input.state || null,
    // Root-cause fix — previously omitted entirely, so every customer-
    // self-added address had lat/lng permanently null (see AddressForm.tsx).
    // Left `undefined` (not `?? null`) when not provided — JSON-serializes
    // away entirely, so `updateMyAddress` never overwrites an already-good
    // pin just because a caller edited an unrelated text field without
    // touching the map; `addMyAddress` correctly gets a null column default
    // in that same case.
    lat: input.lat,
    lng: input.lng,
    address_type: input.addressType,
    ownership: input.ownership,
  }
}

export async function addMyAddress(orgId: string, customerId: string, input: AddressInput, makePrimary: boolean) {
  if (makePrimary) {
    await supabase.from("addresses").update({ is_primary: false }).eq("customer_id", customerId).eq("is_primary", true)
  }
  const { data, error } = await supabase
    .from("addresses")
    .insert({ org_id: orgId, customer_id: customerId, ...addressRow(input), is_primary: makePrimary })
    .select()
    .single()
  if (error) throw error
  return data
}

export async function updateMyAddress(addressId: string, input: AddressInput) {
  const { data, error } = await supabase.from("addresses").update(addressRow(input)).eq("id", addressId).select().single()
  if (error) throw error
  return data
}

export async function setMyPrimaryAddress(customerId: string, addressId: string) {
  await supabase.from("addresses").update({ is_primary: false }).eq("customer_id", customerId).eq("is_primary", true)
  const { error } = await supabase.from("addresses").update({ is_primary: true }).eq("id", addressId)
  if (error) throw error
}

// Task 3 (2026-07-30): routed through a guarded RPC (rather than a raw
// `.delete()`) so the server rejects deleting an address that's linked to
// an active (not completed/cancelled) booking, not just relying on RLS for
// ownership. See 20260730110000_address_everywhere.sql.
export async function deleteMyAddress(addressId: string) {
  const { error } = await supabase.rpc("delete_my_address", { p_address_id: addressId })
  if (error) throw error
}

// ── Family members (CUST-08, max 5 — same trigger as admin side) ─────────

export async function addMyMember(orgId: string, customerId: string, member: { name: string; mobile: string }) {
  const { data, error } = await supabase
    .from("customer_members")
    .insert({ org_id: orgId, customer_id: customerId, name: member.name, mobile: member.mobile, is_primary: false })
    .select()
    .single()
  if (error) throw error
  return data
}

export async function removeMyMember(memberId: string) {
  const { error } = await supabase.from("customer_members").delete().eq("id", memberId)
  if (error) throw error
}

// ── My Products (CUST-06): warranties + AMC contracts, joined to product/brand/model ──

export async function listMyWarranties(customerId: string) {
  const { data, error } = await supabase
    .from("warranties")
    .select("*, products(name, category, brands(name), models(name))")
    .eq("customer_id", customerId)
    .order("expiry_date", { ascending: false })
  if (error) throw error
  return data
}

export async function listMyAmcContracts(customerId: string) {
  const { data, error } = await supabase
    .from("amc_contracts")
    .select("*, products(name, category, brands(name), models(name)), amc_plans(name, years, price, visits_per_year)")
    .eq("customer_id", customerId)
    .order("expiry_date", { ascending: false })
  if (error) throw error
  return data
}

// Row shapes for the two queries above, used by useOwnedProductsWithStatus
// (useCustomerApp.ts) — the shared "one card per owned product" source for
// both CustomerProductsPage and CustomerAmcPage.
export type MyWarrantyRow = Awaited<ReturnType<typeof listMyWarranties>>[number]
export type MyAmcContractRow = Awaited<ReturnType<typeof listMyAmcContracts>>[number]

export async function listOwnedProducts(orgId: string) {
  const { data, error } = await supabase
    .from("products")
    .select("id, name, category, brand_id, model_id, price, warranty_months, brands(name), models(name)")
    .eq("org_id", orgId)
    // Task 6 (2026-07-30): a product an admin disabled shouldn't be pickable
    // for a NEW booking/enquiry — see 20260730170000_product_spare_mapping_
    // and_active_flags.sql. Already-owned products stay visible elsewhere
    // (useMyOwnedProducts, a different query) regardless of this flag.
    .eq("is_active", true)
    .order("name")
  if (error) throw error
  return data
}

export async function registerProductViaQr(orgId: string, productId: string, serialNo: string, purchaseDate: string | null) {
  const { data, error } = await supabase.rpc("register_product_via_qr", {
    p_org_id: orgId,
    p_product_id: productId,
    p_serial_no: serialNo,
    p_purchase_date: purchaseDate,
  })
  if (error) throw error
  return data
}

// ── Service Booking (CUST-02) ─────────────────────────────────────────────
//
// Restored to unavailability-window geometry booking (2026-08-04 change
// request — the admin-configured appointment-slot system introduced
// 2026-07-31 stays live for the admin flow only). See
// 20260804200000_restore_customer_unavailability_booking.sql.

export type AppointmentSlotRow = Tables<"appointment_slots">

export async function listAppointmentSlots(orgId: string, activeOnly = true) {
  let query = supabase.from("appointment_slots").select("*").eq("org_id", orgId).order("sort_order")
  if (activeOnly) query = query.eq("is_active", true)
  const { data, error } = await query
  if (error) throw error
  return data
}

export type UnavailableWindow = { start: string; end: string }

export type ServiceBookingRpcInput = {
  orgId: string
  addressId: string
  productId: string | null
  brandId: string | null
  modelId: string | null
  nameOfComplaint: string
  natureOfComplaint?: string
  /** Issue-based spare suggestions (2026-08-06) — the complaint_types row the
   * "Name of complaint" Autocomplete resolved, if the customer picked a
   * suggestion rather than free-typing. Feeds the on-site technician's
   * "Suggested for this issue" spare list; null for free-typed complaints. */
  complaintTypeId?: string | null
  priority: Enums<"priority_level">
  scheduledDate: string
  unavailableWindows: UnavailableWindow[]
}

export async function bookServiceTicket(input: ServiceBookingRpcInput) {
  const { data, error } = await supabase.rpc("book_service_ticket", {
    p_org_id: input.orgId,
    p_address_id: input.addressId,
    p_product_id: input.productId,
    p_brand_id: input.brandId,
    p_model_id: input.modelId,
    p_name_of_complaint: input.nameOfComplaint,
    p_nature_of_complaint: input.natureOfComplaint ?? "",
    p_priority: input.priority,
    p_scheduled_date: input.scheduledDate,
    p_unavailable_windows: input.unavailableWindows,
    p_complaint_type_id: input.complaintTypeId ?? null,
  })
  if (error) throw error
  return data as {
    ticket_id: string
    appointment_id: string | null
    detected_type: { type: string; reason_key: string }
    lead_id: string | null
    assign_result: { assigned: boolean; reason_key?: string } | null
    scheduled_at: string | null
    available_from: string | null
    available_to: string | null
    is_narrow_window: boolean
    next_day_priority: boolean
  }
}

/** Resolve-on-view (Task 4) — best-effort, fire-and-forget from the
 * customer dashboard: flags any of the customer's bookings whose day ended
 * with no technician ever assigned, and notifies admins. Never blocks or
 * surfaces an error to the UI — a missed sweep just runs again next view. */
export async function resolveStaleBookings(orgId: string) {
  const { error } = await supabase.rpc("resolve_stale_bookings", { p_org_id: orgId })
  if (error) throw error
}

// ── Exemption windows (B4, Build Order Step 4) — read-only here; admin CRUD
// lives in services/customers.ts. Used to render the customer's own standing
// exemption windows as red, pre-populated "already blocked" entries in the
// booking wizard's unavailable-windows picker. ───────────────────────────
export type CustomerExemptionWindowRow = Tables<"customer_exemption_windows">

export async function listMyExemptionWindows(customerId: string): Promise<CustomerExemptionWindowRow[]> {
  const { data, error } = await supabase
    .from("customer_exemption_windows")
    .select("*")
    .eq("customer_id", customerId)
    .eq("is_active", true)
    .order("start_time")
  if (error) throw error
  return data ?? []
}

// ── Bookings / History (CUST-07, Task 7 2026-07-30 server-side filters) ──

export const TICKET_FILTER_PAGE_SIZE = 10

export type TicketFilters = {
  fromDate?: string
  toDate?: string
  productCategory?: string
  status?: Enums<"ticket_status">
  amcStatus?: Enums<"amc_status">
  serviceType?: Enums<"ticket_type">
  technicianId?: string
  bookingNumber?: string
  search?: string
}

export type FilteredTicketItem = {
  id: string
  status: Enums<"ticket_status">
  type: Enums<"ticket_type"> | null
  name_of_complaint: string | null
  nature_of_complaint: string | null
  created_at: string
  product: { id: string; name: string; category: Enums<"brand_category"> } | null
  appointment: {
    id: string
    scheduled_at: string | null
    mode: Enums<"appointment_mode">
    status: Enums<"appointment_status">
    // Customer Dashboard Booking Audit (2026-07-31) Tasks 3/5 — live slot
    // link (name/times reflect the CURRENT slot config, not a frozen
    // snapshot) and the Task 4 stale-booking follow-up flag.
    follow_up_flagged_at: string | null
    slot_name: string | null
    slot_start_time: string | null
    slot_end_time: string | null
    // Restored 2026-08-04 for geometry-booked (no slot_id) customer bookings.
    available_from: string | null
    available_to: string | null
    is_narrow_window: boolean
    technician: { id: string; full_name: string } | null
  } | null
  amc_status: Enums<"amc_status"> | null
}

export async function listMyTicketsFiltered(filters: TicketFilters, page: number) {
  const { data, error } = await supabase.rpc("list_my_tickets_filtered", {
    p_from_date: filters.fromDate || null,
    p_to_date: filters.toDate || null,
    p_product_category: filters.productCategory || null,
    p_status: filters.status || null,
    p_amc_status: filters.amcStatus || null,
    p_service_type: filters.serviceType || null,
    p_technician_id: filters.technicianId || null,
    p_booking_number: filters.bookingNumber || null,
    p_search: filters.search || null,
    p_limit: TICKET_FILTER_PAGE_SIZE,
    p_offset: page * TICKET_FILTER_PAGE_SIZE,
  })
  if (error) throw error
  return data as unknown as { items: FilteredTicketItem[]; total_count: number }
}

export async function listMyTicketTechnicians() {
  const { data, error } = await supabase.rpc("list_my_ticket_technicians")
  if (error) throw error
  return (data ?? []) as { technician_id: string; full_name: string }[]
}

export async function getTicketDetail(ticketId: string) {
  const { data, error } = await supabase
    .from("service_tickets")
    .select(
      // GV.md §2 OTP completion confirmation — service_visit_otps carries
      // the customer-facing code (RLS: a customer may only read the row for
      // their own ticket's visit, see 20260725110000_otp_completion_
      // confirmation.sql). Explicit column list on purpose, excluding the
      // audit-only bypass columns the customer screen has no use for.
      // Customer Dashboard Booking Audit (2026-07-31) Task 3/5: the slot
      // join is live (name/times), not frozen at booking time — an admin
      // retiming a slot shows up here automatically.
      "*, products(name), brands(name), models(name), addresses(*), invoices(*), appointments(*, technicians(id, profile_id, skills, profiles(full_name, phone)), appointment_slots(name, start_time, end_time)), service_visits(*, ratings(*), ro_checklists(*), service_visit_otps(code, generated_at, expires_at, verified_at))"
    )
    .eq("id", ticketId)
    .single()
  if (error) throw error
  return data
}

export type ActiveAssignedTicket = { id: string; status: Enums<"ticket_status"> }

// Technician-assignment banner (Customer Dashboard) — the ticket(s) that
// currently have a technician assigned and aren't finished yet, so the
// banner has something to point at across a page reload (a realtime event
// alone would lose the banner on refresh).
export async function listActiveAssignedTickets() {
  const { data, error } = await supabase
    .from("service_tickets")
    .select("id, status, updated_at, appointments(technician_id)")
    .in("status", ["assigned", "in_progress"])
    .order("updated_at", { ascending: false })
  if (error) throw error
  return (data ?? [])
    .filter((t) => t.appointments?.some((a) => a.technician_id))
    .map((t) => ({ id: t.id, status: t.status }) as ActiveAssignedTicket)
}

// ── AMC (CUST-03) ─────────────────────────────────────────────────────────
// `price_per_year` (migration 20260716130000_amc_price_per_year_and_covered_
// spares.sql) post-dates the last database.ts regen — widened locally the
// same way as `AmcPlanRow` in services/masters.ts rather than editing that
// shared generated file.

export async function listAmcPlans(orgId: string): Promise<AmcPlanRow[]> {
  const { data, error } = await supabase.from("amc_plans").select("*").eq("org_id", orgId).order("years")
  if (error) throw error
  return (data ?? []) as unknown as AmcPlanRow[]
}

export type RenewAmcInput = {
  orgId: string
  productId: string
  planId: string
  paymentReference: string
  /** Fix 1: choose a duration other than the plan's own default `years`.
   * Optional — renew_amc_plan falls back to the plan's own years when
   * omitted, for backward compatibility. */
  years?: number
  /**
   * Build Order A2 — "a new AMC signup can enter the selling technician's
   * name as a referral". Free text on purpose (the customer only knows the
   * technician's name, not their id) — renew_amc_plan resolves it
   * server-side to a real technicians.id -> leads.owner_id so it feeds the
   * existing finder-credit incentive plumbing, never stored as a raw column
   * nothing reads. Silently ignored (no attribution, sale still succeeds)
   * if the name doesn't match exactly one active technician in the org.
   */
  referredByTechnicianName?: string
  /** Task 3 (2026-07-30) — customer-picked service address; falls back to
   * their primary address server-side when omitted. */
  addressId?: string
}

export async function renewAmcPlan(input: RenewAmcInput) {
  const { data, error } = await supabase.rpc("renew_amc_plan", {
    p_org_id: input.orgId,
    p_product_id: input.productId,
    p_plan_id: input.planId,
    p_payment_reference: input.paymentReference,
    p_years: input.years ?? null,
    p_referred_by_technician_name: input.referredByTechnicianName?.trim() || null,
    p_address_id: input.addressId ?? null,
  })
  if (error) throw error
  return data as { contract_id: string; ticket_ids: string[]; expiry_date: string }
}

export type AmcHistoryVisit = {
  id: string
  timer_start: string | null
  timer_end: string | null
  notes: string | null
  service_spares_used: { id: string; qty: number; spares: { name: string } | null }[]
}

export type AmcHistoryTicket = {
  id: string
  name_of_complaint: string | null
  type: Enums<"ticket_type">
  status: Enums<"ticket_status">
  created_at: string
  service_visits: AmcHistoryVisit[]
}

/**
 * Per-product AMC + warranty service history for the customer-app AMC detail
 * page (CustomerAmcProductDetailPage) — completed services only, with parts
 * used per visit. Same join shape as the technician-facing
 * services/technician.ts:getCustomerHistory, but that function is
 * technician-scoped (RLS relies on is_technician_customer, and it isn't
 * product/type-filtered the same way) so this is a separate customer-scoped
 * query rather than a shared one. Reads service_spares_used, which only
 * became visible to the customer role via
 * 20260729093000_amc_history_customer_rls.sql — see that migration's header
 * for the RLS recursion check.
 */
export async function listMyAmcContractHistory(customerId: string, productId: string): Promise<AmcHistoryTicket[]> {
  const { data, error } = await supabase
    .from("service_tickets")
    .select(
      "id, name_of_complaint, type, status, created_at, service_visits(id, timer_start, timer_end, notes, service_spares_used(id, qty, spares(name)))"
    )
    .eq("customer_id", customerId)
    .eq("product_id", productId)
    .in("type", ["amc", "warranty"])
    .eq("status", "completed")
    .order("created_at", { ascending: false })
  if (error) throw error
  return (data ?? []) as unknown as AmcHistoryTicket[]
}

// ── Product / Spare Enquiry (CUST-04 / CUST-05) ───────────────────────────

export async function listVideoLibrary(orgId: string) {
  const { data, error } = await supabase.from("video_library").select("*").eq("org_id", orgId)
  if (error) throw error
  return data
}

/**
 * Task 6 (2026-07-30) — every spare mapped to the selected product, for the
 * Spare Enquiry picker. `spares!inner(...)` so the `is_active` filter on the
 * joined table actually applies (a left join can't be filtered this way in
 * PostgREST) — an admin-disabled spare drops out of the picker immediately,
 * no separate configuration needed.
 */
export type ProductSpareOption = { id: string; name: string; sku: string | null }

export async function listSparesForProduct(productId: string): Promise<ProductSpareOption[]> {
  const { data, error } = await supabase
    .from("product_spares")
    .select("spares!inner(id, name, sku, is_active)")
    .eq("product_id", productId)
    .eq("spares.is_active", true)
  if (error) throw error
  return (data ?? []).map((row) => row.spares).filter((s): s is NonNullable<typeof s> => !!s)
}

export type EnquiryItemInput = { productId?: string; spareId?: string; qty?: number }

export type EnquiryRpcInput = {
  orgId: string
  kind: "product" | "spare"
  enquiryType: Enums<"enquiry_type"> | null
  description: string
  photoUrl?: string
  /** Task 3 (2026-07-30) — optional selected address for the enquiry. */
  addressId?: string
  /** Product Enquiry rebuild (2026-08-04) Phase 4 — structured per-product quote request. */
  productId?: string
  qty?: number
  /** Spare Enquiry -> Quotation autofill (2026-08-04) — the selected spare, if any. */
  spareId?: string
  /**
   * Spare Enquiry multi-product line items (2026-08-05) — one or more
   * product/spare requests in a single enquiry (CustomerSpareEnquiryPage's
   * "+ Add another product" rows). Falls back to the singular productId/
   * spareId/qty above when omitted, so QuotationCta.tsx and
   * VideoLibraryTabContent.tsx (single-item callers) need no changes.
   */
  items?: EnquiryItemInput[]
}

export async function submitCustomerEnquiry(input: EnquiryRpcInput) {
  const items =
    input.items && input.items.length > 0
      ? input.items
      : input.productId || input.spareId
        ? [{ productId: input.productId, spareId: input.spareId, qty: input.qty }]
        : []
  const { data, error } = await supabase.rpc("submit_customer_enquiry", {
    p_org_id: input.orgId,
    p_kind: input.kind,
    p_enquiry_type: input.enquiryType,
    p_description: input.description,
    p_photo_url: input.photoUrl ?? "",
    p_address_id: input.addressId ?? null,
    p_items: items.map((i) => ({ product_id: i.productId ?? null, spare_id: i.spareId ?? null, qty: i.qty ?? 1 })),
  })
  if (error) throw error
  return data as string
}

// ── Product Enquiry rebuild (2026-08-04) Phase 4 — Request Callback ──────
export type CallbackRpcInput = {
  orgId: string
  scheduledDate: string
  slotId: string
  productId?: string
  note?: string
}

export async function requestCallback(input: CallbackRpcInput) {
  const { data, error } = await supabase.rpc("request_callback", {
    p_org_id: input.orgId,
    p_scheduled_date: input.scheduledDate,
    p_slot_id: input.slotId,
    p_product_id: input.productId ?? null,
    p_note: input.note ?? null,
  })
  if (error) throw error
  return data
}

// ── Referral wallet (CUST-08) ─────────────────────────────────────────────

export async function listMyReferralPoints(customerId: string) {
  const { data, error } = await supabase
    .from("referral_points")
    .select("*")
    .eq("customer_id", customerId)
    .order("created_at", { ascending: false })
  if (error) throw error
  return data
}

// ── Settings (read-only: amc window, gst rate, etc.) ──────────────────────

export async function getSettings(orgId: string) {
  const { data, error } = await supabase.from("settings").select("*").eq("org_id", orgId).maybeSingle()
  if (error) throw error
  return data
}

// ── Live tracking (CUST-07 <LiveTracking>) ────────────────────────────────

export async function getLatestTechnicianLocation(technicianId: string) {
  const { data, error } = await supabase
    .from("technician_locations")
    .select("*")
    .eq("technician_id", technicianId)
    .order("recorded_at", { ascending: false })
    .limit(1)
    .maybeSingle()
  if (error) throw error
  return data
}

// ── Premium live tracking — rating submission + technician public stats ──

export async function submitCustomerRating(input: { orgId: string; visitId: string; stars: number; review: string | null }) {
  const { data, error } = await supabase.rpc("submit_customer_rating", {
    p_org_id: input.orgId,
    p_visit_id: input.visitId,
    p_stars: input.stars,
    p_review: input.review,
  })
  if (error) throw error
  return data
}

export type TechnicianPublicStats = { avg_rating: number | null; completed_count: number }

export async function getTechnicianPublicStats(technicianId: string): Promise<TechnicianPublicStats> {
  const { data, error } = await supabase.rpc("get_technician_public_stats", { p_technician_id: technicianId })
  if (error) throw error
  return data as unknown as TechnicianPublicStats
}
