import { supabase } from "@/lib/supabase"
import { minutesBetween } from "@/lib/visit-duration"
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

// ── Month/Year/Custom period filter ──────────────────────────────────────
// Owner request 2026-07-29: every dashboard/report screen was hardcoded to
// "this month"/"today"/"trailing N months" with no way to look at a past
// month or year. PeriodValue is the single value PeriodFilter.tsx produces
// and every screen consumes — mode-tagged (not just a resolved DateRange)
// because some callers (the dashboard's P&L trend chart) need to know
// *which* month/year was picked, not just its bounds, to decide how many
// bars to render. periodToRange() is the one place that collapses a
// PeriodValue down to the plain DateRange every report hook already takes —
// no query/RPC anywhere needs to change to support this.
export type PeriodMode = "month" | "year" | "range"
export type PeriodValue =
  | { mode: "month"; month: string } // "2026-07" — same shape <input type="month"> already produces (see hr/SalaryTab.tsx)
  | { mode: "year"; year: number }
  | { mode: "range"; range: DateRange }

export function periodToRange(value: PeriodValue): DateRange {
  if (value.mode === "range") return value.range
  if (value.mode === "year") {
    return { from: `${value.year}-01-01`, to: `${value.year}-12-31` }
  }
  // "month" — last day of the month via day 0 of the next month, same trick dateRangeForPreset uses.
  const [y, m] = value.month.split("-").map(Number)
  const from = new Date(y, m - 1, 1)
  const to = new Date(y, m, 0)
  const toStr = (d: Date) => d.toISOString().slice(0, 10)
  return { from: toStr(from), to: toStr(to) }
}

