import { supabase } from "@/lib/supabase"
import { db } from "@/lib/offline/db"
import { enqueue } from "@/lib/offline/outbox"
import { distanceKm, expectedMinutes, type GeoPoint } from "@/lib/offline/geo"
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

// Last-resort fallback origin for the Map page's distance-reach indicator
// (TECH-04) when GPS hasn't returned a fix yet — NOT the attendance
// geofence center. Attendance (TECH-01) reads the real, admin-editable
// office coordinate from settings.office_lat/office_lng instead (v2.2
// §6.8: "inside office" only, no distance figure ever shown to the user).
export const OFFICE_LOCATION = { lat: 13.0827, lng: 80.2707 } // matches settings' office_lat/lng default

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

/**
 * Queues attendance through the offline outbox — never calls Supabase directly
 * (DoD: "everything must queue"). Returns the merged row so callers can push
 * it straight into the query cache: the outbox only flushes to Supabase on
 * its ~20s interval, so a network refetch triggered right after this resolves
 * would still read the old, not-yet-synced server row and appear to silently
 * discard the tap.
 */
export async function queueMarkAttendance(input: MarkAttendanceInput): Promise<AttendanceRow> {
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
  const existing = await db.attendanceCache.get(cacheId)
  const merged = { ...(existing?.data as AttendanceRow | undefined), ...row } as AttendanceRow
  await db.attendanceCache.put({ id: cacheId, technicianId: input.technicianId, date: input.date, data: merged, updatedAt: Date.now() })
  await enqueue("attendance.mark", row)
  return merged
}

/**
 * v2.2 §6.5 "30 min lunch allowed, red over 45" — start/end are queued patches
 * on today's attendance row. Returns the merged row for the same reason as
 * queueMarkAttendance above (avoids the invalidate-then-refetch race with the
 * offline outbox's delayed sync).
 */
export async function queueLunchToggle(
  technicianId: string,
  date: string,
  patch: { lunch_start: string } | { lunch_end: string }
): Promise<AttendanceRow | null> {
  const cacheId = `${technicianId}:${date}`
  const cached = await db.attendanceCache.get(cacheId)
  let merged: AttendanceRow | null = null
  if (cached) {
    merged = { ...(cached.data as AttendanceRow), ...patch }
    await db.attendanceCache.put({ ...cached, data: merged, updatedAt: Date.now() })
  }
  await enqueue("attendance.lunch", { technicianId, date, patch })
  return merged
}

/**
 * Requirement 7 — real Attendance check-out (a genuine `check_out_at`
 * timestamp, not a derived/estimated one). `check_out_at` doesn't exist on
 * the generated `AttendanceRow` type yet (`src/types/database.ts` is
 * integrator-owned / regenerated centrally — see services/service.ts's
 * `SettingsWithSla` for the established precedent of locally widening a
 * stale generated row type instead of editing that file directly); the
 * migration adding the column already exists
 * (20260716120000_attendance_checkout.sql). Same queued-patch pattern as
 * queueLunchToggle above and for the identical reason: an immediate refetch
 * right after this resolves would otherwise race the offline outbox's ~20s
 * sync and read back the stale, not-yet-checked-out server row.
 */
export type AttendanceRowWithCheckOut = AttendanceRow & { check_out_at: string | null }

