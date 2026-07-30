import { supabase } from "@/lib/supabase"
import { computeAllowedDurationMinutes, sumItemStandardMinutes } from "@/lib/job-allowance"
import type { DayJobInput, DayVisitInput, RouteTrailPoint } from "@/lib/routeColor"
import type { Tables, TablesInsert } from "@/types/database"
import type { DateRange } from "./reports"

// New file — the admin-side counterpart to src/services/technician.ts
// (owned by the mobile technician app, not touched here). Phase 10 scope:
// ADM-14 List, ADM-15 Live Map, ADM-16 Attendance, ADM-17 Spare Handover.
//
// `technicians.zone` / `technicians.is_active` (migration
// 20260702200000_technicians_admin_schema.sql) and the
// create_spare_handover/admin_sign_spare_handover RPCs (migration
// 20260702200100_technicians_admin_functions.sql) all post-date
// src/types/database.ts, which this file must not edit (integrator-owned,
// regenerated centrally — see src/services/service.ts's SettingsWithSla for
// the established precedent of extending a stale generated row type locally
// instead). RPC names aren't in a literal union that can be widened the
// same way, so those few calls go through a minimally-scoped `as never`
// cast on just the method argument, not on the whole client.
export type TechnicianRow = Tables<"technicians"> & { zone: string | null; is_active: boolean }
// Requirement 2/11 — `check_out_at` (migration 20260716120000_attendance_checkout.sql)
// post-dates the last database.ts regen too; widened locally the same way
// as TechnicianRow above rather than editing that shared file.
export type AttendanceRow = Tables<"attendance"> & { check_out_at: string | null }
export type TechnicianLocationRow = Tables<"technician_locations">
export type SpareHandoverRow = Tables<"spare_handovers">
export type SpareHandoverItemRow = Tables<"spare_handover_items">

/** Cast helper for RPC names added after the last `database.ts` regen. */
function rpc(name: string, args: Record<string, unknown>) {
  return supabase.rpc(name as never, args as never)
}

// ── ADM-14: Technicians list ──────────────────────────────────────────────

export type TechnicianListItem = TechnicianRow & {
  profiles: { full_name: string; phone: string | null; photo_url: string | null } | null
  /** Job count / revenue within `range` (see listTechnicians below) —
   *  defaults to "today" when no range is passed, preserving the original
   *  "today's" meaning for callers that don't opt into period filtering
   *  (TechnicianDetailPage.tsx's fixed "Today" KPI badges). */
  periodJobCount: number
  periodRevenue: number
  avgRating: number | null
}

/**
 * v2.2 constraint (see build report "known limitation"): provisioning a new
 * technician needs a Supabase Auth user + `profiles` row, which requires
 * the service_role key. This app only ships the anon key to the browser, so
 * "Add Technician" cannot create brand-new auth users here — this list (and
 * updateTechnician below) only ever operate on existing seeded
 * technician/profile rows.
 *
 * Owner request 2026-07-29: `range` is optional and additive — omitting it
 * reproduces exactly the original "today only" behavior (TechnicianDetailPage
 * and TechniciansSpareHandoverPage don't pass one); TechniciansListPage.tsx's
 * KPI row passes the dashboard-style PeriodFilter's selected range instead.
 */
