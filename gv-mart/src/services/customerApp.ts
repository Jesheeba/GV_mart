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

export async function deleteMyAddress(addressId: string) {
  const { error } = await supabase.from("addresses").delete().eq("id", addressId)
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

export async function listOwnedProducts(orgId: string) {
  const { data, error } = await supabase
    .from("products")
    .select("id, name, category, brand_id, model_id, price, warranty_months, brands(name), models(name)")
    .eq("org_id", orgId)
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

export type UnavailableWindowInput = { start: string; end: string }

export type ServiceBookingRpcInput = {
  orgId: string
  addressId: string
  productId: string | null
  brandId: string | null
  modelId: string | null
  nameOfComplaint: string
  natureOfComplaint?: string
  priority: Enums<"priority_level">
  appointmentMode: Enums<"appointment_mode">
  scheduledAt: string | null
  // Customer availability time window (Phase 1.5 of the technician
  // assignment rework) — only meaningful when appointmentMode is
  // 'datetime'; null/undefined otherwise. `p_available_from`/`p_available_to`
  // post-date the last database.ts regen (see book_service_ticket's new
  // trailing params in 20260721091000_appointment_availability_window.sql),
  // so they're intentionally typed here rather than sourced from the
  // generated RPC Args type.
  availableFrom?: string | null
  availableTo?: string | null
  // B1 (Build Order Step 4): the windows the customer marked as NOT
  // available on their chosen date. Undefined/null = legacy caller (server
  // falls back to availableFrom/availableTo as-is); an array (possibly
  // empty — "Any time") engages the server's date-only + unavailable-
  // windows computation, including the B2 narrow-window guard and B3
  // next-day-priority bump. See 20260723101000_step4_booking_rpcs.sql.
  unavailableWindows?: UnavailableWindowInput[] | null
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
    p_appointment_mode: input.appointmentMode,
    p_scheduled_at: input.scheduledAt,
    p_available_from: input.availableFrom ?? null,
    p_available_to: input.availableTo ?? null,
    p_unavailable_windows: input.unavailableWindows ?? null,
  })
  if (error) throw error
  return data as {
    ticket_id: string
    appointment_id: string | null
    detected_type: { type: string; reason_key: string }
    lead_id: string | null
    assign_result: { assigned: boolean; reason_key?: string } | null
    // B3 feedback (Build Order Step 4) — only meaningful when the booking
    // went through the new date+unavailable-windows path (appointment_id
    // not null and mode was 'datetime' with p_unavailable_windows sent).
    scheduled_at: string | null
    available_from: string | null
    available_to: string | null
    is_narrow_window: boolean | null
    next_day_priority: boolean | null
  }
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

// ── Bookings / History (CUST-07) ──────────────────────────────────────────

export async function listMyTickets(customerId: string) {
  const { data, error } = await supabase
    .from("service_tickets")
    .select(
      "*, products(name), brands(name), models(name), appointments(id, technician_id, scheduled_at, mode, status, technicians(id, profile_id, profiles(full_name, phone))), ratings:service_visits(id, ro_checklists(*), ratings(*))"
    )
    .eq("customer_id", customerId)
    .order("created_at", { ascending: false })
  if (error) throw error
  return data
}

export async function getTicketDetail(ticketId: string) {
  const { data, error } = await supabase
    .from("service_tickets")
    .select(
      "*, products(name), brands(name), models(name), addresses(*), invoices(*), appointments(*, technicians(id, profile_id, profiles(full_name, phone))), service_visits(*, ratings(*), ro_checklists(*))"
    )
    .eq("id", ticketId)
    .single()
  if (error) throw error
  return data
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
}

export async function renewAmcPlan(input: RenewAmcInput) {
  const { data, error } = await supabase.rpc("renew_amc_plan", {
    p_org_id: input.orgId,
    p_product_id: input.productId,
    p_plan_id: input.planId,
    p_payment_reference: input.paymentReference,
    p_years: input.years ?? null,
  })
  if (error) throw error
  return data as { contract_id: string; ticket_ids: string[]; expiry_date: string }
}

// ── Product / Spare Enquiry (CUST-04 / CUST-05) ───────────────────────────

export async function listVideoLibrary(orgId: string) {
  const { data, error } = await supabase.from("video_library").select("*").eq("org_id", orgId)
  if (error) throw error
  return data
}

export type EnquiryRpcInput = {
  orgId: string
  kind: "product" | "spare"
  enquiryType: Enums<"enquiry_type"> | null
  description: string
  photoUrl?: string
}

export async function submitCustomerEnquiry(input: EnquiryRpcInput) {
  const { data, error } = await supabase.rpc("submit_customer_enquiry", {
    p_org_id: input.orgId,
    p_kind: input.kind,
    p_enquiry_type: input.enquiryType,
    p_description: input.description,
    p_photo_url: input.photoUrl ?? "",
  })
  if (error) throw error
  return data as string
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
