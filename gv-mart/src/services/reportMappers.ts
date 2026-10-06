// Pure mappers from the jsonb the report_* SQL functions return (snake_case, see migrations
// 20261009100000 / 110000 / 120000) to the camelCase types the report screens already use.
// No supabase import on purpose: these are unit-tested in plain Node.
import type { Enums } from "@/types/database"
import type {
  FeedbackReport,
  PerformanceRow,
  PnlReport,
  SalesServiceReport,
  StaffSalaryTotal,
  TopCustomerRow,
  YearTotals,
} from "@/services/reports"
import type { CoverageReport, CustomerTotals, ProductSalesRow } from "@/services/reportsInsights"

const num = (v: unknown): number => (v == null ? 0 : Number(v))
const numOrNull = (v: unknown): number | null => (v == null ? null : Number(v))
const round2 = (n: number) => Math.round(n * 100) / 100

// ── report_sales_service ─────────────────────────────────────────────────
type ClassRpc = { count: number; qty: number; total: number; gst: number; net: number; collected: number }
export type SalesServiceRpc = {
  by_class: { sales: ClassRpc; service: ClassRpc; amc: ClassRpc; rental: ClassRpc }
  totals: { count: number; total: number; gst: number; net: number; collected: number }
  by_invoice_type: { type: Enums<"invoice_type">; count: number; total: number }[]
  service_visits: number
  calls: number
  technicians: { technician_id: string; name: string; count: number; revenue: number }[]
  avg_value_per_service_call: number
}

export function mapSalesService(d: SalesServiceRpc): SalesServiceReport {
  const totalRevenue = num(d.totals.total)
  const invoiceCount = num(d.totals.count)
  const typeRow = (type: "sales" | "service" | "amc" | "rental") => {
    const c = d.by_class[type]
    const revenue = num(c.total)
    const count = num(c.count)
    return {
      type,
      revenue,
      collected: num(c.collected),
      count,
      qty: num(c.qty),
      avgValue: count > 0 ? round2(revenue / count) : 0,
      percent: totalRevenue > 0 ? Math.round((revenue / totalRevenue) * 1000) / 10 : 0,
    }
  }
  return {
    salesCallsCount: num(d.calls),
    invoiceTypeRatio: d.by_invoice_type.map((r) => ({
      type: r.type,
      count: num(r.count),
      total: num(r.total),
      percent: invoiceCount > 0 ? Math.round((num(r.count) / invoiceCount) * 100) : 0,
    })),
    technicianServiceCounts: d.technicians.map((t) => ({ technicianId: t.technician_id, technicianName: t.name, count: num(t.count), revenue: num(t.revenue) })),
    avgValuePerServiceCall: num(d.avg_value_per_service_call),
    salesRevenue: num(d.by_class.sales.total),
    amcRevenue: num(d.by_class.amc.total),
    rentalRevenue: num(d.by_class.rental.total),
    serviceRevenue: num(d.by_class.service.total),
    totalRevenue,
    salesCollected: num(d.by_class.sales.collected),
    amcCollected: num(d.by_class.amc.collected),
    rentalCollected: num(d.by_class.rental.collected),
    serviceCollected: num(d.by_class.service.collected),
    totalCollected: num(d.totals.collected),
    revenueByType: [typeRow("sales"), typeRow("service"), typeRow("amc"), typeRow("rental")],
    totalGst: num(d.totals.gst),
    serviceVisitCount: num(d.service_visits),
  }
}

// ── report_pnl ───────────────────────────────────────────────────────────
export type PnlRpc = {
  invoiced: { total: number; gst: number; net: number }
  collected: { total: number; gst: number; net: number }
  expenses_by_category: { category: Enums<"expense_category">; amount: number }[]
  item_profit: { revenue: number; cost: number; gifts_cost: number; missing_cost_count: number }
}