export async function listTechnicians(orgId: string, range?: DateRange): Promise<TechnicianListItem[]> {
  const { data: technicians, error } = await supabase
    .from("technicians")
    .select("*, profiles(full_name, phone, photo_url)")
    .eq("org_id", orgId)
    .order("created_at")
  if (error) throw error
  const rows = (technicians ?? []) as unknown as (TechnicianRow & {
    profiles: { full_name: string; phone: string | null; photo_url: string | null } | null
  })[]
  if (rows.length === 0) return []

  let rangeStartIso: string
  let rangeEndIso: string
  if (range) {
    rangeStartIso = `${range.from}T00:00:00`
    rangeEndIso = `${range.to}T23:59:59.999`
  } else {
    const todayStart = new Date()
    todayStart.setHours(0, 0, 0, 0)
    rangeStartIso = todayStart.toISOString()
    rangeEndIso = new Date().toISOString()
  }

  const [visitsRes, ratingsRes] = await Promise.all([
    supabase
      .from("service_visits")
      .select("technician_id, service_charge, timer_end")
      .eq("org_id", orgId)
      .gte("timer_end", rangeStartIso)
      .lte("timer_end", rangeEndIso),
    supabase
      .from("ratings")
      .select("stars, service_visits!inner(technician_id, org_id)")
      .eq("service_visits.org_id", orgId),
  ])
  if (visitsRes.error) throw visitsRes.error
  if (ratingsRes.error) throw ratingsRes.error

  const jobCountByTech = new Map<string, number>()
  const revenueByTech = new Map<string, number>()
  for (const v of visitsRes.data ?? []) {
    jobCountByTech.set(v.technician_id, (jobCountByTech.get(v.technician_id) ?? 0) + 1)
    revenueByTech.set(v.technician_id, (revenueByTech.get(v.technician_id) ?? 0) + (v.service_charge ?? 0))
  }

  const ratingSumByTech = new Map<string, number>()
  const ratingCountByTech = new Map<string, number>()
  for (const r of (ratingsRes.data ?? []) as unknown as { stars: number; service_visits: { technician_id: string } }[]) {
    const techId = r.service_visits.technician_id
    ratingSumByTech.set(techId, (ratingSumByTech.get(techId) ?? 0) + r.stars)
    ratingCountByTech.set(techId, (ratingCountByTech.get(techId) ?? 0) + 1)
  }

  return rows.map((t) => {
    const count = ratingCountByTech.get(t.id) ?? 0
    return {
      ...t,
      periodJobCount: jobCountByTech.get(t.id) ?? 0,
      periodRevenue: revenueByTech.get(t.id) ?? 0,
      avgRating: count > 0 ? Math.round(((ratingSumByTech.get(t.id) ?? 0) / count) * 10) / 10 : null,
    }
  })
}

export async function updateTechnician(
  id: string,
  patch: { zone?: string | null; skills?: string[]; is_active?: boolean; is_on_duty?: boolean; daily_capacity_minutes?: number }
) {
  const { data, error } = await supabase
    .from("technicians")
    .update(patch as never)
    .eq("id", id)
    .select()
    .single()
  if (error) throw error
  return data
}

// ── Add technician (link an existing login) ───────────────────────────────
// Real account creation needs the service_role key (see file header) — this
// links a profile that already has a login (created outside this app, e.g.
// via the Supabase dashboard) but has no technicians row yet.

export type EligibleProfile = { id: string; full_name: string; phone: string | null }

export async function listEligibleTechnicianProfiles(orgId: string): Promise<EligibleProfile[]> {
  const [profilesRes, techniciansRes] = await Promise.all([
    supabase.from("profiles").select("id, full_name, phone").eq("org_id", orgId).eq("role", "technician"),
    supabase.from("technicians").select("profile_id").eq("org_id", orgId),
  ])
  if (profilesRes.error) throw profilesRes.error
  if (techniciansRes.error) throw techniciansRes.error
  const linked = new Set((techniciansRes.data ?? []).map((t) => t.profile_id))
  return (profilesRes.data ?? []).filter((p) => !linked.has(p.id))
}

export async function createTechnician(orgId: string, profileId: string): Promise<TechnicianRow> {
  const { data, error } = await supabase
    .from("technicians")
    .insert({ org_id: orgId, profile_id: profileId } as never)
    .select()
    .single()
  if (error) throw error
  return data as unknown as TechnicianRow
}

// ── Technician detail page ────────────────────────────────────────────────

export type TechnicianCurrentJob = {
  appointmentId: string
  ticketId: string
  status: string
  mode: string
  scheduledAt: string | null
  customerName: string | null
  customerMobile: string | null
  area: string | null
  productName: string | null
  complaintName: string | null
}

