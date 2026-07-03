import { supabase } from "@/lib/supabase"
import { db } from "@/lib/offline/db"
import { enqueue } from "@/lib/offline/outbox"
import type { Enums, Tables } from "@/types/database"

export type AttendanceRow = Tables<"attendance">
export type SpareHandoverRow = Tables<"spare_handovers">
export type SpareHandoverItemRow = Tables<"spare_handover_items">
export type ServiceVisitRow = Tables<"service_visits">
export type ServiceTicketRow = Tables<"service_tickets">
export type AppointmentRow = Tables<"appointments">
export type RatingRow = Tables<"ratings">
export type SettingsRow = Tables<"settings">
export type TechnicianRow = Tables<"technicians">

// v2.2 §6.5 "Touching the number starts the call, and calls are tracked and
// recorded." A `tel:` link itself can't be observed completing (the OS owns
// the call), so this logs the tap — best-effort, fire-and-forget so a
// logging failure never blocks the actual call. Not queued offline: a
// missed log while offline is an acceptable degradation for a reporting
// figure, unlike attendance/invoice data.
export async function logCall(input: { orgId: string; technicianId: string | null; customerId: string | null; ticketId: string | null }) {
  try {
    await supabase.from("call_logs").insert({
      org_id: input.orgId,
      technician_id: input.technicianId,
      customer_id: input.customerId,
      ticket_id: input.ticketId,
    })
  } catch {
    // best-effort — see comment above
  }
}

// ── Profile / settings (read-through cached) ────────────────────────────

export async function getMyTechnician(profileId: string) {
  const { data, error } = await supabase.from("technicians").select("*").eq("profile_id", profileId).single()
  if (error) throw error
  return data
}

export async function getSettings(orgId: string): Promise<SettingsRow> {
  if (navigator.onLine) {
    const { data, error } = await supabase.from("settings").select("*").eq("org_id", orgId).single()
    if (!error && data) {
      await db.settingsCache.put({ orgId, data, updatedAt: Date.now() })
      return data
    }
  }
  const cached = await db.settingsCache.get(orgId)
  if (cached) return cached.data as SettingsRow
  throw new Error("settings_unavailable_offline")
}

// GV Mart office location — used as the geofence center for attendance
// (v2.2 §6.8: "inside office" only, no distance figure shown to the user).
// Not in `settings` (that table holds only numeric/time parameters); a
// single fixed office coordinate is app-level config.
export const OFFICE_LOCATION = { lat: 13.0827, lng: 80.2707 } // Chennai HQ placeholder, admin can relocate via env later

// ── TECH-01 Attendance ───────────────────────────────────────────────────

export async function getTodayAttendance(technicianId: string, date: string): Promise<AttendanceRow | null> {
  const cacheId = `${technicianId}:${date}`
  if (navigator.onLine) {
    const { data, error } = await supabase
      .from("attendance")
      .select("*")
      .eq("technician_id", technicianId)
      .eq("date", date)
      .maybeSingle()
    if (!error) {
      if (data) await db.attendanceCache.put({ id: cacheId, technicianId, date, data, updatedAt: Date.now() })
      return data
    }
  }
  const cached = await db.attendanceCache.get(cacheId)
  return cached ? (cached.data as AttendanceRow) : null
}

export type MarkAttendanceInput = {
  orgId: string
  technicianId: string
  date: string
  checkInAt: string
  insideGeofence: boolean
  selfieUrl: string
  isLate: boolean
  affirmation: boolean
  pledge: boolean
  meeting: boolean
}

/** Queues attendance through the offline outbox — never calls Supabase directly (DoD: "everything must queue"). */
export async function queueMarkAttendance(input: MarkAttendanceInput) {
  const row = {
    org_id: input.orgId,
    technician_id: input.technicianId,
    date: input.date,
    check_in_at: input.checkInAt,
    inside_geofence: input.insideGeofence,
    selfie_url: input.selfieUrl,
    is_late: input.isLate,
    affirmation: input.affirmation,
    pledge: input.pledge,
    meeting: input.meeting,
  }
  const cacheId = `${input.technicianId}:${input.date}`
  await db.attendanceCache.put({ id: cacheId, technicianId: input.technicianId, date: input.date, data: row, updatedAt: Date.now() })
  await enqueue("attendance.mark", row)
}

