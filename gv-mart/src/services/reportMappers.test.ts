import { describe, expect, it } from "vitest"
import {
  mapCoverage,
  mapCustomerTotals,
  mapFeedback,
  mapOpsResolution,
  mapPerformance,
  mapPnl,
  mapProductSales,
  mapSalaryByStaff,
  mapSalesService,
  mapTopCustomers,
  mapYearOverYear,
  type SalesServiceRpc,
} from "./reportMappers"

// The RPC documents below are the exact shapes the SQL functions returned for the hand-written October
// 2026 dataset (see supabase/tests/reports_sql_aggregation_*.test.sql).
const salesServiceRpc: SalesServiceRpc = {
  by_class: {
    sales: { count: 5, qty: 7, total: 18644, gst: 2844, net: 15800, collected: 14744 },
    service: { count: 2, qty: 2, total: 1062, gst: 162, net: 900, collected: 1062 },
    amc: { count: 1, qty: 1, total: 2360, gst: 360, net: 2000, collected: 2360 },
    rental: { count: 1, qty: 1, total: 590, gst: 90, net: 500, collected: 590 },
  },
  totals: { count: 9, total: 22656, gst: 3456, net: 19200, collected: 18756 },
  by_invoice_type: [
    { type: "product", count: 4, total: 17464 },
    { type: "spare", count: 3, total: 2242 },
    { type: "amc", count: 1, total: 2360 },
    { type: "rent", count: 1, total: 590 },
  ],
  service_visits: 3,
  calls: 2,
  technicians: [
    { technician_id: "t1", name: "Tech One", count: 2, revenue: 800 },
    { technician_id: "t2", name: "Tech Two", count: 1, revenue: 0 },
  ],
  avg_value_per_service_call: 531,
}

describe("mapSalesService", () => {
  const r = mapSalesService(salesServiceRpc)

  it("maps the class totals and collected figures", () => {
    expect(r.salesRevenue).toBe(18644)
    expect(r.serviceRevenue).toBe(1062)
    expect(r.amcRevenue).toBe(2360)
    expect(r.rentalRevenue).toBe(590)
    expect(r.totalRevenue).toBe(22656)
    expect(r.salesCollected).toBe(14744)
    expect(r.serviceCollected).toBe(1062)
    expect(r.totalCollected).toBe(18756)
  })

  it("keeps the revenue tiles GST-inclusive and exposes GST and visits separately", () => {
    expect(r.totalGst).toBe(3456)
    expect(r.serviceVisitCount).toBe(3)
    expect(r.salesRevenue + r.serviceRevenue + r.amcRevenue + r.rentalRevenue).toBe(r.totalRevenue)
  })

  it("builds revenueByType rows in a fixed order with count, qty, average and share", () => {
    expect(r.revenueByType.map((x) => x.type)).toEqual(["sales", "service", "amc", "rental"])
    const service = r.revenueByType[1]
    expect(service).toMatchObject({ revenue: 1062, collected: 1062, count: 2, qty: 2, avgValue: 531 })
    expect(service.percent).toBe(4.7) // 1,062 / 22,656
    expect(r.revenueByType[0].qty).toBe(7)
  })

  it("derives invoice-type percentages from the invoice count and maps technicians and calls", () => {
    expect(r.invoiceTypeRatio).toEqual([
      { type: "product", count: 4, total: 17464, percent: 44 },
      { type: "spare", count: 3, total: 2242, percent: 33 },
      { type: "amc", count: 1, total: 2360, percent: 11 },
      { type: "rent", count: 1, total: 590, percent: 11 },
    ])
    expect(r.technicianServiceCounts[0]).toEqual({ technicianId: "t1", technicianName: "Tech One", count: 2, revenue: 800 })
    expect(r.salesCallsCount).toBe(2)
    expect(r.avgValuePerServiceCall).toBe(531)
  })

  it("handles an empty period without NaN", () => {
    const zero = { count: 0, qty: 0, total: 0, gst: 0, net: 0, collected: 0 }
    const e = mapSalesService({ by_class: { sales: zero, service: zero, amc: zero, rental: zero }, totals: { count: 0, total: 0, gst: 0, net: 0, collected: 0 }, by_invoice_type: [], service_visits: 0, calls: 0, technicians: [], avg_value_per_service_call: 0 })
    expect(e.revenueByType.every((x) => x.avgValue === 0 && x.percent === 0)).toBe(true)
    expect(e.invoiceTypeRatio).toEqual([])
    expect(e.totalRevenue).toBe(0)
  })

  it("tolerates numeric strings and nulls from the wire", () => {
    const e = mapSalesService({ ...salesServiceRpc, calls: null as unknown as number, avg_value_per_service_call: "12.5" as unknown as number })
    expect(e.salesCallsCount).toBe(0)
    expect(e.avgValuePerServiceCall).toBe(12.5)
  })
})