/** A technician can hold at most one open appointment at a time (enforced by assign_ticket_technician's conflict check), so this is unambiguously "their current/next job." */
export async function getTechnicianCurrentJob(technicianId: string): Promise<TechnicianCurrentJob | null> {
  const { data, error } = await supabase
    .from("appointments")
    .select(
      "id, ticket_id, status, mode, scheduled_at, service_tickets(name_of_complaint, customers(name, mobile), addresses(area), products(name))"
    )
    .eq("technician_id", technicianId)
    .in("status", ["scheduled", "in_progress"])
    .order("scheduled_at", { ascending: true, nullsFirst: true })
    .limit(1)
    .maybeSingle()
  if (error) throw error
  if (!data) return null
  const row = data as unknown as {
    id: string
    ticket_id: string
    status: string
    mode: string
    scheduled_at: string | null
    service_tickets: {
      name_of_complaint: string | null
      customers: { name: string; mobile: string } | null
      addresses: { area: string | null } | null
      products: { name: string } | null
    } | null
  }
  return {
    appointmentId: row.id,
    ticketId: row.ticket_id,
    status: row.status,
    mode: row.mode,
    scheduledAt: row.scheduled_at,
    customerName: row.service_tickets?.customers?.name ?? null,
    customerMobile: row.service_tickets?.customers?.mobile ?? null,
    area: row.service_tickets?.addresses?.area ?? null,
    productName: row.service_tickets?.products?.name ?? null,
    complaintName: row.service_tickets?.name_of_complaint ?? null,
  }
}

export async function getTechnicianAttendanceHistory(technicianId: string, limit = 30): Promise<AttendanceRow[]> {
  const { data, error } = await supabase
    .from("attendance")
    .select("*")
    .eq("technician_id", technicianId)
    .order("date", { ascending: false })
    .limit(limit)
  if (error) throw error
  // Requirement 7 — same check_out_at widening as the AttendanceRow type
  // above; `select("*")` already returns the real column at runtime once the
  // migration lands, the generated type just doesn't know about it yet.
  return (data ?? []) as unknown as AttendanceRow[]
}

/** Calendar view (TechnicianDetailPage's Attendance tab) — one month's rows
 * at a time, keyed by `date` on the client. `date` is a plain `date` column
 * (no timezone), so plain "YYYY-MM-DD" string bounds are exact — no Date
 * math/timezone drift risk, matching the range-query convention already
 * used in reports.ts (`.gte("date", ...).lte("date", ...)`). */
export async function getTechnicianAttendanceForMonth(technicianId: string, year: number, month: number): Promise<AttendanceRow[]> {
  const pad = (n: number) => String(n).padStart(2, "0")
  const from = `${year}-${pad(month + 1)}-01`
  const lastDay = new Date(year, month + 1, 0).getDate()
  const to = `${year}-${pad(month + 1)}-${pad(lastDay)}`

  const { data, error } = await supabase
    .from("attendance")
    .select("*")
    .eq("technician_id", technicianId)
    .gte("date", from)
    .lte("date", to)
  if (error) throw error
  return (data ?? []) as unknown as AttendanceRow[]
}

/** One calendar day's job/rating detail (clicking a day in the Attendance
 * calendar) — service_visits has no plain `date` column, only `created_at`
 * (timestamptz), so the range is a local-midnight-to-local-midnight bound on
 * that column, same shape as the dayStart/dayEnd range queries already used
 * in technician.ts. A visit's rating is 1:1 (ratings.visit_id unique). */
export type TechnicianVisitForDate = {
  id: string
  timer_start: string | null
  timer_end: string | null
  service_tickets: { name_of_complaint: string | null; type: string } | null
  ratings: { stars: number; review: string | null } | null
}

export async function getTechnicianVisitsForDate(technicianId: string, dateStr: string): Promise<TechnicianVisitForDate[]> {
  const dayStart = new Date(`${dateStr}T00:00:00`)
  const dayEnd = new Date(`${dateStr}T23:59:59.999`)

  const { data, error } = await supabase
    .from("service_visits")
    .select("id, timer_start, timer_end, service_tickets(name_of_complaint, type), ratings(stars, review)")
    .eq("technician_id", technicianId)
    .gte("created_at", dayStart.toISOString())
    .lte("created_at", dayEnd.toISOString())
    .order("created_at", { ascending: true })
  if (error) throw error
  return (data ?? []) as unknown as TechnicianVisitForDate[]
}

export type TechnicianRewardItem = Tables<"rewards">

