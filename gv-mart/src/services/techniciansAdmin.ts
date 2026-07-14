import { supabase } from "@/lib/supabase"
import type { Tables, TablesInsert } from "@/types/database"

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
export type AttendanceRow = Tables<"attendance">
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
  todaysJobCount: number
  todaysRevenue: number
  avgRating: number | null
}

/**
 * v2.2 constraint (see build report "known limitation"): provisioning a new
 * technician needs a Supabase Auth user + `profiles` row, which requires
 * the service_role key. This app only ships the anon key to the browser, so
 * "Add Technician" cannot create brand-new auth users here — this list (and
 * updateTechnician below) only ever operate on existing seeded
 * technician/profile rows.
 */
export async function listTechnicians(orgId: string): Promise<TechnicianListItem[]> {
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

  const todayStart = new Date()
  todayStart.setHours(0, 0, 0, 0)
  const todayStartIso = todayStart.toISOString()

  const [visitsRes, ratingsRes] = await Promise.all([
    supabase
      .from("service_visits")
      .select("technician_id, service_charge, timer_end")
      .eq("org_id", orgId)
      .gte("timer_end", todayStartIso),
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
      todaysJobCount: jobCountByTech.get(t.id) ?? 0,
      todaysRevenue: revenueByTech.get(t.id) ?? 0,
      avgRating: count > 0 ? Math.round(((ratingSumByTech.get(t.id) ?? 0) / count) * 10) / 10 : null,
    }
  })
}

export async function updateTechnician(
  id: string,
  patch: { zone?: string | null; skills?: string[]; is_active?: boolean; is_on_duty?: boolean }
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
  return data ?? []
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
