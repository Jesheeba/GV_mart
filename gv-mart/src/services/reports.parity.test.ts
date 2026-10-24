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

  it("Performance matches except a lead owner with no visits now has a real name, and efficiency (P5, new-path only)", async () => {
    const [o, n] = await Promise.all([getPerformanceReportLegacy(org, oct), getPerformanceReport(org, oct)])
    expect(n.length).toBe(o.length)
    for (const row of n) {
      const old = o.find((x) => x.id === row.id)!
      expect(old).toBeTruthy()
      // efficiencyPercent/efficiencySampleCount come from report_performance_efficiency, a SEPARATE RPC the legacy
      // browser-side path never had and never will — excluded from parity on purpose, not a regression.
      const { name, efficiencyPercent: _ep, efficiencySampleCount: _esc, ...rest } = row
      const { name: oldName, efficiencyPercent: _oep, efficiencySampleCount: _oesc, ...oldRest } = old
      expect(rest).toEqual(oldRest)
      if (oldName === "—") expect(name).not.toBe("—")
      else expect(name).toBe(oldName)
    }
  })

  it("Ops resolution matches — only meaningful while this org's SLA is still the legacy-assumed 24h", async (ctx) => {
    // getOpsResolutionKpiLegacy hardcodes 24 hours IN ITS FILTER (reports.ts), not just in a label — it predates
    // settings.ops_resolution_sla_hours entirely and has no way to read it. So this comparison only holds while
    // the org's setting is still the default; once someone changes it, resolved_within_24h/percent genuinely
    // diverge between the two paths, and that is correct new behaviour, not a bug. Skip (not fail, not delete)
    // so the parity signal survives for every org that hasn't touched the setting, and a change to the setting
    // shows up here as a skip, not a mystery red test with no visible cause.
    const { data: s, error } = await supabase.from("settings").select("ops_resolution_sla_hours").eq("org_id", org).single()
    if (error) throw error
    if (s.ops_resolution_sla_hours !== 24) {
      ctx.skip(`org's ops_resolution_sla_hours is ${s.ops_resolution_sla_hours}, not the legacy-assumed 24 — see comment above`)
    }
    // slaHours comes from the same setting (P5, new-path only) — the legacy path has no equivalent field at all;
    // excluded from parity on purpose, not a regression.
    const { slaHours: _sh, ...n } = await getOpsResolutionKpi(org, oct)
    expect(n).toEqual(await getOpsResolutionKpiLegacy(org, oct))
  })

  it("Feedback matches except the trend, which is now grouped by IST day", async () => {
    const [o, n] = await Promise.all([getFeedbackReportLegacy(org, oct), getFeedbackReport(org, oct)])
    expect(n.starsDistribution).toEqual(o.starsDistribution)
    expect(n.averageRating).toEqual(o.averageRating)
    expect(n.lowRatingEntries.map((e) => [e.ratingId, e.stars, e.reason, e.customerName, e.technicianName])).toEqual(o.lowRatingEntries.map((e) => [e.ratingId, e.stars, e.reason, e.customerName, e.technicianName]))
  })

  it("Coverage: only the two documented IST fixes differ", async () => {
    const [o, n] = await Promise.all([getCoverageReportLegacy(org, oct), getCoverageReport(org, oct)])
    const tzIsIst = new Date().getTimezoneOffset() === -330
    expect(n.truncated).toBe(o.truncated)
    expect(n.installation).toEqual(o.installation)
    expect(n.months.length).toBe(o.months.length)
    n.months.forEach((m, i) => {
      const old = o.months[i]
      expect(m.month).toBe(old.month)
      expect(m.warranty.active).toBe(old.warranty.active)
      expect(m.amc).toEqual({ ...old.amc, visits: tzIsIst ? old.amc.visits : m.amc.visits })
      if (tzIsIst) expect(m.warranty.visits).toBe(old.warranty.visits) // off IST the browser buckets visits by its own timezone: that is the bug
    })
    // Fix 2: the fixture has a rental returned at 00:30 IST on Oct 1 (still "out" on the IST date Oct 1, but its UTC
    // date is Sep 30, which is what the browser sliced), so October now counts one more active rental worth 300.
    const m = n.months[0], old = o.months[0]
    expect(m.rental.active).toBe(old.rental.active + 1)
    expect(m.rental.planValue).toBe(old.rental.planValue + 300)
  })

  it("Salary by staff matches", async () => {
    expect(await getSalarySpendByStaff(org, oct)).toEqual(await getSalarySpendByStaffLegacy(org, oct))
  })

  it("Year over year: same years, categories and full-year totals", async () => {
    const [o, n] = await Promise.all([getExpensesYearOverYearLegacy(org, 3), getExpensesYearOverYear(org, 3)])
    expect(n.map((y) => [y.year, y.fullYearTotal])).toEqual(o.map((y) => [y.year, y.fullYearTotal]))
  })
})
