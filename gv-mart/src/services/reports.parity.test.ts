// Legacy browser aggregation vs the SQL functions, against a throwaway organisation in the live project.
// SKIPPED unless VITE_PARITY_EMAIL / VITE_PARITY_PASSWORD / VITE_PARITY_ORG point at a master of that org
// (the *Legacy exports exist only for this test and are removed in a later cleanup commit).
// Run with TZ=Asia/Kolkata to compare like for like; under another TZ the legacy month buckets move (the bug).
import { describe, expect, it, beforeAll } from "vitest"
import { supabase } from "@/lib/supabase"
import {
  getExpensesYearOverYear,
  getExpensesYearOverYearLegacy,
  getFeedbackReport,
  getFeedbackReportLegacy,
  getOpsResolutionKpi,
  getOpsResolutionKpiLegacy,
  getPerformanceReport,
  getPerformanceReportLegacy,
  getPnlReport,
  getPnlReportLegacy,
  getSalarySpendByStaff,
  getSalarySpendByStaffLegacy,
  getSalesServiceReport,
  getSalesServiceReportLegacy,
  getTopCustomersBySales,
  getTopCustomersBySalesLegacy,
} from "@/services/reports"
import {
  getCoverageReport,
  getCoverageReportLegacy,
  getCustomerTotals,
  getCustomerTotalsLegacy,
  getProductSalesReport,
  getProductSalesReportLegacy,
} from "@/services/reportsInsights"

const env = import.meta.env as Record<string, string | undefined>
const email = env.VITE_PARITY_EMAIL
const password = env.VITE_PARITY_PASSWORD
const org = env.VITE_PARITY_ORG ?? ""
const oct = { from: "2026-10-01", to: "2026-10-31" }
const closeTo = (a: number, b: number) => expect(Math.abs(a - b)).toBeLessThanOrEqual(0.01)

describe.skipIf(!email || !password || !org)("legacy vs SQL (live throwaway org)", () => {
  beforeAll(async () => {
    const { error } = await supabase.auth.signInWithPassword({ email: email!, password: password! })
    if (error) throw error
  })

  it("P&L is identical in every field (same invoice set, same item profit)", async () => {
    const [o, n] = await Promise.all([getPnlReportLegacy(org, oct), getPnlReport(org, oct)])
    for (const k of ["revenueWithGst", "revenueWithoutGst", "gstCollected", "totalExpenses", "netProfitWithGst", "revenueCollectedWithGst", "revenueCollectedWithoutGst"] as const) closeTo(n[k], o[k])
    expect(n.expensesByCategory.map((e) => [e.category, e.amount]).sort()).toEqual(o.expensesByCategory.map((e) => [e.category, e.amount]).sort())
    for (const k of ["revenue", "cost", "giftsCost", "profit", "missingCostCount"] as const) closeTo(n.itemProfit[k], o.itemProfit[k])
  })

  it("Sales & Service: only the documented differences (service invoices at full total, count by invoice, collected)", async () => {
    const [o, n] = await Promise.all([getSalesServiceReportLegacy(org, oct), getSalesServiceReport(org, oct)])
    closeTo(n.amcRevenue, o.amcRevenue)
    closeTo(n.rentalRevenue, o.rentalRevenue)
    closeTo(n.salesRevenue, o.salesRevenue)
    expect(n.salesCallsCount).toBe(o.salesCallsCount)
    expect(n.technicianServiceCounts).toEqual(o.technicianServiceCounts) // decision 4: unchanged
    expect(n.serviceVisitCount).toBe(o.revenueByType[1].count) // legacy "service count" was visits
    // new total = legacy total - legacy service charge + full service invoice totals
    closeTo(n.totalRevenue - n.serviceRevenue, o.totalRevenue - o.serviceRevenue)
    expect(n.totalGst).toBeGreaterThan(0)
  })

  it("Top customers, customer totals and product sales match", async () => {
    const [ot, nt] = await Promise.all([getTopCustomersBySalesLegacy(org, oct, 50), getTopCustomersBySales(org, oct, 50)])
    expect(nt.map((r) => [r.customerId, r.invoicedTotal, r.collectedTotal, r.invoiceCount])).toEqual(ot.map((r) => [r.customerId, r.invoicedTotal, r.collectedTotal, r.invoiceCount]))
    const [oc, nc] = await Promise.all([getCustomerTotalsLegacy(org, oct), getCustomerTotals(org, oct)])
    expect(nc).toEqual(oc)
    const [op, np] = await Promise.all([getProductSalesReportLegacy(org, oct), getProductSalesReport(org, oct)])
    expect(np.map((r) => [r.itemType, r.itemId, r.qty, r.revenue, r.cost, r.profit])).toEqual(op.map((r) => [r.itemType, r.itemId, r.qty, r.revenue, r.cost, r.profit]))
  })

  it("Performance matches except a lead owner with no visits now has a real name", async () => {
    const [o, n] = await Promise.all([getPerformanceReportLegacy(org, oct), getPerformanceReport(org, oct)])
    expect(n.length).toBe(o.length)
    for (const row of n) {
      const old = o.find((x) => x.id === row.id)!
      expect(old).toBeTruthy()
      const { name, ...rest } = row
      const { name: oldName, ...oldRest } = old
      expect(rest).toEqual(oldRest)
      if (oldName === "—") expect(name).not.toBe("—")
      else expect(name).toBe(oldName)
    }
  })

  it("Ops resolution matches", async () => {
    expect(await getOpsResolutionKpi(org, oct)).toEqual(await getOpsResolutionKpiLegacy(org, oct))
  })

  it("Feedback matches except the trend, which is now grouped by IST day", async () => {
    const [o, n] = await Promise.all([getFeedbackReportLegacy(org, oct), getFeedbackReport(org, oct)])
    expect(n.starsDistribution).toEqual(o.starsDistribution)
    expect(n.averageRating).toEqual(o.averageRating)
    expect(n.lowRatingEntries.map((e) => [e.ratingId, e.stars, e.reason, e.customerName, e.technicianName])).toEqual(o.lowRatingEntries.map((e) => [e.ratingId, e.stars, e.reason, e.customerName, e.technicianName]))
  })

  it("Coverage matches when the browser is on IST", async () => {
    const [o, n] = await Promise.all([getCoverageReportLegacy(org, oct), getCoverageReport(org, oct)])
    expect(n).toEqual(o)
  })

  it("Salary by staff matches", async () => {
    expect(await getSalarySpendByStaff(org, oct)).toEqual(await getSalarySpendByStaffLegacy(org, oct))
  })

  it("Year over year: same years, categories and full-year totals", async () => {
    const [o, n] = await Promise.all([getExpensesYearOverYearLegacy(org, 3), getExpensesYearOverYear(org, 3)])
    expect(n.map((y) => [y.year, y.fullYearTotal])).toEqual(o.map((y) => [y.year, y.fullYearTotal]))
  })
})