/** v2.2 §6.5 "30 min lunch allowed, red over 45" — start/end are queued patches on today's attendance row. */
export async function queueLunchToggle(technicianId: string, date: string, patch: { lunch_start: string } | { lunch_end: string }) {
  const cacheId = `${technicianId}:${date}`
  const cached = await db.attendanceCache.get(cacheId)
  if (cached) {
    await db.attendanceCache.put({ ...cached, data: { ...(cached.data as AttendanceRow), ...patch }, updatedAt: Date.now() })
  }
  await enqueue("attendance.lunch", { technicianId, date, patch })
}

// ── TECH-02 Spare receipt ────────────────────────────────────────────────

export async function getTodayHandover(technicianId: string, date: string) {
  const { data, error } = await supabase
    .from("spare_handovers")
    .select("*, spare_handover_items(*, spares(name, sku))")
    .eq("technician_id", technicianId)
    .eq("date", date)
    .maybeSingle()
  if (error) throw error
  return data
}

export async function queueConfirmHandover(handoverId: string, techSignUrl: string, adminSignUrl: string) {
  await enqueue("spare_handover.confirm", { handoverId, techSignUrl, adminSignUrl })
}

// ── TECH-03 Home / Today's jobs ──────────────────────────────────────────

export type JobCard = AppointmentRow & {
  service_tickets: ServiceTicketRow & {
    customers: { id: string; name: string; mobile: string } | null
    addresses: { area: string | null; door_no: string | null; lat: number | null; lng: number | null } | null
    products: { name: string } | null
  }
}

export async function listTodaysJobs(technicianId: string): Promise<JobCard[]> {
  if (navigator.onLine) {
    const { data, error } = await supabase
      .from("appointments")
      .select(
        "*, service_tickets!inner(*, customers(id,name,mobile), addresses(area,door_no,lat,lng), products(name))"
      )
      .eq("technician_id", technicianId)
      .in("status", ["scheduled", "in_progress"])
      .order("scheduled_at", { ascending: true, nullsFirst: true })
    if (!error && data) {
      const rows = data as unknown as JobCard[]
      await db.jobsCache.bulkPut(rows.map((r) => ({ id: r.id, ticketId: r.ticket_id, data: r, updatedAt: Date.now() })))
      return rows
    }
  }
  const cached = await db.jobsCache.toArray()
  return cached.map((c) => c.data as JobCard)
}

// ── TECH-06 Job detail / history ─────────────────────────────────────────

export type JobDetail = ServiceTicketRow & {
  customers: { id: string; name: string; mobile: string } | null
  addresses: Tables<"addresses"> | null
  products: { name: string; warranty_months: number; category: Enums<"brand_category"> } | null
  brands: { name: string } | null
  models: { name: string } | null
  appointments: { scheduled_at: string | null; mode: Enums<"appointment_mode">; status: Enums<"appointment_status">; technician_id: string | null }[]
  service_visits: {
    id: string
    timer_start: string | null
    timer_end: string | null
    service_charge: number
    before_image_url: string | null
    after_image_url: string | null
  }[]
}

export async function getJobDetail(ticketId: string): Promise<JobDetail> {
  if (navigator.onLine) {
    const { data, error } = await supabase
      .from("service_tickets")
      .select(
        "*, customers(id,name,mobile), addresses(*), products(name, warranty_months, category), brands(name), models(name), appointments(scheduled_at, mode, status, technician_id), service_visits(id, timer_start, timer_end, service_charge, before_image_url, after_image_url)"
      )
      .eq("id", ticketId)
      .single()
    if (!error && data) {
      const row = data as unknown as JobDetail
      await db.jobDetailCache.put({ ticketId, data: row, updatedAt: Date.now() })
      return row
    }
  }
  const cached = await db.jobDetailCache.get(ticketId)
  if (cached) return cached.data as JobDetail
  throw new Error("job_detail_unavailable_offline")
}

export type CustomerHistoryEntry = {
  id: string
  name_of_complaint: string | null
  nature_of_complaint: string | null
  type: Enums<"ticket_type"> | null
  status: Enums<"ticket_status">
  created_at: string
  service_visits: { timer_start: string | null; timer_end: string | null; service_charge: number }[]
}

/** Previous service history for a customer (TECH-06 "previous history timeline"), most recent first. */
export async function getCustomerHistory(customerId: string, excludeTicketId?: string): Promise<CustomerHistoryEntry[]> {
  const { data, error } = await supabase
    .from("service_tickets")
    .select("id, name_of_complaint, nature_of_complaint, type, status, created_at, service_visits(timer_start, timer_end, service_charge)")
    .eq("customer_id", customerId)
    .neq("id", excludeTicketId ?? "")
    .order("created_at", { ascending: false })
    .limit(10)
  if (error) throw error
  return (data ?? []) as unknown as CustomerHistoryEntry[]
}