describe("mapPnl", () => {
  const rpc = {
    invoiced: { total: 22656, gst: 3456, net: 19200 },
    collected: { total: 18756, gst: 2861.08, net: 15894.92 },
    expenses_by_category: [
      { category: "salary" as const, amount: 25000 },
      { category: "rent" as const, amount: 10000 },
    ],
    item_profit: { revenue: 15950, cost: 10600, gifts_cost: 150, missing_cost_count: 1 },
  }

  it("maps revenue, GST, collected and derives profit lines", () => {
    const r = mapPnl(rpc)
    expect(r.revenueWithGst).toBe(22656)
    expect(r.gstCollected).toBe(3456)
    expect(r.revenueWithoutGst).toBe(19200)
    expect(r.totalExpenses).toBe(35000)
    expect(r.netProfitWithGst).toBe(22656 - 35000)
    expect(r.netProfitCollectedWithoutGst).toBeCloseTo(15894.92 - 35000, 2)
    expect(r.itemProfit).toEqual({ revenue: 15950, cost: 10600, giftsCost: 150, profit: 5200, missingCostCount: 1 })
  })

  it("a non-master gets no expense rows: zero expenses, profit equals revenue", () => {
    const r = mapPnl({ ...rpc, expenses_by_category: [] })
    expect(r.expensesByCategory).toEqual([])
    expect(r.totalExpenses).toBe(0)
    expect(r.netProfitWithGst).toBe(22656)
  })

  it("treats a missing expenses array as empty", () => {
    expect(mapPnl({ ...rpc, expenses_by_category: undefined as never }).totalExpenses).toBe(0)
  })
})

describe("mapPerformance / mapOpsResolution", () => {
  it("maps rows and keeps nulls as null (never 0)", () => {
    const rows = mapPerformance([
      { id: "a", name: "Tech One", role: "technician", jobs_done: 3, on_time_percent: 66.7, revenue: 800, avg_rating: 4.5, review_count: 2, conversion_percent: 50, avg_completion_minutes: 60, productivity_jobs_per_hour: 0.19, installations: 2 },
      { id: "c", name: "Lead Only", role: "technician", jobs_done: 0, on_time_percent: null, revenue: 0, avg_rating: null, review_count: 0, conversion_percent: 33.3, avg_completion_minutes: null, productivity_jobs_per_hour: null, installations: 0 },
    ])
    expect(rows[0]).toEqual({ id: "a", name: "Tech One", role: "technician", jobsDone: 3, onTimePercent: 66.7, revenue: 800, avgRating: 4.5, reviewCount: 2, conversionPercent: 50, avgCompletionMinutes: 60, productivityJobsPerHour: 0.19, installations: 2 })
    expect(rows[1].name).toBe("Lead Only")
    expect(rows[1].onTimePercent).toBeNull()
    expect(rows[1].avgRating).toBeNull()
    expect(rows[1].avgCompletionMinutes).toBeNull()
    expect(rows[1].productivityJobsPerHour).toBeNull()
    expect(rows[1].conversionPercent).toBe(33.3)
  })

  it("maps the 24h resolution KPI, including no completed tickets", () => {
    expect(mapOpsResolution({ resolved_within_24h: 2, total_completed: 3, percent: 66.7 })).toEqual({ resolvedWithin24h: 2, totalCompleted: 3, percent: 66.7 })
    expect(mapOpsResolution({ resolved_within_24h: 0, total_completed: 0, percent: null })).toEqual({ resolvedWithin24h: 0, totalCompleted: 0, percent: null })
  })

  it("an empty list stays empty", () => {
    expect(mapPerformance([])).toEqual([])
    expect(mapPerformance(null as never)).toEqual([])
  })
})

