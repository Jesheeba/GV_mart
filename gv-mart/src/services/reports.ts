import { supabase } from "@/lib/supabase"
import type { Enums } from "@/types/database"

export type DateRange = { from: string; to: string }

function rangeToTimestamps(range: DateRange) {
  // `to` is a date input (yyyy-mm-dd); make it inclusive of the whole day.
  const fromIso = new Date(`${range.from}T00:00:00`).toISOString()
  const toIso = new Date(`${range.to}T23:59:59.999`).toISOString()
  return { fromIso, toIso }
}

export function defaultDateRange(days = 30): DateRange {
  const to = new Date()
  const from = new Date()
  from.setDate(from.getDate() - days)
  return { from: from.toISOString().slice(0, 10), to: to.toISOString().slice(0, 10) }
}

// ── F2 quick-select date presets ─────────────────────────────────────────
export const dateRangePresets = ["thisMonth", "previousMonth", "thisYear", "allTime"] as const
export type DateRangePreset = (typeof dateRangePresets)[number]

/** Meeting spec F2 — "month / previous month / this year / all-time" presets
 * next to the existing manual from/to pickers. Same yyyy-mm-dd local-date
 * string shape as defaultDateRange() (what the <input type="date"> and
 * rangeToTimestamps() both expect). "All-time" has no real epoch to anchor
 * to, so it just uses a date well before this app could have any data. */
export function dateRangeForPreset(preset: DateRangePreset): DateRange {
  const now = new Date()
  const toStr = (d: Date) => d.toISOString().slice(0, 10)
  if (preset === "thisMonth") {
    return { from: toStr(new Date(now.getFullYear(), now.getMonth(), 1)), to: toStr(now) }
  }
  if (preset === "previousMonth") {
    return { from: toStr(new Date(now.getFullYear(), now.getMonth() - 1, 1)), to: toStr(new Date(now.getFullYear(), now.getMonth(), 0)) }
  }
  if (preset === "thisYear") {
    return { from: toStr(new Date(now.getFullYear(), 0, 1)), to: toStr(now) }
  }
  return { from: "2000-01-01", to: toStr(now) }
}

// ── ADM-27 Sales & Service report ───────────────────────────────────────
// "No. of sales calls" reads the real `call_logs` table (added in
// 20260702170500_lunch_and_calls.sql, populated by every tap-to-call in the
// technician app — v2.2 §6.5 "calls are tracked and recorded").
export type SalesServiceReport = {
  salesCallsCount: number
  invoiceTypeRatio: { type: Enums<"invoice_type">; count: number; total: number; percent: number }[]
  technicianServiceCounts: { technicianId: string; technicianName: string; count: number; revenue: number }[]
  avgValuePerServiceCall: number
  totalRevenue: number
}