export async function queueCheckOut(technicianId: string, date: string): Promise<AttendanceRowWithCheckOut | null> {
  const checkOutAt = new Date().toISOString()
  const cacheId = `${technicianId}:${date}`
  const cached = await db.attendanceCache.get(cacheId)
  let merged: AttendanceRowWithCheckOut | null = null
  if (cached) {
    merged = { ...(cached.data as AttendanceRow), check_out_at: checkOutAt }
    await db.attendanceCache.put({ ...cached, data: merged, updatedAt: Date.now() })
  }
  await enqueue("attendance.checkout", { technicianId, date, checkOutAt })
  return merged
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

/**
 * Bug 2/3 (technician home overdue highlighting) — ported verbatim from the
 * admin side's isOverdueRow (src/app/admin/service/TicketsListPage.tsx):
 * overdue means the ticket has an SLA deadline that has already passed and
 * the ticket hasn't reached a terminal status. Takes the loosest shape that
 * satisfies both call sites (a live JobCard's service_tickets join and the
 * ticket fields it embeds) so it doesn't force a wider import just for typing.
 */
export function isOverdueJob(ticket: { sla_due_at: string | null; status: Enums<"ticket_status"> }, now: number): boolean {
  return !!ticket.sla_due_at && ticket.status !== "completed" && ticket.status !== "cancelled" && new Date(ticket.sla_due_at).getTime() <= now
}

export type TodaysJobCounts = {
  total: number
  pending: number
  completed: number
  cancelled: number
  overdue: number
}

/**
 * Requirement 6 — Today's Jobs / Pending / Completed / Cancelled / Overdue
 * counts row on TechnicianHomePage. `listTodaysJobs` only ever returns
 * appointments still in status scheduled/in_progress (no date filter — "all
 * currently open jobs" for this technician), so total/pending/overdue are
 * derived from that same result: pending = every open job (scheduled or
 * in_progress both count as "not yet completed today"), overdue = the subset
 * whose ticket already breached SLA. completed/cancelled appointments don't
 * appear in that query at all once they leave scheduled/in_progress, so they
 * need their own date-windowed queries — same `count: "exact", head: true` +
 * a today [00:00, 23:59:59.999] window pattern getDaySheetSummary uses in
 * services/workspace.ts, using `updated_at` as the completion/cancellation
 * timestamp proxy (appointments has no dedicated "closed_at" column).
 */
export async function getTodaysJobCounts(orgId: string, technicianId: string): Promise<TodaysJobCounts> {
  const date = new Date().toISOString().slice(0, 10)
  const dayStartIso = new Date(`${date}T00:00:00`).toISOString()
  const dayEndIso = new Date(`${date}T23:59:59.999`).toISOString()
  const now = Date.now()

  const [openJobs, completedRes, cancelledRes] = await Promise.all([
    listTodaysJobs(technicianId),
    supabase
      .from("appointments")
      .select("id", { count: "exact", head: true })
      .eq("org_id", orgId)
      .eq("technician_id", technicianId)
      .eq("status", "completed")
      .gte("updated_at", dayStartIso)
      .lte("updated_at", dayEndIso),
    supabase
      .from("appointments")
      .select("id", { count: "exact", head: true })
      .eq("org_id", orgId)
      .eq("technician_id", technicianId)
      .eq("status", "cancelled")
      .gte("updated_at", dayStartIso)
      .lte("updated_at", dayEndIso),
  ])
  if (completedRes.error) throw completedRes.error
  if (cancelledRes.error) throw cancelledRes.error

  const pending = openJobs.length
  const overdue = openJobs.filter((job) => job.service_tickets && isOverdueJob(job.service_tickets, now)).length
  const completed = completedRes.count ?? 0
  const cancelled = cancelledRes.count ?? 0

  return { total: pending + completed + cancelled, pending, completed, cancelled, overdue }
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
  service_visits: {
    id: string
    timer_start: string | null
    timer_end: string | null
    service_charge: number
    // Meeting spec D6: the previous technician's on-site notes — already
    // captured on every visit (see VisitDraftData.visitNotes -> endVisit),
    // just never selected/shown here before.
    notes: string | null
    // Build Order A3: optional voice note recorded on-site, alongside the
    // text note — same data-URL convention as before/after images and
    // signatures (see 20260724110000_service_visit_voice_notes.sql).
    voice_note_url: string | null
    service_spares_used: { id: string; qty: number; spares: { name: string } | null }[]
  }[]
}

/**
 * Previous service history for a customer (TECH-06 "previous history timeline"), most recent first.
 * Meeting spec D6: owner wants at least the last 2 services shown, with parts changed and the
 * previous technician's notes — not just dates — so a technician opening a job sees the full
 * picture, including visits a *different* technician handled (see the
 * `service_tickets_select_customer_history_technician` RLS policy this depends on).
 *
 * Build Order A3 fix: this was scoped to `customer_id` only, so a customer with more than one
 * product serviced would have every product's notes/parts interleaved regardless of which
 * product the *current* job is for — noisy, and actively misleading (a note about a different
 * appliance surfacing on this one). `productId` (the current ticket's `product_id`) narrows the
 * read to that same product's history when known; tickets with no product_id keep the previous
 * customer-wide behavior since there's nothing to scope to. No RLS change needed — see
 * 20260724110000_service_visit_voice_notes.sql's header for why: the existing
 * `is_technician_customer` policies already gate access at the customer level, and this filters
 * narrower within that same already-permitted row set.
 */
export async function getCustomerHistory(
  customerId: string,
  productId?: string | null,
  excludeTicketId?: string
): Promise<CustomerHistoryEntry[]> {
  let query = supabase
    .from("service_tickets")
    .select(
      "id, name_of_complaint, nature_of_complaint, type, status, created_at, service_visits(id, timer_start, timer_end, service_charge, notes, voice_note_url, service_spares_used(id, qty, spares(name)))"
    )
    .eq("customer_id", customerId)
    .neq("id", excludeTicketId ?? "")
  if (productId) query = query.eq("product_id", productId)
  const { data, error } = await query.order("created_at", { ascending: false }).limit(2)
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

/**
 * Continuous live-tracking stream (v2.2 §6.6) — a direct, best-effort write,
 * unlike queueLocationPing's offline-queued "arrived" event. A stale
 * position replayed minutes later from the outbox is worse than useless for
 * a "where is the technician right now" admin map, so a ping dropped while
 * offline is simply skipped rather than queued for later delivery.
 */
export async function pingLiveLocation(orgId: string, technicianId: string, lat: number, lng: number) {
  const { error } = await supabase.from("technician_locations").insert({ org_id: orgId, technician_id: technicianId, lat, lng })
  // Best-effort (see doc comment above) — logged, not swallowed, so a real
  // RLS/network failure is diagnosable instead of just silently never
  // appearing on the admin map with no trace of why.
  if (error) console.error("Failed to send live location ping:", error)
}

// ── Build Order STEP 5 / Assignment spec Phase 4 — route ordering ────────

/**
 * Loosest shape computeRouteOrder/selectNextJob actually need — same
 * "don't force a wider import just for typing" reasoning as isOverdueJob
 * above. Both are generic over `T extends RoutableJob`, so a real caller
 * passing JobCard[] gets JobCard[]/JobCard back, not this narrowed type.
 */
export type RoutableJob = {
  available_from: string | null
  available_to: string | null
  service_tickets: {
    estimated_duration_minutes: number | null
    addresses: { lat: number | null; lng: number | null } | null
  }
}

/**
 * `available_from`/`available_to` on `appointments` are plain nullable
 * `time` columns (only meaningful when `mode = 'datetime'`; `mode =
 * 'always'` keeps both null — see
 * 20260721091000_appointment_availability_window.sql). Permissive-when-
 * unknown: NULL on EITHER bound reads as "no constraint / always open", not
 * a half-open window — same precedent as the zone/skill/capacity hard
 * filters documented in
 * 20260721100000_technician_assignment_phase2_hard_filter.sql's header
 * comment. `atMinutes` is minutes-since-midnight of the projected arrival.
 */
function isWindowOpenAt(job: RoutableJob, atMinutes: number): boolean {
  if (job.available_from == null || job.available_to == null) return true
  const from = timeStringToMinutes(job.available_from)
  const to = timeStringToMinutes(job.available_to)
  if (from == null || to == null) return true
  return atMinutes >= from && atMinutes <= to
}

function timeStringToMinutes(value: string): number | null {
  const m = /^(\d{1,2}):(\d{2})/.exec(value)
  if (!m) return null
  return Number(m[1]) * 60 + Number(m[2])
}

/**
 * Build Order STEP 5 / Assignment spec Phase 4 (verification gate 4) —
 * orders a technician's remaining jobs into a route starting from their
 * current position: nearest-first by straight-line distance (the same
 * Haversine metric MapPage already shows on its live distance/ETA card — no
 * need for a second distance model just to pick an order), but a job whose
 * customer-availability window isn't open yet at the projected arrival is
 * skipped for the next-closest job whose window IS open, and reconsidered
 * again from the next stop onward — producing an A -> C -> back-to-B route
 * instead of a strict nearest-only greedy order.
 *
 * Each step advances the simulated clock by travel time plus
 * `estimated_duration_minutes` (0 when null — same legacy-null-contributes-0
 * convention the Phase 2 capacity filter uses) before evaluating the next
 * stop, so a deferred job's projected arrival accounts for time actually
 * spent at the stops visited ahead of it, not just travel time from "now" —
 * the spec's own stated reason Phase 4 needs Phase 1.3's duration data.
 * Jobs missing geocoded coordinates can't have a distance computed; they
 * sort last but stay eligible (never silently dropped from the route). If
 * NO remaining job's window is open yet (e.g. only one job left and it isn't
 * due for hours), falls back to nearest overall rather than stalling the
 * route with nothing selected — the window is a preference for ordering,
 * not a hard eligibility gate (unlike zone/skill/capacity at assignment
 * time).
 *
 * Deliberately myopic/recomputed rather than a persisted plan: callers
 * (MapPage) re-run this from the technician's live GPS position and the
 * current clock on every render, so "return to B once C is done" falls out
 * naturally from the technician's actual movement instead of a stale
 * upfront route.
 */
export function computeRouteOrder<T extends RoutableJob>(jobs: T[], startPosition: GeoPoint, startTime: Date, perKmMinutes: number): T[] {
  const remaining = jobs.slice()
  const ordered: T[] = []
  let position = startPosition
  let clockMinutes = startTime.getHours() * 60 + startTime.getMinutes()

  while (remaining.length > 0) {
    const candidates = remaining.map((job, index) => {
      const addr = job.service_tickets.addresses
      const dest = addr?.lat != null && addr?.lng != null ? { lat: addr.lat, lng: addr.lng } : null
      const km = dest ? distanceKm(position, dest) : null
      const arrivalMinutes = clockMinutes + (km != null ? expectedMinutes(km, perKmMinutes) : 0)
      return { index, job, km, dest, arrivalMinutes }
    })

    // Nearest first; jobs without resolvable coordinates sort last but stay eligible.
    candidates.sort((a, b) => {
      if (a.km == null && b.km == null) return 0
      if (a.km == null) return 1
      if (b.km == null) return -1
      return a.km - b.km
    })

    const pick = candidates.find((c) => isWindowOpenAt(c.job, c.arrivalMinutes)) ?? candidates[0]

    ordered.push(pick.job)
    remaining.splice(pick.index, 1)
    if (pick.dest) position = pick.dest
    clockMinutes = pick.arrivalMinutes + (pick.job.service_tickets.estimated_duration_minutes ?? 0)
  }

  return ordered
}

/** The route's first stop — what MapPage sends the technician to when no specific job is chosen. */
export function selectNextJob<T extends RoutableJob>(jobs: T[], position: GeoPoint, now: Date, perKmMinutes: number): T | null {
  return computeRouteOrder(jobs, position, now, perKmMinutes)[0] ?? null
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

/**
 * A visit can now be started from two places — MapPage's arrival detection
 * (auto or the "I've arrived" fallback tap) and OnSiteVisitPage's own mount
 * effect, reached directly from JobDetailPage's "Start visit" without going
 * through Map at all. Both must check for an already-open visit first (timer
 * started, not yet ended) so arriving-then-continuing doesn't create a
 * second, orphaned service_visits row with none of the on-site work attached
 * to it.
 */
export function findOpenVisit(visits: { id: string; timer_start: string | null; timer_end: string | null }[]) {
  return visits.find((v) => v.timer_start && !v.timer_end) ?? null
}

/**
 * `completed`/`cancelled` are terminal — once a ticket reaches either, no
 * screen should let a technician start a *new* service_visits row for it.
 * Callers (MapPage, JobDetailPage, OnSiteVisitPage) all gate on this before
 * offering "Navigate"/"Start visit"/arrival auto-start, since findOpenVisit
 * alone only stops a duplicate of the *current* visit, not re-opening a job
 * that already finished (e.g. via a stale ?ticketId= URL or browser back).
 */
export function isTicketClosed(status: Enums<"ticket_status"> | null | undefined) {
  return status === "completed" || status === "cancelled"
}

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
  // Arrival also triggers the productivity timer; appointment flips to
  // in_progress — scoped to appointments still scheduled/in_progress so this
  // can never silently resurrect an appointment already flipped to
  // completed/cancelled by create_service_invoice, as a last line of defense
  // if a UI guard elsewhere has a gap.
  if (navigator.onLine) {
    await supabase
      .from("appointments")
      .update({ status: "in_progress" })
      .eq("ticket_id", visit.ticketId)
      .eq("technician_id", visit.technicianId)
      .in("status", ["scheduled", "in_progress"])
  }
}

export async function queueVisitImage(visitId: string, kind: "before" | "after", url: string) {
  await enqueue("service_visit.image", { visitId, column: kind === "before" ? "before_image_url" : "after_image_url", url })
}

/**
 * Closes the productivity timer (timer_end) once payment is complete — the outbox kind + sync.ts handler already existed but nothing queued it yet.
 * Optionally carries the technician's own free-text on-site findings (`service_visits.notes`, an existing but previously-unused column) in the same
 * patch — sync.ts's `service_visit.arrive` handler already applies whatever fields are present in `patch` generically, so no new job kind or sync.ts
 * change is needed to land this.
 */
export async function queueEndVisit(visitId: string, timerEnd: string, notes?: string) {
  const patch: { timer_end: string; notes?: string } = { timer_end: timerEnd }
  const trimmedNotes = notes?.trim()
  if (trimmedNotes) patch.notes = trimmedNotes
  await enqueue("service_visit.arrive", { visitId, patch })
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

/**
 * Build Order A3 — optional on-site voice note, captured/cleared immediately
 * (not batched into the end-of-visit patch like the text `notes` field) so
 * it survives the app being closed mid-visit, same as the signatures above.
 * `dataUrl: null` clears an already-recorded note (re-record/remove).
 */
export async function cacheVisitVoiceNote(visitId: string, dataUrl: string | null) {
  if (dataUrl) {
    await db.media.put({ id: `${visitId}:voice_note`, kind: "voice_note", dataUrl, meta: { capturedAt: new Date().toISOString() }, createdAt: Date.now() })
  } else {
    await db.media.delete(`${visitId}:voice_note`)
  }
  await enqueue("service_visit.arrive", { visitId, patch: { voice_note_url: dataUrl } })
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