export async function listTechnicianRewards(technicianId: string, limit = 20): Promise<TechnicianRewardItem[]> {
  const { data, error } = await supabase
    .from("rewards")
    .select("*")
    .eq("winner_id", technicianId)
    .order("given_at", { ascending: false })
    .limit(limit)
  if (error) throw error
  return data ?? []
}

// ── Requirement 2/11: History tab enrichment (duration + rating) ──────────
// TechnicianDetailPage's History tab previously reused service.ts's
// listTickets (customer/complaint/product/date/type/priority/status only,
// no duration or rating). This is a separate, technician-scoped query here
// rather than extending listTickets/TicketListItem directly — service.ts
// isn't owned by this pass (see file header), and the extra
// service_visits/ratings embed is only needed on this one admin screen.
// `appointments!inner(technician_id)` mirrors listTickets' client-side "any
// of its appointments belongs to this technician" filter, pushed into the
// query instead of applied after the fetch.
export type TechnicianHistoryTicket = Tables<"service_tickets"> & {
  customers: { name: string; mobile: string } | null
  products: { name: string } | null
  service_visits: { timer_start: string | null; timer_end: string | null; ratings: { stars: number } | null }[]
}

export async function getTechnicianTicketHistory(technicianId: string): Promise<TechnicianHistoryTicket[]> {
  const { data, error } = await supabase
    .from("service_tickets")
    .select(
      "*, customers(name, mobile), products(name), appointments!inner(technician_id), service_visits(timer_start, timer_end, ratings(stars))"
    )
    .eq("appointments.technician_id", technicianId)
    .order("created_at", { ascending: false })
    .limit(200)
  if (error) throw error
  return (data ?? []) as unknown as TechnicianHistoryTicket[]
}

/**
 * Picks the visit to summarize on a History row when a ticket has more than
 * one service_visits row (revisits) — the most recently *completed* one
 * (both timer_start and timer_end set), falling back to the latest visit of
 * any kind so a job that's currently in progress doesn't just show nothing.
 * Rows whose picked visit isn't actually completed render no duration/rating
 * at all (see HistoryTab in TechnicianDetailPage.tsx) — this only decides
 * *which* visit to look at, not whether to display it.
 */
export function pickHistoryVisit(
  visits: { timer_start: string | null; timer_end: string | null; ratings: { stars: number } | null }[]
) {
  const completed = visits.filter((v) => v.timer_start && v.timer_end)
  if (completed.length > 0) return completed[completed.length - 1]
  return visits[visits.length - 1] ?? null
}

// ── ADM-15: Live tracking (map) ───────────────────────────────────────────

export type TechnicianWithLatestLocation = TechnicianRow & {
  profiles: { full_name: string; phone: string | null } | null
  latestLocation: TechnicianLocationRow | null
}

export async function listTechniciansWithLatestLocation(orgId: string): Promise<TechnicianWithLatestLocation[]> {
  const [techRes, locRes] = await Promise.all([
    supabase.from("technicians").select("*, profiles(full_name, phone)").eq("org_id", orgId).eq("is_active" as "is_on_duty", true),
    supabase
      .from("technician_locations")
      .select("*")
      .eq("org_id", orgId)
      .order("recorded_at", { ascending: false })
      .limit(500),
  ])
  if (techRes.error) throw techRes.error
  if (locRes.error) throw locRes.error

  const latestByTech = new Map<string, TechnicianLocationRow>()
  for (const loc of locRes.data ?? []) {
    if (!latestByTech.has(loc.technician_id)) latestByTech.set(loc.technician_id, loc)
  }

  const rows = (techRes.data ?? []) as unknown as (TechnicianRow & {
    profiles: { full_name: string; phone: string | null } | null
  })[]
  return rows.map((t) => ({ ...t, latestLocation: latestByTech.get(t.id) ?? null }))
}

/** Seeds the admin map's idle-detection buffer — Realtime INSERTs append to
 * this after mount, but without an initial window the map would need ~5
 * minutes of fresh events before it could flag anyone as idle. */