export async function getSalesServiceReport(orgId: string, range: DateRange): Promise<SalesServiceReport> {
  const { fromIso, toIso } = rangeToTimestamps(range)

  const [callsRes, invoicesRes, visitsRes] = await Promise.all([
    supabase
      .from("call_logs")
      .select("id", { count: "exact", head: true })
      .eq("org_id", orgId)
      .gte("called_at", fromIso)
      .lte("called_at", toIso),
    supabase
      .from("invoices")
      .select("id, type, total, created_at")
      .eq("org_id", orgId)
      .gte("created_at", fromIso)
      .lte("created_at", toIso),
    supabase
      .from("service_visits")
      .select("id, technician_id, service_charge, timer_start, technicians(id, profiles(full_name))")
      .eq("org_id", orgId)
      .gte("timer_start", fromIso)
      .lte("timer_start", toIso),
  ])
  if (callsRes.error) throw callsRes.error
  if (invoicesRes.error) throw invoicesRes.error
  if (visitsRes.error) throw visitsRes.error

  const invoices = invoicesRes.data ?? []
  const totalRevenue = invoices.reduce((sum, i) => sum + (i.total ?? 0), 0)

  const ratioMap = new Map<Enums<"invoice_type">, { count: number; total: number }>()
  for (const inv of invoices) {
    const existing = ratioMap.get(inv.type) ?? { count: 0, total: 0 }
    existing.count += 1
    existing.total += inv.total ?? 0
    ratioMap.set(inv.type, existing)
  }
  // "Shown as ratios" gap fix — this used to return only raw counts/totals
  // despite the field being named *Ratio; add the actual percentage share of
  // invoice count each type represents, so the UI can show real ratios.
  const invoiceCountTotal = invoices.length
  const invoiceTypeRatio = [...ratioMap.entries()].map(([type, v]) => ({
    type,
    ...v,
    percent: invoiceCountTotal > 0 ? Math.round((v.count / invoiceCountTotal) * 100) : 0,
  }))

  type VisitRow = { id: string; technician_id: string; service_charge: number | null; technicians: { id: string; profiles: { full_name: string } | null } | null }
  const visits = (visitsRes.data ?? []) as unknown as VisitRow[]
  const techMap = new Map<string, { technicianName: string; count: number; revenue: number }>()
  for (const v of visits) {
    const name = v.technicians?.profiles?.full_name ?? "—"
    const existing = techMap.get(v.technician_id) ?? { technicianName: name, count: 0, revenue: 0 }
    existing.count += 1
    existing.revenue += v.service_charge ?? 0
    techMap.set(v.technician_id, existing)
  }
  const technicianServiceCounts = [...techMap.entries()].map(([technicianId, v]) => ({ technicianId, ...v }))

  const serviceRevenue = visits.reduce((sum, v) => sum + (v.service_charge ?? 0), 0)
  const avgValuePerServiceCall = visits.length ? Math.round((serviceRevenue / visits.length) * 100) / 100 : 0

  return {
    salesCallsCount: callsRes.count ?? 0,
    invoiceTypeRatio,
    technicianServiceCounts,
    avgValuePerServiceCall,
    totalRevenue,
  }
}

// ── ADM-28 P&L and Expenses ──────────────────────────────────────────────
export type PnlReport = {
  revenueWithGst: number
  revenueWithoutGst: number
  gstCollected: number
  expensesByCategory: { category: Enums<"expense_category">; amount: number }[]
  totalExpenses: number
  netProfitWithGst: number
  netProfitWithoutGst: number
}

export async function getPnlReport(orgId: string, range: DateRange): Promise<PnlReport> {
  const { fromIso, toIso } = rangeToTimestamps(range)

  const [invoicesRes, expensesRes] = await Promise.all([
    supabase
      .from("invoices")
      .select("total, subtotal, discount, gst, created_at")
      .eq("org_id", orgId)
      .gte("created_at", fromIso)
      .lte("created_at", toIso),
    supabase
      .from("expenses")
      .select("category, amount, date")
      .eq("org_id", orgId)
      .gte("date", range.from)
      .lte("date", range.to),
  ])
  if (invoicesRes.error) throw invoicesRes.error
  // expenses is master-only under RLS (expenses_select_master) — a non-master
  // caller gets an empty result set here, not an error; the P&L tab handles
  // that by showing zeros rather than crashing (RLS denies rows silently).
  if (expensesRes.error) throw expensesRes.error

  const invoices = invoicesRes.data ?? []
  const revenueWithGst = invoices.reduce((sum, i) => sum + (i.total ?? 0), 0)
  const gstCollected = invoices.reduce((sum, i) => sum + (i.gst ?? 0), 0)
  const revenueWithoutGst = revenueWithGst - gstCollected

  const expenseMap = new Map<Enums<"expense_category">, number>()
  for (const e of expensesRes.data ?? []) {
    expenseMap.set(e.category, (expenseMap.get(e.category) ?? 0) + (e.amount ?? 0))
  }
  const expensesByCategory = [...expenseMap.entries()].map(([category, amount]) => ({ category, amount }))
  const totalExpenses = expensesByCategory.reduce((sum, e) => sum + e.amount, 0)

  return {
    revenueWithGst,
    revenueWithoutGst,
    gstCollected,
    expensesByCategory,
    totalExpenses,
    netProfitWithGst: revenueWithGst - totalExpenses,
    netProfitWithoutGst: revenueWithoutGst - totalExpenses,
  }
}

