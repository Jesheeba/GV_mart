import { describe, expect, it } from "vitest"
import { mapKpiTiles, type KpiTilesRpc } from "@/services/reportMappers"

const window = { from: "2026-10-01", to: "2026-10-31", today_ist: "2026-10-12" }
const sales: NonNullable<KpiTilesRpc["sales"]> = {
  invoiced: { count: 8, total: 22656, gst: 3456, net: 19200 },
  collected: { total: 17576, net: 14894.92 },
  outstanding: { amount: 5906, invoice_count: 4, oldest_invoice_date: "2026-09-30" },
  streams: { product: 14500, spare_counter: 1000, gst_and_adjustments: 3144, service: 1062, amc: 2360, rental: 590, note: "Spares used on a service visit count as Service, not as Spare." },
  units_sold: 3,
  avg_sale_value: 3728.8,
  leads: { new: 5, won: 2, lost: 1, won_percent: 40 },
  repeat_buyers: { buying_customers: 4, repeat_buyers: 1, new_buyers: 3, repeat_rate_percent: 25 },
}
const service: NonNullable<KpiTilesRpc["service"]> = {
  open_tickets: { count: 3, urgent: 2, past_sla: 1 },
  resolved_within_24h: { resolved: 1, completed: 2, percent: 50 },
  rating: { average: 4, count: 3, below_4_5: 2 },
  amc: { active: 2, renewal_window: 1, revenue: 2360 },
}
const money: NonNullable<KpiTilesRpc["money_out"]> = {
  spend: { total: 14200, by_category: [{ category: "salary", amount: 6000 }], operating_excl_purchase: 10200 },
  cash_profit: { collected_net: 14894.92, spend: 14200, profit: 694.92 },
  item_margin: { revenue: 10950, cost: 7600, gifts_cost: 0, profit: 3350, margin_percent: 30.6, missing_cost_count: 1, cost_missing: true },
}

describe("mapKpiTiles", () => {
  it("maps every group for a master", () => {
    const t = mapKpiTiles({ window, role: "master", sales, service, money_out: money })
    expect(t.sales?.invoicedNet).toBe(19200)
    expect(t.sales?.outstandingAmount).toBe(5906)
    expect(t.sales?.streams.spareCounter).toBe(1000)
    expect(t.service?.openTickets.pastSla).toBe(1)
    expect(t.moneyOut?.cashProfit).toBe(694.92)
    expect(t.moneyOut?.itemMargin.costMissing).toBe(true)
  })
  it("keeps groups a role may not see as null, never as zeros", () => {
    const t = mapKpiTiles({ window, role: "sales_admin", sales, service: null, money_out: null })
    expect(t.service).toBeNull()
    expect(t.moneyOut).toBeNull()
    expect(t.sales).not.toBeNull()
  })
  it("keeps 'no data' percentages and averages as null", () => {
    const t = mapKpiTiles({
      window,
      role: "master",
      sales: {
        ...sales,
        leads: { new: 0, won: 0, lost: 0, won_percent: null },
        repeat_buyers: { buying_customers: 0, repeat_buyers: 0, new_buyers: 0, repeat_rate_percent: null },
        outstanding: { amount: 0, invoice_count: 0, oldest_invoice_date: null },
      },
      service: { ...service, rating: { average: null, count: 0, below_4_5: 0 }, resolved_within_24h: { resolved: 0, completed: 0, percent: null } },
      money_out: { ...money, item_margin: { ...money.item_margin, margin_percent: null, cost_missing: false, missing_cost_count: 0 } },
    })
    expect(t.sales?.leads.wonPercent).toBeNull()
    expect(t.sales?.oldestOutstandingDate).toBeNull()
    expect(t.service?.rating.average).toBeNull()
    expect(t.moneyOut?.itemMargin.marginPercent).toBeNull()
    expect(t.moneyOut?.itemMargin.costMissing).toBe(false)
  })
  it("coerces numeric strings the way PostgREST returns numerics", () => {
    const t = mapKpiTiles({
      window,
      role: "master",
      sales: { ...sales, invoiced: { count: 1, total: "100.50" as unknown as number, gst: 0, net: 100.5 } },
      service: null,
      money_out: null,
    })
    expect(t.sales?.invoicedTotal).toBe(100.5)
  })
})