export async function listRecentTechnicianLocations(orgId: string, sinceIso: string): Promise<TechnicianLocationRow[]> {
  const { data, error } = await supabase
    .from("technician_locations")
    .select("*")
    .eq("org_id", orgId)
    .gte("recorded_at", sinceIso)
    .order("recorded_at", { ascending: true })
    .limit(2000)
  if (error) throw error
  return data ?? []
}

// ── A5: "Track today's movement" — full-day route trail ──────────────────
// Feeds src/lib/routeColor.ts's mergeDayLegs/buildDayLegs/classifyRouteTrail
// for the admin map's per-technician full-day coloured route. Mirrors
// services/technician.ts's own getTodaysTechnicianTrail/
// listTodaysVisitTimings (the technician-side "customer journey" view) —
// same two-source shape (a technician_locations trail + job/visit timing),
// just admin-scoped (any technician in the org, not just "me") and
// date-parameterized rather than hardcoded to "today".

/** A technician's full-day location trail, ordered ascending. */
export async function getTechnicianTrailForDate(technicianId: string, dateStr: string): Promise<RouteTrailPoint[]> {
  const dayStart = new Date(`${dateStr}T00:00:00`)
  const dayEnd = new Date(`${dateStr}T23:59:59.999`)
  const { data, error } = await supabase
    .from("technician_locations")
    .select("lat, lng, recorded_at")
    .eq("technician_id", technicianId)
    .gte("recorded_at", dayStart.toISOString())
    .lte("recorded_at", dayEnd.toISOString())
    .order("recorded_at", { ascending: true })
  if (error) throw error
  return (data ?? []).map((r) => ({ lat: r.lat, lng: r.lng, recordedAt: r.recorded_at }))
}

/** This technician's currently-active/upcoming jobs (no date filter — same
 * status-only scope listTodaysJobs uses in technician.ts, since a completed
 * job's appointment status has already flipped away from
 * scheduled/in_progress and won't show up here; that half of the picture
 * comes from listTechnicianVisitsForDate below instead). */
export async function listTechnicianActiveAppointments(technicianId: string): Promise<DayJobInput[]> {
  const { data, error } = await supabase
    .from("appointments")
    .select("ticket_id, scheduled_at, service_tickets(addresses(lat,lng), customers(name))")
    .eq("technician_id", technicianId)
    .in("status", ["scheduled", "in_progress"])
  if (error) throw error
  const rows = (data ?? []) as unknown as {
    ticket_id: string
    scheduled_at: string | null
    service_tickets: { addresses: { lat: number | null; lng: number | null } | null; customers: { name: string } | null } | null
  }[]
  return rows.map((r) => ({
    ticketId: r.ticket_id,
    scheduledAt: r.scheduled_at,
    lat: r.service_tickets?.addresses?.lat ?? null,
    lng: r.service_tickets?.addresses?.lng ?? null,
    customerName: r.service_tickets?.customers?.name ?? null,
  }))
}

/** This technician's actual visit timing (timer_start/timer_end) for one
 * calendar date — the completed/in-progress half of the day's legs. */
export async function listTechnicianVisitsForDate(technicianId: string, dateStr: string): Promise<DayVisitInput[]> {
  const dayStart = new Date(`${dateStr}T00:00:00`)
  const dayEnd = new Date(`${dateStr}T23:59:59.999`)
  const { data, error } = await supabase
    .from("service_visits")
    .select("ticket_id, timer_start, timer_end")
    .eq("technician_id", technicianId)
    .gte("created_at", dayStart.toISOString())
    .lte("created_at", dayEnd.toISOString())
  if (error) throw error
  return (data ?? []).map((v) => ({ ticketId: v.ticket_id, timerStart: v.timer_start, timerEnd: v.timer_end }))
}

// ── ETA / off-route (v2.2 §6.6) ───────────────────────────────────────────

export type TechnicianActiveJob = {
  ticketId: string
  lat: number
  lng: number
  scheduledAt: string | null
  customerName: string | null
  addressLabel: string | null
}