// ── ADM-29 Performance scoreboard ────────────────────────────────────────
// Operation-admin KPI = % of tickets resolved within 24h of creation (the
// literal "24h-resolution KPI" named in BuildSpec Phase 10). Sales-admin KPI
// = lead conversion rate (won / total leads owned) rather than the
// lead_activities call-ratio proxy — conversion rate is the metric that
// actually exists cleanly per-person (leads.owner_id references a
// technician, but the same owner_id pattern also carries sales attribution
// in this schema's Automation module); documented as a judgment call in the
// final report since v2.2's "calls-ratio 40%/50%" figure was never anchored
// to a concrete table.
export type PerformanceRow = {
  id: string
  name: string
  role: "technician" | "sales_admin" | "operation_admin"
  jobsDone: number
  onTimePercent: number | null
  revenue: number
  avgRating: number | null
  reviewCount: number
  conversionPercent: number | null
  /** Average `timer_end - timer_start` (minutes) across this tech's visits in
   *  range that have both timestamps set. Null if none qualify. */
  avgCompletionMinutes: number | null
  /** jobsDone ÷ total on-duty hours in range (sum of each attendance day's
   *  `check_out_at - check_in_at`, days missing either timestamp skipped).
   *  Null if there's no on-duty time to divide by. */
  productivityJobsPerHour: number | null
}

// Same `end - start` → minutes diff used ad hoc by TicketDetailPage's
// `minutesBetween` and HistoryDetailPage's duration computation — duplicated
// here per this codebase's convention of not centralizing this small
// date-math helper into a shared util.
function minutesBetween(start: string | null, end: string | null) {
  if (!start || !end) return null
  return Math.round((new Date(end).getTime() - new Date(start).getTime()) / 60_000)
}