export function defaultPeriodValue(): PeriodValue {
  const now = new Date()
  return { mode: "month", month: now.toISOString().slice(0, 7) }
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
  /** Revenue KPIs, kept separate per the 2026-09-24 Accounts change request
   * (item 3) rather than folded into one figure — Sales (product+spare
   * invoices), AMC (amc invoices), Rental (rent invoices), and Service
   * (service_visits.service_charge, which is NOT an invoice at all — there
   * is no invoice_type for it). `totalRevenue` is the honest sum of all
   * four; before this change it silently excluded serviceRevenue since it
   * only summed invoices.
   *
   * `create_service_invoice` always writes its invoice as type='spare' (the
   * schema has no separate invoice_type for a service call), and that
   * invoice's total already includes the service charge. So salesRevenue —
   * which used to sum every type='spare' invoice — double-counted every
   * service visit's charge (once here, once in serviceRevenue) until the
   * 2026-09-25 money-flow-audit item-1 fix below, which excludes
   * service-visit-originated invoices from the sales bucket via
   * service_tickets.invoice_id. */
  salesRevenue: number
  amcRevenue: number
  rentalRevenue: number
  serviceRevenue: number
  totalRevenue: number
  /** "Collected" mirrors of the five figures above — sum of invoices.amount_paid
   * (money-flow-audit item 1: invoiced totals hide how much is actually
   * collected vs. still due/partial). serviceCollected is prorated per visit
   * by its invoice's amount_paid/total ratio, since a service invoice can
   * bundle the service charge together with chargeable spares under one
   * amount_paid figure — there's no itemized "this rupee paid off the
   * service charge" breakdown to read instead. */
  salesCollected: number
  amcCollected: number
  rentalCollected: number
  serviceCollected: number
  totalCollected: number
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
      .select("id, type, total, amount_paid, created_at")
      .eq("org_id", orgId)
      .gte("created_at", fromIso)
      .lte("created_at", toIso),
    supabase
      .from("service_visits")
      .select("id, ticket_id, technician_id, service_charge, timer_start, technicians(id, profiles(full_name))")
      .eq("org_id", orgId)
      .gte("timer_start", fromIso)
      .lte("timer_start", toIso),
  ])
  if (callsRes.error) throw callsRes.error
  if (invoicesRes.error) throw invoicesRes.error
  if (visitsRes.error) throw visitsRes.error

  const invoices = invoicesRes.data ?? []

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

  type VisitRow = {
    id: string
    ticket_id: string
    technician_id: string
    service_charge: number | null
    technicians: { id: string; profiles: { full_name: string } | null } | null
  }
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

  const avgValuePerServiceCall = visits.length
    ? Math.round((visits.reduce((sum, v) => sum + (v.service_charge ?? 0), 0) / visits.length) * 100) / 100
    : 0

  // Which invoices belong to a service visit (type='spare' always, per
  // create_service_invoice) — looked up via service_tickets.invoice_id so
  // they can be excluded from the sales bucket below instead of
  // double-counted, and so their amount_paid/total can be read for
  // serviceCollected's proration.
  const visitTicketIds = [...new Set(visits.map((v) => v.ticket_id))]
  const ticketInvoiceMap = new Map<string, string>()
  if (visitTicketIds.length) {
    const { data: ticketRows, error: ticketErr } = await supabase
      .from("service_tickets")
      .select("id, invoice_id")
      .eq("org_id", orgId)
      .in("id", visitTicketIds)
    if (ticketErr) throw ticketErr
    for (const t of ticketRows ?? []) {
      if (t.invoice_id) ticketInvoiceMap.set(t.id, t.invoice_id)
    }
  }
  const serviceInvoiceIds = new Set(ticketInvoiceMap.values())
  const invoiceById = new Map(invoices.map((inv) => [inv.id, inv]))

  let salesRevenue = 0
  let salesCollected = 0
  for (const inv of invoices) {
    if (inv.type === "product" || (inv.type === "spare" && !serviceInvoiceIds.has(inv.id))) {
      salesRevenue += inv.total ?? 0
      salesCollected += inv.amount_paid ?? 0
    }
  }
  const amcRevenue = ratioMap.get("amc")?.total ?? 0
  const amcCollected = invoices.filter((i) => i.type === "amc").reduce((sum, i) => sum + (i.amount_paid ?? 0), 0)
  const rentalRevenue = ratioMap.get("rent")?.total ?? 0
  const rentalCollected = invoices.filter((i) => i.type === "rent").reduce((sum, i) => sum + (i.amount_paid ?? 0), 0)

  let serviceRevenue = 0
  let serviceCollected = 0
  for (const v of visits) {
    const charge = v.service_charge ?? 0
    serviceRevenue += charge
    const invoiceId = ticketInvoiceMap.get(v.ticket_id)
    const inv = invoiceId ? invoiceById.get(invoiceId) : undefined
    // Some service-visit invoices may fall outside this range's created_at
    // window even though the visit's timer_start is inside it (rare — same
    // transaction sets both — but not guaranteed if a shift crosses
    // midnight right at a range boundary). Treat those as fully collected
    // rather than silently dropping them, same as an invoice with total<=0.
    serviceCollected += !inv || inv.total <= 0 ? charge : charge * ((inv.amount_paid ?? 0) / inv.total)
  }

  // Honest total — previously only summed invoices, silently excluding
  // serviceRevenue (service_visits.service_charge has no invoice_type at
  // all, see the type doc comment above).
  const totalRevenue = salesRevenue + amcRevenue + rentalRevenue + serviceRevenue
  const totalCollected = salesCollected + amcCollected + rentalCollected + serviceCollected

  return {
    salesCallsCount: callsRes.count ?? 0,
    invoiceTypeRatio,
    technicianServiceCounts,
    avgValuePerServiceCall,
    salesRevenue,
    amcRevenue,
    rentalRevenue,
    serviceRevenue,
    totalRevenue,
    salesCollected,
    amcCollected,
    rentalCollected,
    serviceCollected,
    totalCollected,
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
  /** money-flow-audit item 1 — revenueWithGst/WithoutGst above are invoiced
   * totals regardless of payment_status; these are the "actually collected"
   * counterparts (sum of invoices.amount_paid, GST portion prorated by each
   * invoice's own gst/total ratio) and the cash-basis profit built from
   * them. netProfitCollected is the more accurate real cash position —
   * netProfitWithGst/WithoutGst above still count invoiced-but-unpaid
   * revenue as profit. */
  revenueCollectedWithGst: number
  revenueCollectedWithoutGst: number
  netProfitCollectedWithGst: number
  netProfitCollectedWithoutGst: number
  /** Cost/margin tracking (stage 1) — real profit matched to what was
   *  actually sold/consumed, distinct from the cash-basis costOfGoods above
   *  (which just reads the 'purchase' expense category). Sourced from
   *  invoice_items.cost (covers product/spare sales AND spares consumed on
   *  a service visit, chargeable or free — see create_service_invoice) and
   *  gift_logs.cost (gifts given away: pure cost, no revenue). Both are
   *  snapshots taken at the moment of sale/consumption/handover, so this
   *  never drifts when an item's cost_price changes later. Lines with no
   *  cost_price set yet are excluded from `profit` and counted in
   *  `missingCostCount` — never treated as zero cost. */
  itemProfit: {
    revenue: number
    cost: number
    giftsCost: number
    profit: number
    missingCostCount: number
  }
}