describe("mapFeedback", () => {
  it("maps distribution, IST-day trend and low-rating entries with nullable fields", () => {
    const r = mapFeedback({
      stars_distribution: [1, 2, 3, 4, 5].map((stars) => ({ stars, count: stars === 5 ? 3 : 0 })),
      average_rating: 4.3,
      trend: [{ date: "2026-10-10", average_rating: 4 }],
      low_rating_entries: [{ rating_id: "r1", stars: 3, review: null, reason: "Late arrival", created_at: "2026-10-10T18:00:00+00:00", customer_name: null, technician_name: "Tech One" }],
    })
    expect(r.starsDistribution[4]).toEqual({ stars: 5, count: 3 })
    expect(r.averageRating).toBe(4.3)
    expect(r.trend).toEqual([{ date: "2026-10-10", averageRating: 4 }])
    expect(r.lowRatingEntries[0]).toEqual({ ratingId: "r1", stars: 3, review: null, reason: "Late arrival", createdAt: "2026-10-10T18:00:00+00:00", customerName: null, technicianName: "Tech One" })
  })

  it("no ratings gives a null average, not 0", () => {
    const r = mapFeedback({ stars_distribution: [], average_rating: null, trend: [], low_rating_entries: [] })
    expect(r.averageRating).toBeNull()
    expect(r.trend).toEqual([])
  })
})

describe("Accounts aggregates", () => {
  it("maps salary by staff", () => {
    expect(mapSalaryByStaff([{ staff_id: "s1", staff_name: "Staff A", total: 25000 }])).toEqual([{ staffId: "s1", staffName: "Staff A", total: 25000 }])
    expect(mapSalaryByStaff([])).toEqual([])
  })

  it("maps year over year with empty categories", () => {
    const r = mapYearOverYear([
      { year: 2026, full_year_total: 440, ytd_comparable_total: 400, by_category: [{ category: "rent", amount: 300 }] },
      { year: 2025, full_year_total: 0, ytd_comparable_total: 0, by_category: [] },
    ])
    expect(r[0]).toEqual({ year: 2026, fullYearTotal: 440, ytdComparableTotal: 400, byCategory: [{ category: "rent", amount: 300 }] })
    expect(r[1].byCategory).toEqual([])
  })
})