/** Each technician's current job-in-progress-or-next-up today, address coordinates included — the destination the live-tracking map compares live position against. */
export async function listTechniciansActiveJobs(orgId: string): Promise<Map<string, TechnicianActiveJob>> {
  const { data, error } = await supabase
    .from("appointments")
    .select("technician_id, scheduled_at, ticket_id, service_tickets!inner(addresses(lat, lng, door_no, area), customers(name))")
    .eq("org_id", orgId)
    .in("status", ["scheduled", "in_progress"])
    .not("technician_id", "is", null)
    .order("scheduled_at", { ascending: true, nullsFirst: true })
  if (error) throw error
  const rows = (data ?? []) as unknown as {
    technician_id: string
    scheduled_at: string | null
    ticket_id: string
    service_tickets: {
      addresses: { lat: number | null; lng: number | null; door_no: string | null; area: string | null } | null
      customers: { name: string } | null
    } | null
  }[]
  const byTech = new Map<string, TechnicianActiveJob>()
  for (const r of rows) {
    if (byTech.has(r.technician_id)) continue
    const addr = r.service_tickets?.addresses
    if (addr?.lat == null || addr?.lng == null) continue
    byTech.set(r.technician_id, {
      ticketId: r.ticket_id,
      lat: addr.lat,
      lng: addr.lng,
      scheduledAt: r.scheduled_at,
      customerName: r.service_tickets?.customers?.name ?? null,
      addressLabel: [addr.door_no, addr.area].filter(Boolean).join(", ") || null,
    })
  }
  return byTech
}

// ── Build Order A4: job-overrun detection (elapsed vs estimate) ───────────
// `service_tickets.estimated_duration_minutes` was added directly to
// database.ts alongside migration 20260724120000_job_overrun_estimate.sql.
// The join shape below still needs the same manual `as unknown as {...}[]`
// cast listTechniciansActiveJobs above uses — supabase-js can't infer nested
// relationship selects from the generated types either way.

export type TechnicianOpenVisit = {
  visitId: string
  ticketId: string
  timerStart: string | null
  timerEnd: string | null
  estimatedDurationMinutes: number | null
  // GV.md 1.2: the same admin-set-item-times + conditional-allowances figure
  // job-allowance.ts computes elsewhere — precomputed here (rather than in
  // TechniciansMapPage) so both its call sites (the live badge and the
  // admin-popup notify effect) agree. Note the review allowance can never
  // actually apply to a row from this query specifically — every row here
  // is, by definition, still OPEN (timer_end is null), and a rating can only
  // exist once RatingPage runs after the visit closes — see job-allowance.ts's
  // `reviewCollected` doc for why that's the literal, intended reading.
  allowedDurationMinutes: number | null
  customerName: string | null
  addressLabel: string | null
}

/** Each technician's currently-open visit (timer started, not yet ended) with its
 *  ticket's admin-set estimate — the input src/lib/job-overrun.ts#computeJobOverrun
 *  needs. Distinct from listTechniciansActiveJobs above: that one tracks travel
 *  toward the *next* destination (v2.2 §6.6 idle/off-route); this tracks time
 *  spent *inside* a job already started. */