/** TECH-06 costing rule: Paid -> qty & cost from master; Warranty/AMC -> cost 0 but qty still captured. */
export function isChargeableTicketType(type: Enums<"ticket_type"> | null) {
  return type === "paid" || type === "installation"
}

// ── TECH-04 Map / location tracking ──────────────────────────────────────

export async function queueLocationPing(orgId: string, technicianId: string, lat: number, lng: number) {
  await enqueue("location.ping", {
    org_id: orgId,
    technician_id: technicianId,
    lat,
    lng,
    recorded_at: new Date().toISOString(),
  })
}

// ── TECH-05 Customer search & call ────────────────────────────────────────

export async function searchAddressesForTechnician(orgId: string, term: string) {
  const q = term.trim().replace(/[%,]/g, "")
  if (!q) return []
  // Pulls each customer's most recent open/assigned/in-progress ticket so the
  // result card can show "only the Service/Product relevant to this job"
  // (TECH-05 BuildSpec) without a new RPC — same table, wider select.
  const { data, error } = await supabase
    .from("addresses")
    .select(
      "id, door_no, area, pincode, lat, lng, customers(id, name, mobile, service_tickets(id, name_of_complaint, type, status, products(name), created_at))"
    )
    .eq("org_id", orgId)
    .or(`area.ilike.%${q}%,door_no.ilike.%${q}%,pincode.ilike.%${q}%`)
    .limit(10)
  if (error) throw error
  return data ?? []
}

// ── TECH-07 On-site stepper ───────────────────────────────────────────────

export async function queueStartVisit(visit: {
  id: string
  orgId: string
  ticketId: string
  technicianId: string
  timerStart: string
}) {
  const row = {
    id: visit.id,
    org_id: visit.orgId,
    ticket_id: visit.ticketId,
    technician_id: visit.technicianId,
    timer_start: visit.timerStart,
  }
  await db.draftVisits.put({ clientId: visit.id, ticketId: visit.ticketId, serverId: visit.id, data: row, updatedAt: Date.now() })
  await enqueue("service_visit.start", row)
  // Arrival also triggers the productivity timer; appointment flips to in_progress.
  if (navigator.onLine) {
    await supabase.from("appointments").update({ status: "in_progress" }).eq("ticket_id", visit.ticketId).eq("technician_id", visit.technicianId)
  }
}

export async function queueVisitImage(visitId: string, kind: "before" | "after", url: string) {
  await enqueue("service_visit.image", { visitId, column: kind === "before" ? "before_image_url" : "after_image_url", url })
}

/** Closes the productivity timer (timer_end) once payment is complete — the outbox kind + sync.ts handler already existed but nothing queued it yet. */
export async function queueEndVisit(visitId: string, timerEnd: string) {
  await enqueue("service_visit.arrive", { visitId, patch: { timer_end: timerEnd } })
}

/**
 * TECH-07 step 9 captures technician + customer on-screen signatures.
 * `service_visits.tech_sign_url`/`customer_sign_url` now exist
 * (20260702160000_phase7_visit_signatures.sql) — this both keeps the local
 * media cache (offline redisplay/retry) and queues the same generic
 * `service_visit.arrive` patch job `queueEndVisit` uses, so the signature
 * reaches the server exactly like every other on-site write, through the
 * existing outbox rather than a new job kind.
 */
export async function cacheVisitSignature(visitId: string, kind: "signature_tech" | "signature_customer", dataUrl: string) {
  await db.media.put({ id: `${visitId}:${kind}`, kind, dataUrl, meta: { capturedAt: new Date().toISOString() }, createdAt: Date.now() })
  const column = kind === "signature_tech" ? "tech_sign_url" : "customer_sign_url"
  await enqueue("service_visit.arrive", { visitId, patch: { [column]: dataUrl } })
}

export async function queueSopStepComplete(step: { id: string; orgId: string; visitId: string; stepName: string; expectedMinutes: number; doneAt: string }) {
  await enqueue("sop_step.complete", {
    id: step.id,
    org_id: step.orgId,
    visit_id: step.visitId,
    step_name: step.stepName,
    expected_minutes: step.expectedMinutes,
    done_at: step.doneAt,
  })
}

export async function queueRoChecklist(input: {
  orgId: string
  visitId: string
  tdsBefore?: number
  tdsAfter?: number
  tankCleaned: boolean | null
  productExplained: boolean | null
  clientName: string
}) {
  await enqueue("ro_checklist.save", {
    org_id: input.orgId,
    visit_id: input.visitId,
    tds_before: input.tdsBefore ?? null,
    tds_after: input.tdsAfter ?? null,
    tank_cleaned: input.tankCleaned,
    product_explained: input.productExplained,
    client_name: input.clientName,
  })
}