export async function getPnlReport(orgId: string, range: DateRange): Promise<PnlReport> {
  const { fromIso, toIso } = rangeToTimestamps(range)

  const [invoicesRes, expensesRes, invoiceItemsRes, giftLogsRes] = await Promise.all([
    supabase
      .from("invoices")
      .select("total, subtotal, discount, gst, amount_paid, created_at")
      .eq("org_id", orgId)
      .gte("created_at", fromIso)
      .lte("created_at", toIso),
    supabase
      .from("expenses")
      .select("category, amount, date")
      .eq("org_id", orgId)
      .gte("date", range.from)
      .lte("date", range.to),
    supabase
      .from("invoice_items")
      .select("qty, price, discount, cost")
      .eq("org_id", orgId)
      .gte("created_at", fromIso)
      .lte("created_at", toIso),
    supabase
      .from("gift_logs")
      .select("cost")
      .eq("org_id", orgId)
      .gte("created_at", fromIso)
      .lte("created_at", toIso),
  ])
  if (invoicesRes.error) throw invoicesRes.error
  // expenses is master-only under RLS (expenses_select_master) — a non-master
  // caller gets an empty result set here, not an error; the P&L tab handles
  // that by showing zeros rather than crashing (RLS denies rows silently).
  if (expensesRes.error) throw expensesRes.error
  if (invoiceItemsRes.error) throw invoiceItemsRes.error
  if (giftLogsRes.error) throw giftLogsRes.error

  const invoices = invoicesRes.data ?? []
  const revenueWithGst = invoices.reduce((sum, i) => sum + (i.total ?? 0), 0)
  const gstCollected = invoices.reduce((sum, i) => sum + (i.gst ?? 0), 0)
  const revenueWithoutGst = revenueWithGst - gstCollected

  // Collected (cash-basis) counterparts — amount_paid summed directly, GST
  // portion of it prorated per invoice by that invoice's own gst/total
  // ratio (an invoice with total<=0 has nothing to prorate).
  const revenueCollectedWithGst = invoices.reduce((sum, i) => sum + (i.amount_paid ?? 0), 0)
  const gstCollectedOfPayments = invoices.reduce(
    (sum, i) => sum + (i.total > 0 ? (i.amount_paid ?? 0) * ((i.gst ?? 0) / i.total) : 0),
    0
  )
  const revenueCollectedWithoutGst = revenueCollectedWithGst - gstCollectedOfPayments

  const expenseMap = new Map<Enums<"expense_category">, number>()
  for (const e of expensesRes.data ?? []) {
    expenseMap.set(e.category, (expenseMap.get(e.category) ?? 0) + (e.amount ?? 0))
  }
  const expensesByCategory = [...expenseMap.entries()].map(([category, amount]) => ({ category, amount }))
  const totalExpenses = expensesByCategory.reduce((sum, e) => sum + e.amount, 0)

  const items = invoiceItemsRes.data ?? []
  const itemsWithCost = items.filter((i) => i.cost != null)
  const itemRevenue = itemsWithCost.reduce((sum, i) => sum + (i.qty * i.price - i.discount), 0)
  const itemCost = itemsWithCost.reduce((sum, i) => sum + i.qty * (i.cost ?? 0), 0)

  const gifts = giftLogsRes.data ?? []
  const giftsCost = gifts.filter((g) => g.cost != null).reduce((sum, g) => sum + (g.cost ?? 0), 0)

  const missingCostCount = items.length - itemsWithCost.length + gifts.filter((g) => g.cost == null).length

  return {
    revenueWithGst,
    revenueWithoutGst,
    gstCollected,
    expensesByCategory,
    totalExpenses,
    netProfitWithGst: revenueWithGst - totalExpenses,
    netProfitWithoutGst: revenueWithoutGst - totalExpenses,
    revenueCollectedWithGst,
    revenueCollectedWithoutGst,
    netProfitCollectedWithGst: revenueCollectedWithGst - totalExpenses,
    netProfitCollectedWithoutGst: revenueCollectedWithoutGst - totalExpenses,
    itemProfit: {
      revenue: itemRevenue,
      cost: itemCost,
      giftsCost,
      profit: itemRevenue - itemCost - giftsCost,
      missingCostCount,
    },
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

// ── Log Expense (ADM-28 gap fix; extended 2026-09-24 for the Accounts /
// money-out expense-tracking change request — see
// 20260924120000_expense_tracking_change_request.sql) ────────────────────
// The only pre-existing write path into `expenses` was create_bill_entry(),
// which always hardcodes category='purchase' (20260702170400_bill_entry_fix
// .sql). This is the missing UI/service entry point for the other
// categories, now including 'rent'/'electricity' and the optional
// note/recurring-task-link/logged-by columns added in the change request
// above. RLS (expenses_write_ops, 20260701091300_rls.sql) already lets ops
// staff (master/operation_admin) insert — no policy change needed. `note`
// and `recurringTaskId` are both optional: an unplanned expense (emergency
// repair, surprise purchase) is logged exactly the same way as a routine
// one, with no task link required.
export type CreateExpenseInput = {
  orgId: string
  category: Enums<"expense_category">
  amount: number
  date: string
  note?: string | null
  recurringTaskId?: string | null
  loggedBy?: string | null
  /** Item 1 of the 2026-09-24 change request — identifies the staff member
   * (any role, via `profiles.id`) a category='salary' expense belongs to.
   * Both the technician-payroll path (SalaryTab's "Log to Accounts") and
   * the manual non-technician staff-salary path write here, so salary
   * spend is one combined figure with per-person drill-down. Unset for
   * every other category. */
  staffId?: string | null
}

export async function createExpense(input: CreateExpenseInput) {
  const { data, error } = await supabase
    .from("expenses")
    .insert({
      org_id: input.orgId,
      category: input.category,
      amount: input.amount,
      date: input.date,
      note: input.note ?? null,
      recurring_task_id: input.recurringTaskId ?? null,
      is_recurring: !!input.recurringTaskId,
      logged_by: input.loggedBy ?? null,
      staff_id: input.staffId ?? null,
    })
    .select()
    .single()
  if (error) throw error
  return data
}

// ── Expenses / Accounts dashboard (2026-09-24 change request) ────────────
export type ExpenseEntry = {
  id: string
  category: Enums<"expense_category">
  amount: number
  date: string
  note: string | null
  isRecurring: boolean
  recurringTaskId: string | null
  loggedByName: string | null
  staffId: string | null
  staffName: string | null
  createdAt: string
}

export async function getExpensesList(orgId: string, range: DateRange): Promise<ExpenseEntry[]> {
  const { data, error } = await supabase
    .from("expenses")
    .select(
      "id, category, amount, date, note, is_recurring, recurring_task_id, created_at, staff_id, logged_by_profile:profiles!expenses_logged_by_fkey(full_name), staff:profiles!expenses_staff_id_fkey(full_name)"
    )
    .eq("org_id", orgId)
    .gte("date", range.from)
    .lte("date", range.to)
    .order("date", { ascending: false })
  if (error) throw error
  return (data ?? []).map((e) => ({
    id: e.id,
    category: e.category,
    amount: e.amount,
    date: e.date,
    note: e.note,
    isRecurring: e.is_recurring,
    recurringTaskId: e.recurring_task_id,
    loggedByName: (e.logged_by_profile as { full_name: string } | null)?.full_name ?? null,
    staffId: e.staff_id,
    staffName: (e.staff as { full_name: string } | null)?.full_name ?? null,
    createdAt: e.created_at,
  }))
}

/** Open (not-yet-linked) recurring tasks, for the Log Expense form's
 * "link to task" picker — deliberately optional (see createExpense above),
 * this just surfaces candidates, it never requires a link. */
export async function getOpenRecurringTasks(orgId: string) {
  const { data, error } = await supabase
    .from("tasks")
    .select("id, title, due_date")
    .eq("org_id", orgId)
    .eq("is_recurring", true)
    .eq("status", "open")
    .order("due_date", { ascending: true })
  if (error) throw error
  return data ?? []
}

/** Salary spend grouped by staff member (item 1 drill-down) — sums every
 * category='salary' expense row for the period regardless of which path
 * wrote it (technician "Log to Accounts" or manual staff entry). */
export type StaffSalaryTotal = { staffId: string; staffName: string; total: number }

export async function getSalarySpendByStaff(orgId: string, range: DateRange): Promise<StaffSalaryTotal[]> {
  const { data, error } = await supabase
    .from("expenses")
    .select("amount, staff_id, staff:profiles!expenses_staff_id_fkey(full_name)")
    .eq("org_id", orgId)
    .eq("category", "salary")
    .not("staff_id", "is", null)
    .gte("date", range.from)
    .lte("date", range.to)
  if (error) throw error
  const byStaff = new Map<string, StaffSalaryTotal>()
  for (const row of data ?? []) {
    if (!row.staff_id) continue
    const name = (row.staff as { full_name: string } | null)?.full_name ?? "—"
    const existing = byStaff.get(row.staff_id) ?? { staffId: row.staff_id, staffName: name, total: 0 }
    existing.total += row.amount
    byStaff.set(row.staff_id, existing)
  }
  return [...byStaff.values()].sort((a, b) => b.total - a.total)
}

export type YearTotals = {
  year: number
  fullYearTotal: number
  /** Sum restricted to Jan 1 → the same calendar day-of-year as "today" in
   * the current year, so a partial current year compares fairly against
   * complete past years (see reports.pnl-adjacent Accounts dashboard spec,
   * 2026-09-24). Equal to fullYearTotal for any fully-elapsed past year. */
  ytdComparableTotal: number
  byCategory: { category: Enums<"expense_category">; amount: number }[]
}

export async function getExpensesYearOverYear(orgId: string, yearsBack = 3): Promise<YearTotals[]> {
  const now = new Date()
  const currentYear = now.getUTCFullYear()
  const dayOfYear = Math.ceil((now.getTime() - Date.UTC(currentYear, 0, 1)) / 86_400_000) + 1
  const earliestYear = currentYear - yearsBack

  const { data, error } = await supabase
    .from("expenses")
    .select("category, amount, date")
    .eq("org_id", orgId)
    .gte("date", `${earliestYear}-01-01`)
  if (error) throw error

  const years = new Map<number, { full: number; ytd: number; byCategory: Map<Enums<"expense_category">, number> }>()
  for (const row of data ?? []) {
    const d = new Date(`${row.date}T00:00:00Z`)
    const year = d.getUTCFullYear()
    const rowDayOfYear = Math.ceil((d.getTime() - Date.UTC(year, 0, 1)) / 86_400_000) + 1
    const entry = years.get(year) ?? { full: 0, ytd: 0, byCategory: new Map() }
    entry.full += row.amount
    if (rowDayOfYear <= dayOfYear) entry.ytd += row.amount
    entry.byCategory.set(row.category, (entry.byCategory.get(row.category) ?? 0) + row.amount)
    years.set(year, entry)
  }

  const result: YearTotals[] = []
  for (let year = currentYear; year >= earliestYear; year--) {
    const entry = years.get(year) ?? { full: 0, ytd: 0, byCategory: new Map() }
    result.push({
      year,
      fullYearTotal: entry.full,
      ytdComparableTotal: entry.ytd,
      byCategory: [...entry.byCategory.entries()].map(([category, amount]) => ({ category, amount })),
    })
  }
  return result
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