export async function listTechniciansOpenVisits(orgId: string): Promise<Map<string, TechnicianOpenVisit>> {
  const [{ data, error }, settingsRes] = await Promise.all([
    supabase
      .from("service_visits")
      .select(
        "id, technician_id, ticket_id, timer_start, timer_end, service_tickets(estimated_duration_minutes, customers(name), addresses(door_no, area)), service_spares_used(qty, spares(standard_time_minutes)), ratings(google_review_clicked), leads(id)"
      )
      .eq("org_id", orgId)
      .not("timer_start", "is", null)
      .is("timer_end", null),
    supabase.from("settings").select("review_time_allowance_minutes, enquiry_time_allowance_minutes").eq("org_id", orgId).maybeSingle(),
  ])
  if (error) throw error
  const rows = (data ?? []) as unknown as {
    id: string
    technician_id: string
    ticket_id: string
    timer_start: string | null
    timer_end: string | null
    service_tickets: {
      estimated_duration_minutes: number | null
      customers: { name: string } | null
      addresses: { door_no: string | null; area: string | null } | null
    } | null
    service_spares_used: { qty: number; spares: { standard_time_minutes: number | null } | null }[]
    ratings: { google_review_clicked: boolean } | null
    leads: { id: string }[]
  }[]
  const settings = settingsRes.data
  const byTech = new Map<string, TechnicianOpenVisit>()
  for (const r of rows) {
    const addr = r.service_tickets?.addresses
    const allowedDurationMinutes = computeAllowedDurationMinutes({
      itemsStandardMinutesSum: sumItemStandardMinutes(
        (r.service_spares_used ?? []).map((s) => ({ qty: s.qty, standardTimeMinutes: s.spares?.standard_time_minutes }))
      ),
      ticketEstimatedDurationMinutes: r.service_tickets?.estimated_duration_minutes ?? null,
      reviewAllowanceMinutes: settings?.review_time_allowance_minutes ?? 0,
      enquiryAllowanceMinutes: settings?.enquiry_time_allowance_minutes ?? 0,
      reviewCollected: r.ratings?.google_review_clicked ?? false,
      enquiryLoggedThisVisit: (r.leads?.length ?? 0) > 0,
    })
    byTech.set(r.technician_id, {
      visitId: r.id,
      ticketId: r.ticket_id,
      timerStart: r.timer_start,
      timerEnd: r.timer_end,
      estimatedDurationMinutes: r.service_tickets?.estimated_duration_minutes ?? null,
      allowedDurationMinutes,
      customerName: r.service_tickets?.customers?.name ?? null,
      addressLabel: [addr?.door_no, addr?.area].filter(Boolean).join(", ") || null,
    })
  }
  return byTech
}

/**
 * Admin-side alert for an overrunning job (Build Order A4 "admin popup").
 * Chosen mechanism: a `notifications` row, same "reuse the existing polling
 * system" pattern as the header bell (useUnreadNotificationCount, 30s poll)
 * and refresh_operational_alerts' sla_breach/low_stock/handover_pending rows
 * (20260715300000_operational_alerts.sql) — not a new push mechanism. Unlike
 * that migration's scan-on-dashboard-load functions, detection here runs
 * entirely client-side on TechniciansMapPage (see that page's `now` tick),
 * which is already the same live-tracking screen `technician_locations`
 * belongs to — no DB trigger needed per the task's own "prefer client-side
 * unless there's a concrete reason" guidance.
 *
 * `notifications_insert_ops` (20260701091300_rls.sql) lets any ops-staff
 * client insert directly — no SECURITY DEFINER RPC required. Dedup mirrors
 * every other notification writer in this codebase: skip if a row for
 * (org_id, type, ref_id) already exists, regardless of read status, so
 * re-visiting the map page doesn't spam a fresh notification for a job
 * that's still overrunning from an earlier visit.
 */
export async function notifyJobOverrunAlert(
  orgId: string,
  visit: TechnicianOpenVisit,
  overrunByMinutes: number,
  location: { lat: number; lng: number; recordedAt: string } | null
): Promise<void> {
  const { data: existing, error: checkError } = await supabase
    .from("notifications")
    .select("id")
    .eq("org_id", orgId)
    .eq("type", "job_overrun")
    .eq("ref_id", visit.visitId)
    .limit(1)
  if (checkError) {
    console.error("Failed to check for an existing job_overrun notification:", checkError)
    return
  }
  if (existing && existing.length > 0) return

  const locationText = location
    ? ` Last known location: ${location.lat.toFixed(5)}, ${location.lng.toFixed(5)} (as of ${new Date(location.recordedAt).toLocaleTimeString()}).`
    : " No recent location ping for this technician yet."
  const { error } = await supabase.from("notifications").insert({
    org_id: orgId,
    role: "operation_admin",
    type: "job_overrun",
    title: "Job running over its estimated time",
    body:
      `${visit.customerName ?? "Customer"}${visit.addressLabel ? ` (${visit.addressLabel})` : ""} — ` +
      `running ${Math.round(overrunByMinutes)} min over the ${visit.estimatedDurationMinutes ?? "—"} min estimate.` +
      locationText,
    ref_id: visit.visitId,
  })
  if (error) console.error("Failed to create job_overrun notification:", error)
}

// ── ADM-16: Attendance ─────────────────────────────────────────────────────