export async function getPerformanceReport(orgId: string, range: DateRange): Promise<PerformanceRow[]> {
  const { fromIso, toIso } = rangeToTimestamps(range)

  const [visitsRes, ticketsRes, ratingsRes, leadsRes, attendanceRes] = await Promise.all([
    supabase
      .from("service_visits")
      .select("id, technician_id, service_charge, timer_start, timer_end, needs_revisit, technicians(id, profiles(full_name))")
      .eq("org_id", orgId)
      .gte("timer_start", fromIso)
      .lte("timer_start", toIso),
    supabase
      .from("service_tickets")
      .select("id, status, created_at, updated_at, appointments(technician_id)")
      .eq("org_id", orgId)
      .gte("created_at", fromIso)
      .lte("created_at", toIso),
    supabase
      .from("ratings")
      .select("stars, service_visits!inner(technician_id, org_id, timer_start)")
      .eq("service_visits.org_id", orgId)
      .gte("service_visits.timer_start", fromIso)
      .lte("service_visits.timer_start", toIso),
    supabase
      .from("leads")
      .select("id, owner_id, status, created_at")
      .eq("org_id", orgId)
      .gte("created_at", fromIso)
      .lte("created_at", toIso),
    // Productivity denominator (on-duty hours) — `check_out_at` is a new
    // column landing on `attendance` alongside the check-out flow; queried
    // directly like other recently-added columns elsewhere in this codebase.
    supabase
      .from("attendance")
      .select("technician_id, date, check_in_at, check_out_at")
      .eq("org_id", orgId)
      .gte("date", range.from)
      .lte("date", range.to),
  ])
  if (visitsRes.error) throw visitsRes.error
  if (ticketsRes.error) throw ticketsRes.error
  if (ratingsRes.error) throw ratingsRes.error
  if (leadsRes.error) throw leadsRes.error
  if (attendanceRes.error) throw attendanceRes.error

  type VisitRow = {
    id: string
    technician_id: string
    service_charge: number | null
    timer_start: string | null
    timer_end: string | null
    needs_revisit: boolean
    technicians: { id: string; profiles: { full_name: string } | null } | null
  }
  const visits = (visitsRes.data ?? []) as unknown as VisitRow[]

  const byTech = new Map<string, PerformanceRow>()
  for (const v of visits) {
    const name = v.technicians?.profiles?.full_name ?? "—"
    const row = byTech.get(v.technician_id) ?? {
      id: v.technician_id,
      name,
      role: "technician" as const,
      jobsDone: 0,
      onTimePercent: null,
      revenue: 0,
      avgRating: null,
      reviewCount: 0,
      conversionPercent: null,
      avgCompletionMinutes: null,
      productivityJobsPerHour: null,
    }
    row.jobsDone += 1
    row.revenue += v.service_charge ?? 0
    byTech.set(v.technician_id, row)
  }

  // On-time % proxy: a visit with no `needs_revisit` flag counts as on-time
  // — this schema has no per-visit SLA/appointment-time comparison stored
  // on service_visits itself (only on the ticket), so "didn't need a
  // revisit" is the closest available signal of a clean first-time fix.
  const onTimeCounts = new Map<string, { onTime: number; total: number }>()
  for (const v of visits) {
    const c = onTimeCounts.get(v.technician_id) ?? { onTime: 0, total: 0 }
    c.total += 1
    if (!v.needs_revisit) c.onTime += 1
    onTimeCounts.set(v.technician_id, c)
  }
  for (const [techId, c] of onTimeCounts) {
    const row = byTech.get(techId)
    if (row) row.onTimePercent = c.total ? Math.round((c.onTime / c.total) * 1000) / 10 : null
  }

  type RatingRow = { stars: number; service_visits: { technician_id: string } | null }
  const ratings = (ratingsRes.data ?? []) as unknown as RatingRow[]
  const ratingAgg = new Map<string, { sum: number; count: number }>()
  for (const r of ratings) {
    const techId = r.service_visits?.technician_id
    if (!techId) continue
    const a = ratingAgg.get(techId) ?? { sum: 0, count: 0 }
    a.sum += r.stars
    a.count += 1
    ratingAgg.set(techId, a)
  }
  for (const [techId, a] of ratingAgg) {
    const row = byTech.get(techId)
    if (row) {
      row.avgRating = a.count ? Math.round((a.sum / a.count) * 10) / 10 : null
      row.reviewCount = a.count
    }
  }

  // Sales/lead-owner conversion rate — owner_id on `leads` references a
  // technician per the schema, but is also how field-originated sales
  // leads are attributed; folded into the same leaderboard as a
  // "conversion %" column per owner.
  type LeadRow = { id: string; owner_id: string | null; status: Enums<"lead_status"> }
  const leads = (leadsRes.data ?? []) as unknown as LeadRow[]
  const leadAgg = new Map<string, { won: number; total: number }>()
  for (const l of leads) {
    if (!l.owner_id) continue
    const a = leadAgg.get(l.owner_id) ?? { won: 0, total: 0 }
    a.total += 1
    if (l.status === "won") a.won += 1
    leadAgg.set(l.owner_id, a)
  }
  for (const [ownerId, a] of leadAgg) {
    const existing = byTech.get(ownerId)
    if (existing) {
      existing.conversionPercent = a.total ? Math.round((a.won / a.total) * 1000) / 10 : null
    } else {
      byTech.set(ownerId, {
        id: ownerId,
        name: "—",
        role: "technician",
        jobsDone: 0,
        onTimePercent: null,
        revenue: 0,
        avgRating: null,
        reviewCount: 0,
        conversionPercent: a.total ? Math.round((a.won / a.total) * 1000) / 10 : null,
        avgCompletionMinutes: null,
        productivityJobsPerHour: null,
      })
    }
  }

  // Avg completion time — mean of per-visit `timer_end - timer_start` minutes
  // among this tech's visits in range that have both timestamps set.
  const completionAgg = new Map<string, { sum: number; count: number }>()
  for (const v of visits) {
    const minutes = minutesBetween(v.timer_start, v.timer_end)
    if (minutes == null) continue
    const a = completionAgg.get(v.technician_id) ?? { sum: 0, count: 0 }
    a.sum += minutes
    a.count += 1
    completionAgg.set(v.technician_id, a)
  }
  for (const [techId, a] of completionAgg) {
    const row = byTech.get(techId)
    if (row) row.avgCompletionMinutes = a.count ? Math.round(a.sum / a.count) : null
  }

  // Productivity — jobsDone ÷ total on-duty hours in range. On-duty hours are
  // summed per attendance day where both check_in_at and check_out_at are
  // present; a day missing either (not checked out yet, or a historical row
  // predating the check-out flow) contributes nothing rather than NaN.
  type AttendanceRow = { technician_id: string; date: string; check_in_at: string | null; check_out_at: string | null }
  const attendance = (attendanceRes.data ?? []) as unknown as AttendanceRow[]
  const dutyHours = new Map<string, number>()
  for (const a of attendance) {
    if (!a.check_in_at || !a.check_out_at) continue
    const hours = (new Date(a.check_out_at).getTime() - new Date(a.check_in_at).getTime()) / 3_600_000
    if (!Number.isFinite(hours) || hours <= 0) continue
    dutyHours.set(a.technician_id, (dutyHours.get(a.technician_id) ?? 0) + hours)
  }
  for (const [techId, hours] of dutyHours) {
    const row = byTech.get(techId)
    if (row) row.productivityJobsPerHour = hours > 0 ? Math.round((row.jobsDone / hours) * 100) / 100 : null
  }

  void ticketsRes // ticket-level 24h-resolution KPI surfaced via getOpsResolutionKpi below
  return [...byTech.values()].sort((a, b) => b.revenue - a.revenue)
}