export function mapPnl(d: PnlRpc): PnlReport {
  const expensesByCategory = (d.expenses_by_category ?? []).map((e) => ({ category: e.category, amount: num(e.amount) }))
  const totalExpenses = expensesByCategory.reduce((s, e) => s + e.amount, 0)
  const revenueWithGst = num(d.invoiced.total)
  const revenueWithoutGst = num(d.invoiced.net)
  const collectedWithGst = num(d.collected.total)
  const collectedWithoutGst = num(d.collected.net)
  const ip = d.item_profit
  return {
    revenueWithGst,
    revenueWithoutGst,
    gstCollected: num(d.invoiced.gst),
    expensesByCategory,
    totalExpenses,
    netProfitWithGst: revenueWithGst - totalExpenses,
    netProfitWithoutGst: revenueWithoutGst - totalExpenses,
    revenueCollectedWithGst: collectedWithGst,
    revenueCollectedWithoutGst: collectedWithoutGst,
    netProfitCollectedWithGst: collectedWithGst - totalExpenses,
    netProfitCollectedWithoutGst: collectedWithoutGst - totalExpenses,
    itemProfit: {
      revenue: num(ip.revenue),
      cost: num(ip.cost),
      giftsCost: num(ip.gifts_cost),
      profit: num(ip.revenue) - num(ip.cost) - num(ip.gifts_cost),
      missingCostCount: num(ip.missing_cost_count),
    },
  }
}

// ── report_performance / report_ops_resolution ───────────────────────────
export type PerformanceRpcRow = {
  id: string
  name: string
  role: "technician"
  jobs_done: number
  on_time_percent: number | null
  revenue: number
  avg_rating: number | null
  review_count: number
  conversion_percent: number | null
  avg_completion_minutes: number | null
  productivity_jobs_per_hour: number | null
  installations: number
}

export function mapPerformance(rows: PerformanceRpcRow[]): PerformanceRow[] {
  return (rows ?? []).map((r) => ({
    id: r.id,
    name: r.name,
    role: r.role,
    jobsDone: num(r.jobs_done),
    onTimePercent: numOrNull(r.on_time_percent),
    revenue: num(r.revenue),
    avgRating: numOrNull(r.avg_rating),
    reviewCount: num(r.review_count),
    conversionPercent: numOrNull(r.conversion_percent),
    avgCompletionMinutes: numOrNull(r.avg_completion_minutes),
    productivityJobsPerHour: numOrNull(r.productivity_jobs_per_hour),
    installations: num(r.installations),
  }))
}

export type OpsResolutionRpc = { resolved_within_24h: number; total_completed: number; percent: number | null }
export function mapOpsResolution(d: OpsResolutionRpc) {
  return { resolvedWithin24h: num(d.resolved_within_24h), totalCompleted: num(d.total_completed), percent: numOrNull(d.percent) }
}

// ── report_feedback ──────────────────────────────────────────────────────
export type FeedbackRpc = {
  stars_distribution: { stars: number; count: number }[]
  average_rating: number | null
  trend: { date: string; average_rating: number }[]
  low_rating_entries: {
    rating_id: string
    stars: number
    review: string | null
    reason: string | null
    created_at: string
    customer_name: string | null
    technician_name: string | null
  }[]
}

export function mapFeedback(d: FeedbackRpc): FeedbackReport {
  return {
    starsDistribution: d.stars_distribution.map((s) => ({ stars: num(s.stars), count: num(s.count) })),
    averageRating: numOrNull(d.average_rating),
    trend: d.trend.map((t) => ({ date: t.date, averageRating: num(t.average_rating) })),
    lowRatingEntries: d.low_rating_entries.map((e) => ({
      ratingId: e.rating_id,
      stars: num(e.stars),
      review: e.review,
      reason: e.reason,
      createdAt: e.created_at,
      customerName: e.customer_name,
      technicianName: e.technician_name,
    })),
  }
}

// ── Accounts aggregates ──────────────────────────────────────────────────
export type SalaryByStaffRpcRow = { staff_id: string; staff_name: string; total: number }
export function mapSalaryByStaff(rows: SalaryByStaffRpcRow[]): StaffSalaryTotal[] {
  return (rows ?? []).map((r) => ({ staffId: r.staff_id, staffName: r.staff_name, total: num(r.total) }))
}

export type YearOverYearRpcRow = {
  year: number
  full_year_total: number
  ytd_comparable_total: number
  by_category: { category: Enums<"expense_category">; amount: number }[]
}
export function mapYearOverYear(rows: YearOverYearRpcRow[]): YearTotals[] {
  return (rows ?? []).map((r) => ({
    year: num(r.year),
    fullYearTotal: num(r.full_year_total),
    ytdComparableTotal: num(r.ytd_comparable_total),
    byCategory: (r.by_category ?? []).map((c) => ({ category: c.category, amount: num(c.amount) })),
  }))
}