export type AttendanceListItem = AttendanceRow & {
  technicians: { id: string; profiles: { full_name: string } | null } | null
}

export async function listAttendanceForDate(orgId: string, date: string): Promise<AttendanceListItem[]> {
  const { data, error } = await supabase
    .from("attendance")
    .select("*, technicians(id, profiles(full_name))")
    .eq("org_id", orgId)
    .eq("date", date)
    .order("check_in_at")
  if (error) throw error
  return (data ?? []) as unknown as AttendanceListItem[]
}

// ── ADM-17: Spare handover ────────────────────────────────────────────────

export type SpareHandoverListItem = SpareHandoverRow & {
  technicians: { id: string; profiles: { full_name: string } | null } | null
  spare_handover_items: (SpareHandoverItemRow & { spares: { name: string; sku: string | null } | null })[]
}

export async function listSpareHandovers(orgId: string): Promise<SpareHandoverListItem[]> {
  const { data, error } = await supabase
    .from("spare_handovers")
    .select("*, technicians(id, profiles(full_name)), spare_handover_items(*, spares(name, sku))")
    .eq("org_id", orgId)
    .order("date", { ascending: false })
    .limit(100)
  if (error) throw error
  return (data ?? []) as unknown as SpareHandoverListItem[]
}

export type SpareOption = { id: string; name: string; sku: string | null; price: number }

export async function listSparesForHandover(orgId: string): Promise<SpareOption[]> {
  const { data, error } = await supabase.from("spares").select("id, name, sku, price").eq("org_id", orgId).order("name")
  if (error) throw error
  return data ?? []
}

export type CreateSpareHandoverInput = {
  orgId: string
  technicianId: string
  date: string
  items: { spareId: string; qtyGiven: number }[]
}

export async function createSpareHandover(input: CreateSpareHandoverInput) {
  const { data, error } = await rpc("create_spare_handover", {
    p_org_id: input.orgId,
    p_technician_id: input.technicianId,
    p_date: input.date,
    p_items: input.items.map((i) => ({ spare_id: i.spareId, qty_given: i.qtyGiven })),
  })
  if (error) throw error
  return data as string
}

export async function adminSignSpareHandover(handoverId: string, adminSignUrl: string) {
  const { error } = await rpc("admin_sign_spare_handover", {
    p_handover_id: handoverId,
    p_admin_sign_url: adminSignUrl,
  })
  if (error) throw error
}

export type SpareHandoverItemInsert = TablesInsert<"spare_handover_items">

// ── Phase 1 assignment-engine data: technician_availability ───────────────
// Turns on real per-technician working/leave + shift data for the
// assignment engine (see GV_Mart_Technician_Assignment_Logic_Change.md
// Phase 1) — no assignment-logic behavior change in this pass, this just
// makes the rows editable from TechnicianDetailPage's Availability tab.

export type TechnicianAvailabilityRow = Tables<"technician_availability">

/** "Upcoming" = today onward, local calendar date (the column is a plain
 * `date`, no timezone) — same local-date-string convention already used by
 * TechnicianDetailPage's Attendance tab (`todayStr` there). */
export async function listTechnicianAvailability(technicianId: string): Promise<TechnicianAvailabilityRow[]> {
  const now = new Date()
  const pad = (n: number) => String(n).padStart(2, "0")
  const todayStr = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`

  const { data, error } = await supabase
    .from("technician_availability")
    .select("*")
    .eq("technician_id", technicianId)
    .gte("date", todayStr)
    .order("date", { ascending: true })
  if (error) throw error
  return data ?? []
}

/** technician_availability has a unique(technician_id, date) constraint —
 * upsert on that pair so re-submitting the same date edits it in place
 * instead of erroring. */
export async function upsertTechnicianAvailability(
  input: TablesInsert<"technician_availability">
): Promise<TechnicianAvailabilityRow> {
  const { data, error } = await supabase
    .from("technician_availability")
    .upsert(input, { onConflict: "technician_id,date" })
    .select()
    .single()
  if (error) throw error
  return data
}

export async function deleteTechnicianAvailability(id: string): Promise<void> {
  const { error } = await supabase.from("technician_availability").delete().eq("id", id)
  if (error) throw error
}
