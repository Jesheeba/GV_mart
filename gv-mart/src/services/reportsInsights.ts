import { supabase } from "@/lib/supabase"
import type { Enums } from "@/types/database"
import { rangeToTimestamps, type DateRange } from "@/services/reports"

// Salary/Incentive system, Phase 2 — coverage, installation rates,
// product-wise sales, lead funnel, customer totals. Read-only aggregations
// over tables that already exist (no new tracking tables), same
// client-side-query style as services/reports.ts.

const MAX_MONTHS = 36

function chunk<T>(arr: T[], size: number): T[][] {
  const out: T[][] = []
  for (let i = 0; i < arr.length; i += size) out.push(arr.slice(i, i + size))
  return out
}

/** Local-time "YYYY-MM" of a timestamp or date string. */
function localMonth(value: string): string {
  const d = new Date(value)
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}`
}

/** Every "YYYY-MM" from range.from to range.to inclusive, newest MAX_MONTHS kept. */
export function monthsInRange(range: DateRange): { months: string[]; truncated: boolean } {
  const [fy, fm] = range.from.split("-").map(Number)
  const [ty, tm] = range.to.split("-").map(Number)
  const all: string[] = []
  let y = fy
  let m = fm
  while (y < ty || (y === ty && m <= tm)) {
    all.push(`${y}-${String(m).padStart(2, "0")}`)
    m += 1
    if (m > 12) {
      m = 1
      y += 1
    }
  }
  return { months: all.slice(-MAX_MONTHS), truncated: all.length > MAX_MONTHS }
}

function monthBounds(month: string) {
  const [y, m] = month.split("-").map(Number)
  const last = new Date(y, m, 0).getDate()
  return { start: `${month}-01`, end: `${month}-${String(last).padStart(2, "0")}` }
}

// ── Part D: coverage (warranty / AMC / rent) + installation rates ─────────

export type CoverageMonth = {
  month: string
  warranty: { visits: number; active: number }
  amc: { visits: number; active: number; planValue: number }
  rental: { visits: number; active: number; planValue: number }
}

export type InstallationRates = {
  installs: number
  monthsCount: number
  /** Technicians with at least one visit or installation in range. */
  technicianCount: number
  /** 1 — productivity: installs ÷ technicians ÷ months. */
  perTechnicianPerMonth: number | null
  unitsSold: number
  /** 2 — attach rate: installs ÷ product units sold (invoice_items item_type='product'). */
  perProductSold: number | null
  visits: number
  /** 3 — installs ÷ service visits. */
  perVisit: number | null
  byTechnician: { technicianId: string; name: string; installs: number; perMonth: number }[]
}

export type CoverageReport = {
  months: CoverageMonth[]
  truncated: boolean
  installation: InstallationRates
}

const round2 = (n: number) => Math.round(n * 100) / 100

export async function getCoverageReport(orgId: string, range: DateRange): Promise<CoverageReport> {
  const { fromIso, toIso } = rangeToTimestamps(range)
  const { months, truncated } = monthsInRange(range)
  // Restrict every query to the (possibly truncated) month window.
  const winFrom = months.length ? monthBounds(months[0]).start : range.from
  const winTo = months.length ? monthBounds(months[months.length - 1]).end : range.to
  const win = rangeToTimestamps({ from: winFrom, to: winTo })

  const [visitsRes, amcRes, rentalRes, warrantyRes, installsRes, soldRes] = await Promise.all([
    supabase
      .from("service_visits")
      .select("technician_id, timer_start, service_tickets!inner(type)")
      .eq("org_id", orgId)
      .gte("timer_start", win.fromIso)
      .lte("timer_start", win.toIso),
    supabase
      .from("amc_contracts")
      .select("start_date, expiry_date, amc_plans(price, price_per_year, years)")
      .eq("org_id", orgId)
      .lte("start_date", winTo)
      .gte("expiry_date", winFrom),
    supabase
      .from("rental_contracts")
      .select("start_date, returned_at, rental_plans(monthly_rate)")
      .eq("org_id", orgId)
      .lte("start_date", winTo),
    supabase.from("warranties").select("start_date, expiry_date").eq("org_id", orgId).lte("start_date", winTo).gte("expiry_date", winFrom),
    supabase
      .from("installations_logged")
      .select("technician_id, qty, technicians(id, profiles(full_name))")
      .eq("org_id", orgId)
      .gte("created_at", fromIso)
      .lte("created_at", toIso),
    supabase
      .from("invoice_items")
      .select("qty")
      .eq("org_id", orgId)
      .eq("item_type", "product")
      .gte("created_at", fromIso)
      .lte("created_at", toIso),
  ])
  for (const r of [visitsRes, amcRes, rentalRes, warrantyRes, installsRes, soldRes]) if (r.error) throw r.error

  type VisitRow = { technician_id: string; timer_start: string | null; service_tickets: { type: string | null } | null }
  const visits = (visitsRes.data ?? []) as unknown as VisitRow[]
  type AmcRow = { start_date: string; expiry_date: string; amc_plans: { price: number; price_per_year: number | null; years: number } | null }
  const amc = (amcRes.data ?? []) as unknown as AmcRow[]
  type RentalRow = { start_date: string; returned_at: string | null; rental_plans: { monthly_rate: number } | null }
  const rentals = (rentalRes.data ?? []) as unknown as RentalRow[]
  const warranties = (warrantyRes.data ?? []) as unknown as { start_date: string; expiry_date: string }[]

  const rows: CoverageMonth[] = months.map((month) => {
    const { start, end } = monthBounds(month)
    const row: CoverageMonth = {
      month,
      warranty: { visits: 0, active: 0 },
      amc: { visits: 0, active: 0, planValue: 0 },
      rental: { visits: 0, active: 0, planValue: 0 },
    }
    for (const v of visits) {
      if (!v.timer_start || localMonth(v.timer_start) !== month) continue
      const type = v.service_tickets?.type
      if (type === "warranty") row.warranty.visits += 1
      else if (type === "amc") row.amc.visits += 1
      else if (type === "rental") row.rental.visits += 1
    }
    for (const w of warranties) {
      if (w.start_date <= end && w.expiry_date >= start) row.warranty.active += 1
    }
    // Plan value for the month = each active contract's plan price spread
    // evenly across its term (price_per_year ÷ 12), regardless of whether a
    // visit that month was separately invoiced.
    for (const c of amc) {
      if (c.start_date <= end && c.expiry_date >= start && c.amc_plans) {
        row.amc.active += 1
        const yearly = c.amc_plans.price_per_year ?? c.amc_plans.price / Math.max(c.amc_plans.years, 1)
        row.amc.planValue += yearly / 12
      }
    }
    for (const c of rentals) {
      const stillOut = !c.returned_at || c.returned_at.slice(0, 10) >= start
      if (c.start_date <= end && stillOut && c.rental_plans) {
        row.rental.active += 1
        row.rental.planValue += c.rental_plans.monthly_rate
      }
    }
    row.amc.planValue = round2(row.amc.planValue)
    row.rental.planValue = round2(row.rental.planValue)
    return row
  })

  // Installation rates use the exact selected range (not the month window).
  type InstallRow = { technician_id: string; qty: number; technicians: { id: string; profiles: { full_name: string } | null } | null }
  const installRows = (installsRes.data ?? []) as unknown as InstallRow[]
  const installs = installRows.reduce((s, r) => s + (r.qty ?? 0), 0)
  const unitsSold = (soldRes.data ?? []).reduce((s, r) => s + (r.qty ?? 0), 0)
  const inRangeVisits = visits.filter((v) => v.timer_start && v.timer_start >= fromIso && v.timer_start <= toIso)
  const techIds = new Set<string>([...inRangeVisits.map((v) => v.technician_id), ...installRows.map((r) => r.technician_id)])
  const monthsCount = Math.max(1, monthsInRange(range).months.length)
  const byTech = new Map<string, { name: string; installs: number }>()
  for (const r of installRows) {
    const e = byTech.get(r.technician_id) ?? { name: r.technicians?.profiles?.full_name ?? "—", installs: 0 }
    e.installs += r.qty ?? 0
    byTech.set(r.technician_id, e)
  }

  return {
    months: rows,
    truncated,
    installation: {
      installs,
      monthsCount,
      technicianCount: techIds.size,
      perTechnicianPerMonth: techIds.size > 0 ? round2(installs / techIds.size / monthsCount) : null,
      unitsSold,
      perProductSold: unitsSold > 0 ? round2(installs / unitsSold) : null,
      visits: inRangeVisits.length,
      perVisit: inRangeVisits.length > 0 ? round2(installs / inRangeVisits.length) : null,
      byTechnician: [...byTech.entries()]
        .map(([technicianId, v]) => ({ technicianId, name: v.name, installs: v.installs, perMonth: round2(v.installs / monthsCount) }))
        .sort((a, b) => b.installs - a.installs),
    },
  }
}

// ── Part G: product-wise sales ───────────────────────────────────────────

export type ProductSalesRow = {
  itemType: "product" | "spare"
  itemId: string
  name: string
  category: string | null
  qty: number
  invoiceCount: number
  revenue: number
  /** null when any sold line has no cost snapshot — never treated as zero. */
  cost: number | null
  profit: number | null
  marginPercent: number | null
  sharePercent: number
  avgPrice: number
}

export async function getProductSalesReport(orgId: string, range: DateRange): Promise<ProductSalesRow[]> {
  const { fromIso, toIso } = rangeToTimestamps(range)
  const { data, error } = await supabase
    .from("invoice_items")
    .select("invoice_id, item_type, item_id, qty, price, discount, cost")
    .eq("org_id", orgId)
    .in("item_type", ["product", "spare"])
    .gte("created_at", fromIso)
    .lte("created_at", toIso)
  if (error) throw error

  type Agg = { itemType: "product" | "spare"; itemId: string; qty: number; revenue: number; cost: number; missingCost: boolean; invoices: Set<string> }
  const agg = new Map<string, Agg>()
  for (const it of data ?? []) {
    const type = it.item_type as "product" | "spare"
    const key = `${type}:${it.item_id}`
    const e = agg.get(key) ?? { itemType: type, itemId: it.item_id, qty: 0, revenue: 0, cost: 0, missingCost: false, invoices: new Set<string>() }
    e.qty += it.qty ?? 0
    e.revenue += (it.qty ?? 0) * (it.price ?? 0) - (it.discount ?? 0)
    if (it.cost == null) e.missingCost = true
    else e.cost += (it.qty ?? 0) * it.cost
    e.invoices.add(it.invoice_id)
    agg.set(key, e)
  }

  const productIds = [...agg.values()].filter((a) => a.itemType === "product").map((a) => a.itemId)
  const spareIds = [...agg.values()].filter((a) => a.itemType === "spare").map((a) => a.itemId)
  const names = new Map<string, { name: string; category: string | null }>()
  for (const ids of chunk(productIds, 100)) {
    const { data: ps, error: e } = await supabase.from("products").select("id, name, category").in("id", ids)
    if (e) throw e
    for (const p of ps ?? []) names.set(`product:${p.id}`, { name: p.name, category: p.category })
  }
  for (const ids of chunk(spareIds, 100)) {
    const { data: ss, error: e } = await supabase.from("spares").select("id, name").in("id", ids)
    if (e) throw e
    for (const s of ss ?? []) names.set(`spare:${s.id}`, { name: s.name, category: null })
  }

  const totalRevenue = [...agg.values()].reduce((s, a) => s + a.revenue, 0)
  return [...agg.entries()]
    .map(([key, a]) => {
      const meta = names.get(key)
      const cost = a.missingCost ? null : a.cost
      const profit = cost == null ? null : a.revenue - cost
      return {
        itemType: a.itemType,
        itemId: a.itemId,
        name: meta?.name ?? "—",
        category: meta?.category ?? null,
        qty: a.qty,
        invoiceCount: a.invoices.size,
        revenue: round2(a.revenue),
        cost: cost == null ? null : round2(cost),
        profit: profit == null ? null : round2(profit),
        marginPercent: profit != null && a.revenue > 0 ? Math.round((profit / a.revenue) * 1000) / 10 : null,
        sharePercent: totalRevenue > 0 ? Math.round((a.revenue / totalRevenue) * 1000) / 10 : 0,
        avgPrice: a.qty > 0 ? round2(a.revenue / a.qty) : 0,
      }
    })
    .sort((a, b) => b.revenue - a.revenue)
}

// ── Part G: lead-to-sale funnel ──────────────────────────────────────────

export type LeadStatus = Enums<"lead_status">

export type LeadFunnel = {
  total: number
  byStatus: Record<LeadStatus, number>
  /** Cumulative "reached at least this stage", derived from CURRENT status
   * (no stage history is stored): contacted+ = contacted/quoted/won,
   * quoted+ = quoted/won. Lost leads can't be placed at a stage, so they are
   * reported separately and excluded from the stage counts. */
  stages: { key: "created" | "contacted" | "quoted" | "won"; count: number }[]
  lost: number
  conversionPercent: number | null
  bySource: { source: string; total: number; won: number; conversionPercent: number | null }[]
}

export async function getLeadFunnel(orgId: string, range: DateRange): Promise<LeadFunnel> {
  const { fromIso, toIso } = rangeToTimestamps(range)
  const { data, error } = await supabase
    .from("leads")
    .select("status, source")
    .eq("org_id", orgId)
    .gte("created_at", fromIso)
    .lte("created_at", toIso)
  if (error) throw error
  const leads = data ?? []

  const byStatus: Record<LeadStatus, number> = { new: 0, contacted: 0, quoted: 0, won: 0, lost: 0 }
  const srcMap = new Map<string, { total: number; won: number }>()
  for (const l of leads) {
    byStatus[l.status] += 1
    const e = srcMap.get(l.source) ?? { total: 0, won: 0 }
    e.total += 1
    if (l.status === "won") e.won += 1
    srcMap.set(l.source, e)
  }
  const pct = (a: number, b: number) => (b > 0 ? Math.round((a / b) * 1000) / 10 : null)
  return {
    total: leads.length,
    byStatus,
    stages: [
      { key: "created", count: leads.length - byStatus.lost },
      { key: "contacted", count: byStatus.contacted + byStatus.quoted + byStatus.won },
      { key: "quoted", count: byStatus.quoted + byStatus.won },
      { key: "won", count: byStatus.won },
    ],
    lost: byStatus.lost,
    conversionPercent: pct(byStatus.won, leads.length),
    bySource: [...srcMap.entries()]
      .map(([source, v]) => ({ source, ...v, conversionPercent: pct(v.won, v.total) }))
      .sort((a, b) => b.total - a.total),
  }
}

// ── Part G: customer totals ──────────────────────────────────────────────

export type CustomerTotals = {
  totalCustomers: number
  newCustomers: number
  buyingCustomers: number
  /** Buyers whose first-ever invoice falls inside the range. */
  newBuyers: number
  /** Buyers who also had an invoice before the range started. */
  repeatBuyers: number
  repeatRatePercent: number | null
  avgRevenuePerBuyer: number
}

export async function getCustomerTotals(orgId: string, range: DateRange): Promise<CustomerTotals> {
  const { fromIso, toIso } = rangeToTimestamps(range)
  const [totalRes, newRes, invRes] = await Promise.all([
    supabase.from("customers").select("id", { count: "exact", head: true }).eq("org_id", orgId),
    supabase.from("customers").select("id", { count: "exact", head: true }).eq("org_id", orgId).gte("created_at", fromIso).lte("created_at", toIso),
    supabase.from("invoices").select("customer_id, total").eq("org_id", orgId).gte("created_at", fromIso).lte("created_at", toIso),
  ])
  if (totalRes.error) throw totalRes.error
  if (newRes.error) throw newRes.error
  if (invRes.error) throw invRes.error

  const revenueByCustomer = new Map<string, number>()
  for (const inv of invRes.data ?? []) {
    revenueByCustomer.set(inv.customer_id, (revenueByCustomer.get(inv.customer_id) ?? 0) + (inv.total ?? 0))
  }
  const buyerIds = [...revenueByCustomer.keys()]

  const repeat = new Set<string>()
  for (const ids of chunk(buyerIds, 100)) {
    const { data, error } = await supabase.from("invoices").select("customer_id").eq("org_id", orgId).in("customer_id", ids).lt("created_at", fromIso)
    if (error) throw error
    for (const r of data ?? []) repeat.add(r.customer_id)
  }

  const totalRevenue = [...revenueByCustomer.values()].reduce((s, v) => s + v, 0)
  return {
    totalCustomers: totalRes.count ?? 0,
    newCustomers: newRes.count ?? 0,
    buyingCustomers: buyerIds.length,
    newBuyers: buyerIds.length - repeat.size,
    repeatBuyers: repeat.size,
    repeatRatePercent: buyerIds.length > 0 ? Math.round((repeat.size / buyerIds.length) * 1000) / 10 : null,
    avgRevenuePerBuyer: buyerIds.length > 0 ? round2(totalRevenue / buyerIds.length) : 0,
  }
}