// ── top customers / customer totals / product sales ─────────────────────
export type TopCustomerRpcRow = {
  rank: number
  customer_id: string
  name: string
  mobile: string
  profession: string | null
  area: string | null
  pincode: string | null
  invoiced_total: number
  collected_total: number
  invoice_count: number
  first_purchase_at: string
  last_purchase_at: string
}
export function mapTopCustomers(rows: TopCustomerRpcRow[]): TopCustomerRow[] {
  return (rows ?? []).map((r) => ({
    rank: num(r.rank),
    customerId: r.customer_id,
    name: r.name,
    mobile: r.mobile,
    profession: r.profession,
    area: r.area,
    pincode: r.pincode,
    invoicedTotal: num(r.invoiced_total),
    collectedTotal: num(r.collected_total),
    invoiceCount: num(r.invoice_count),
    firstPurchaseAt: r.first_purchase_at,
    lastPurchaseAt: r.last_purchase_at,
  }))
}

export type CustomerTotalsRpc = {
  total_customers: number
  new_customers: number
  buying_customers: number
  new_buyers: number
  repeat_buyers: number
  repeat_rate_percent: number | null
  avg_revenue_per_buyer: number
}
export function mapCustomerTotals(d: CustomerTotalsRpc): CustomerTotals {
  return {
    totalCustomers: num(d.total_customers),
    newCustomers: num(d.new_customers),
    buyingCustomers: num(d.buying_customers),
    newBuyers: num(d.new_buyers),
    repeatBuyers: num(d.repeat_buyers),
    repeatRatePercent: numOrNull(d.repeat_rate_percent),
    avgRevenuePerBuyer: num(d.avg_revenue_per_buyer),
  }
}

export type ProductSalesRpcRow = {
  item_type: "product" | "spare"
  item_id: string
  name: string
  category: string | null
  qty: number
  invoice_count: number
  revenue: number
  cost: number | null
  profit: number | null
  margin_percent: number | null
  share_percent: number
  avg_price: number
}
export function mapProductSales(rows: ProductSalesRpcRow[]): ProductSalesRow[] {
  return (rows ?? []).map((r) => ({
    itemType: r.item_type,
    itemId: r.item_id,
    name: r.name,
    category: r.category,
    qty: num(r.qty),
    invoiceCount: num(r.invoice_count),
    revenue: num(r.revenue),
    cost: numOrNull(r.cost),
    profit: numOrNull(r.profit),
    marginPercent: numOrNull(r.margin_percent),
    sharePercent: num(r.share_percent),
    avgPrice: num(r.avg_price),
  }))
}

// ── report_coverage ──────────────────────────────────────────────────────
export type CoverageRpc = {
  months: {
    month: string
    warranty: { visits: number; active: number }
    amc: { visits: number; active: number; plan_value: number }
    rental: { visits: number; active: number; plan_value: number }
  }[]
  truncated: boolean
  installation: {
    installs: number
    months_count: number
    technician_count: number
    per_technician_per_month: number | null
    units_sold: number
    per_product_sold: number | null
    visits: number
    per_visit: number | null
    by_technician: { technician_id: string; name: string; installs: number; per_month: number }[]
  }
}
export function mapCoverage(d: CoverageRpc): CoverageReport {
  const i = d.installation
  return {
    months: d.months.map((m) => ({
      month: m.month,
      warranty: { visits: num(m.warranty.visits), active: num(m.warranty.active) },
      amc: { visits: num(m.amc.visits), active: num(m.amc.active), planValue: num(m.amc.plan_value) },
      rental: { visits: num(m.rental.visits), active: num(m.rental.active), planValue: num(m.rental.plan_value) },
    })),
    truncated: !!d.truncated,
    installation: {
      installs: num(i.installs),
      monthsCount: num(i.months_count),
      technicianCount: num(i.technician_count),
      perTechnicianPerMonth: numOrNull(i.per_technician_per_month),
      unitsSold: num(i.units_sold),
      perProductSold: numOrNull(i.per_product_sold),
      visits: num(i.visits),
      perVisit: numOrNull(i.per_visit),
      byTechnician: i.by_technician.map((t) => ({ technicianId: t.technician_id, name: t.name, installs: num(t.installs), perMonth: num(t.per_month) })),
    },
  }
}