describe("customers, product sales, coverage", () => {
  it("maps top customers with null address fields", () => {
    const [r] = mapTopCustomers([{ rank: 1, customer_id: "c1", name: "Big", mobile: "9000000001", profession: null, area: null, pincode: null, invoiced_total: 5000, collected_total: 4500, invoice_count: 2, first_purchase_at: "2026-10-15T06:30:00+00:00", last_purchase_at: "2026-10-16T06:30:00+00:00" }])
    expect(r).toMatchObject({ rank: 1, customerId: "c1", invoicedTotal: 5000, collectedTotal: 4500, invoiceCount: 2, area: null, pincode: null, profession: null })
  })

  it("maps customer totals including a null repeat rate", () => {
    expect(mapCustomerTotals({ total_customers: 4, new_customers: 2, buying_customers: 2, new_buyers: 1, repeat_buyers: 1, repeat_rate_percent: 50, avg_revenue_per_buyer: 885 })).toEqual({ totalCustomers: 4, newCustomers: 2, buyingCustomers: 2, newBuyers: 1, repeatBuyers: 1, repeatRatePercent: 50, avgRevenuePerBuyer: 885 })
    expect(mapCustomerTotals({ total_customers: 4, new_customers: 0, buying_customers: 0, new_buyers: 0, repeat_buyers: 0, repeat_rate_percent: null, avg_revenue_per_buyer: 0 }).repeatRatePercent).toBeNull()
  })

  it("product sales: a missing cost stays null (never zero)", () => {
    const [missing, ok] = mapProductSales([
      { item_type: "product", item_id: "p1", name: "MissingCost", category: "ro", qty: 2, invoice_count: 1, revenue: 200, cost: null, profit: null, margin_percent: null, share_percent: 66.7, avg_price: 100 },
      { item_type: "spare", item_id: "s1", name: "WithCost", category: null, qty: 1, invoice_count: 1, revenue: 100, cost: 60, profit: 40, margin_percent: 40, share_percent: 33.3, avg_price: 100 },
    ])
    expect(missing).toMatchObject({ cost: null, profit: null, marginPercent: null, qty: 2, invoiceCount: 1 })
    expect(ok).toMatchObject({ itemType: "spare", cost: 60, profit: 40, marginPercent: 40, category: null })
  })

  it("coverage: maps months, truncated flag, nullable rates and technician rows", () => {
    const r = mapCoverage({
      months: [{ month: "2026-10", warranty: { visits: 2, active: 2 }, amc: { visits: 1, active: 2, plan_value: 150 }, rental: { visits: 0, active: 2, plan_value: 600 } }],
      truncated: true,
      installation: { installs: 5, months_count: 2, technician_count: 2, per_technician_per_month: 1.25, units_sold: 0, per_product_sold: null, visits: 7, per_visit: 0.71, by_technician: [{ technician_id: "t2", name: "Tech Two", installs: 3, per_month: 1.5 }] },
    })
    expect(r.months[0]).toEqual({ month: "2026-10", warranty: { visits: 2, active: 2 }, amc: { visits: 1, active: 2, planValue: 150 }, rental: { visits: 0, active: 2, planValue: 600 } })
    expect(r.truncated).toBe(true)
    expect(r.installation.perProductSold).toBeNull()
    expect(r.installation.perTechnicianPerMonth).toBe(1.25)
    expect(r.installation.byTechnician).toEqual([{ technicianId: "t2", name: "Tech Two", installs: 3, perMonth: 1.5 }])
  })
})

describe("mapSalesService by_kind (Sales & Invoices tiles)", () => {
  const withKind: SalesServiceRpc = {
    ...salesServiceRpc,
    by_kind: {
      product: { count: 2, total: 17110, gst: 2610, collected: 13210 },
      spare_counter: { count: 1, total: 1180, gst: 180, collected: 1180 },
      service: { count: 1, total: 1062, gst: 162, collected: 1062 },
      amc: { count: 1, total: 2360, gst: 360, collected: 2360 },
      rental: { count: 0, total: 0, gst: 0, collected: 0 },
    },
  }

  it("maps each kind with its average ticket (total / invoices)", () => {
    const k = mapSalesService(withKind).byKind!
    expect(k.product).toMatchObject({ count: 2, total: 17110, collected: 13210, avgTicket: 8555 })
    expect(k.spareCounter).toMatchObject({ count: 1, total: 1180, avgTicket: 1180 })
    expect(k.amc.avgTicket).toBe(2360)
  })

  it("keeps technician service invoices out of spareCounter", () => {
    const k = mapSalesService(withKind).byKind!
    expect(k.service.total).toBe(1062)
    expect(k.spareCounter.total).toBe(1180)
  })

  it("average is null (not 0, not NaN) when a kind has no invoices", () => {
    expect(mapSalesService(withKind).byKind!.rental.avgTicket).toBeNull()
  })

  it("byKind is null while the function has no by_kind key (migration not applied)", () => {
    expect(mapSalesService(salesServiceRpc).byKind).toBeNull()
  })

  it("tolerates numeric strings from the wire", () => {
    const k = mapSalesService({ ...withKind, by_kind: { product: { count: "3" as unknown as number, total: "300.50" as unknown as number, gst: 0, collected: 0 } } }).byKind!
    expect(k.product.avgTicket).toBe(100.17)
    expect(k.amc).toMatchObject({ count: 0, total: 0, avgTicket: null })
  })
})