/** Operation-admin KPI: % of tickets in range resolved (completed) within 24h of creation. */
export async function getOpsResolutionKpi(orgId: string, range: DateRange): Promise<{ resolvedWithin24h: number; totalCompleted: number; percent: number | null }> {
  const { fromIso, toIso } = rangeToTimestamps(range)
  const { data, error } = await supabase
    .from("service_tickets")
    .select("id, status, created_at, updated_at")
    .eq("org_id", orgId)
    .eq("status", "completed")
    .gte("created_at", fromIso)
    .lte("created_at", toIso)
  if (error) throw error

  const rows = data ?? []
  const within24h = rows.filter((r) => {
    const created = new Date(r.created_at).getTime()
    const updated = new Date(r.updated_at).getTime()
    return updated - created <= 24 * 3_600_000
  }).length

  return {
    resolvedWithin24h: within24h,
    totalCompleted: rows.length,
    percent: rows.length ? Math.round((within24h / rows.length) * 1000) / 10 : null,
  }
}

// ── ADM-36 NPS / Feedback report ─────────────────────────────────────────
// The low-rating "reason" is NOT a column on `ratings` — see
// supabase/migrations/20260702120000_technician_phase7_functions.sql's
// submit_rating(): below settings.review_link_min_stars it inserts a
// `notifications` row (role='operation_admin', type='low_rating') whose
// `body` is a formatted "A %s-star rating was recorded. Reason: %s" string
// and whose `ref_id` points at the rating id. This report joins ratings to
// that notification (by ref_id) to recover the reason text.
export type FeedbackReport = {
  starsDistribution: { stars: number; count: number }[]
  averageRating: number | null
  trend: { date: string; averageRating: number }[]
  lowRatingEntries: { ratingId: string; stars: number; review: string | null; reason: string | null; createdAt: string; customerName: string | null; technicianName: string | null }[]
}