export type CreateServiceInvoiceInput = {
  orgId: string
  visitId: string
  serviceCharge: number
  discountPercent: number
  spares: { spareId: string; qty: number }[]
  paymentMethod: Enums<"payment_method">
  txnId?: string
  paymentDescription?: string
  isChargeable: boolean
}

export async function queueCreateServiceInvoice(input: CreateServiceInvoiceInput) {
  await enqueue("service_invoice.create", {
    orgId: input.orgId,
    visitId: input.visitId,
    serviceCharge: input.serviceCharge,
    discountPercent: input.discountPercent,
    spares: input.spares.map((s) => ({ spare_id: s.spareId, qty: s.qty })),
    paymentMethod: input.paymentMethod,
    txnId: input.txnId,
    paymentDescription: input.paymentDescription,
    isChargeable: input.isChargeable,
  })
}

export async function searchSpares(orgId: string, term: string) {
  const q = term.trim().replace(/[%,]/g, "")
  let query = supabase.from("spares").select("id, name, sku, price").eq("org_id", orgId).limit(15)
  if (q) query = query.or(`name.ilike.%${q}%,sku.ilike.%${q}%`)
  const { data, error } = await query
  if (error) throw error
  return data ?? []
}

export async function queueGenerateEnquiry(input: {
  orgId: string
  customerId?: string
  name: string
  mobile?: string
  enquiryType: Enums<"enquiry_type">
  note?: string
}) {
  await enqueue("lead.generate", {
    orgId: input.orgId,
    customerId: input.customerId,
    name: input.name,
    mobile: input.mobile,
    enquiryType: input.enquiryType,
    note: input.note,
  })
}

// ── TECH-08 Rating ─────────────────────────────────────────────────────────

export async function queueSubmitRating(input: { orgId: string; visitId: string; stars: number; review?: string; lowRatingReason?: string }) {
  await enqueue("rating.submit", {
    orgId: input.orgId,
    visitId: input.visitId,
    stars: input.stars,
    review: input.review,
    lowRatingReason: input.lowRatingReason,
  })
}

// ── TECH-09 History ────────────────────────────────────────────────────────

export type MyHistoryEntry = {
  id: string
  ticket_id: string
  timer_start: string | null
  timer_end: string | null
  service_charge: number
  service_tickets: {
    name_of_complaint: string | null
    type: Enums<"ticket_type"> | null
    status: Enums<"ticket_status">
    customers: { name: string } | null
  } | null
}

export async function listMyHistory(technicianId: string, filters: { from?: string; to?: string; type?: Enums<"ticket_type"> }): Promise<MyHistoryEntry[]> {
  let query = supabase
    .from("service_visits")
    .select("id, ticket_id, timer_start, timer_end, service_charge, service_tickets(name_of_complaint, type, status, customers(name))")
    .eq("technician_id", technicianId)
    .order("timer_start", { ascending: false })
    .limit(50)
  if (filters.from) query = query.gte("timer_start", filters.from)
  if (filters.to) query = query.lte("timer_start", filters.to)
  const { data, error } = await query
  if (error) throw error
  const rows = (data ?? []) as unknown as MyHistoryEntry[]
  return filters.type ? rows.filter((r) => r.service_tickets?.type === filters.type) : rows
}

// ── TECH-10 Profile / stats ────────────────────────────────────────────────

export async function getTechnicianStats(technicianId: string, orgId: string) {
  const since = new Date()
  since.setDate(since.getDate() - 30)
  const sinceIso = since.toISOString()

  const [visitsRes, ratingsRes] = await Promise.all([
    supabase
      .from("service_visits")
      .select("service_charge, timer_start")
      .eq("technician_id", technicianId)
      .gte("timer_start", sinceIso),
    supabase
      .from("ratings")
      .select("stars, service_visits!inner(technician_id)")
      .eq("service_visits.technician_id", technicianId),
  ])
  if (visitsRes.error) throw visitsRes.error
  if (ratingsRes.error) throw ratingsRes.error

  const revenue30d = (visitsRes.data ?? []).reduce((sum, v) => sum + (v.service_charge ?? 0), 0)
  const jobs30d = (visitsRes.data ?? []).length
  const ratings = (ratingsRes.data ?? []) as unknown as { stars: number }[]
  const avgRating = ratings.length ? ratings.reduce((s, r) => s + r.stars, 0) / ratings.length : null

  void orgId
  return { revenue30d, jobs30d, avgRating, ratingCount: ratings.length }
}