export async function getFeedbackReport(orgId: string, range: DateRange): Promise<FeedbackReport> {
  const { fromIso, toIso } = rangeToTimestamps(range)

  const { data: ratingsData, error: ratingsError } = await supabase
    .from("ratings")
    .select(
      "id, stars, review, created_at, visit_id, service_visits!inner(org_id, timer_start, technician_id, technicians(profiles(full_name)), service_tickets(customer_id, customers(name)))"
    )
    .eq("service_visits.org_id", orgId)
    .gte("created_at", fromIso)
    .lte("created_at", toIso)
    .order("created_at", { ascending: true })
  if (ratingsError) throw ratingsError

  type RatingJoinRow = {
    id: string
    stars: number
    review: string | null
    created_at: string
    service_visits: {
      technicians: { profiles: { full_name: string } | null } | null
      service_tickets: { customers: { name: string } | null } | null
    } | null
  }
  const ratings = (ratingsData ?? []) as unknown as RatingJoinRow[]

  const distMap = new Map<number, number>()
  for (const r of ratings) {
    const bucket = Math.round(r.stars)
    distMap.set(bucket, (distMap.get(bucket) ?? 0) + 1)
  }
  const starsDistribution = [1, 2, 3, 4, 5].map((stars) => ({ stars, count: distMap.get(stars) ?? 0 }))

  const averageRating = ratings.length ? Math.round((ratings.reduce((s, r) => s + r.stars, 0) / ratings.length) * 100) / 100 : null

  // Trend: average rating per day.
  const byDay = new Map<string, { sum: number; count: number }>()
  for (const r of ratings) {
    const day = r.created_at.slice(0, 10)
    const a = byDay.get(day) ?? { sum: 0, count: 0 }
    a.sum += r.stars
    a.count += 1
    byDay.set(day, a)
  }
  const trend = [...byDay.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([date, a]) => ({ date, averageRating: Math.round((a.sum / a.count) * 100) / 100 }))

  const lowRatings = ratings.filter((r) => r.stars < 4.5)
  let reasonByRatingId = new Map<string, string>()
  if (lowRatings.length) {
    const ids = lowRatings.map((r) => r.id)
    const { data: notifData, error: notifError } = await supabase
      .from("notifications")
      .select("ref_id, body")
      .eq("org_id", orgId)
      .eq("type", "low_rating")
      .in("ref_id", ids)
    if (notifError) throw notifError
    reasonByRatingId = new Map((notifData ?? []).map((n) => [n.ref_id as string, n.body ?? ""]))
  }

  const lowRatingEntries = lowRatings.map((r) => {
    const rawBody = reasonByRatingId.get(r.id) ?? null
    // Extract just the "Reason: ..." tail of the formatted notification body.
    const reasonMatch = rawBody?.match(/Reason:\s*(.*)$/)
    return {
      ratingId: r.id,
      stars: r.stars,
      review: r.review,
      reason: reasonMatch ? reasonMatch[1] : rawBody,
      createdAt: r.created_at,
      customerName: r.service_visits?.service_tickets?.customers?.name ?? null,
      technicianName: r.service_visits?.technicians?.profiles?.full_name ?? null,
    }
  })

  return { starsDistribution, averageRating, trend, lowRatingEntries }
}

// ── Log Expense (ADM-28 gap fix) ─────────────────────────────────────────
// The only pre-existing write path into `expenses` was create_bill_entry(),
// which always hardcodes category='purchase' (20260702170400_bill_entry_fix
// .sql). This is the missing UI/service entry point for the other 5
// categories. RLS (expenses_write_ops, 20260701091300_rls.sql) already lets
// ops staff (master/operation_admin) insert — no schema or policy change
// needed. `expenses` has no free-text note/description column (only
// id/org_id/category/amount/ref_id/date/created_at/updated_at — see
// 20260701091000_hr_finance.sql), so this input intentionally has no note
// field; ref_id is left unset (nullable, used elsewhere to link an expense
// back to its originating record, e.g. a purchase bill — there's nothing to
// link a manually-logged expense to).
export type CreateExpenseInput = {
  orgId: string
  category: Enums<"expense_category">
  amount: number
  date: string
}

export async function createExpense(input: CreateExpenseInput) {
  const { data, error } = await supabase
    .from("expenses")
    .insert({ org_id: input.orgId, category: input.category, amount: input.amount, date: input.date })
    .select()
    .single()
  if (error) throw error
  return data
}

// ── CSV export (no xlsx/exceljs dependency exists in package.json — plain
// string-blob download instead, per the "don't add a new dependency" rule) ──
export function toCsv(headers: string[], rows: (string | number | null)[][]): string {
  const escape = (v: string | number | null) => {
    const s = v === null || v === undefined ? "" : String(v)
    return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s
  }
  return [headers.map(escape).join(","), ...rows.map((r) => r.map(escape).join(","))].join("\n")
}

export function downloadCsv(filename: string, csv: string) {
  const blob = new Blob([csv], { type: "text/csv;charset=utf-8;" })
  const url = URL.createObjectURL(blob)
  const a = document.createElement("a")
  a.href = url
  a.download = filename
  document.body.appendChild(a)
  a.click()
  document.body.removeChild(a)
  URL.revokeObjectURL(url)
}
