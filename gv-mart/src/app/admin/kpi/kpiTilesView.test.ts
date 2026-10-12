import { describe, expect, it } from "vitest"
import en from "@/lib/i18n/en.json"
import ta from "@/lib/i18n/ta.json"
import type { KpiTiles } from "@/services/reportMappers"
import { buildKpiView, formatKpiValue, pickTiles } from "./kpiTilesView"

const sales: NonNullable<KpiTiles["sales"]> = {
  invoicedTotal: 22656,
  invoicedGst: 3456,
  invoicedNet: 19200,
  invoiceCount: 8,
  collectedTotal: 17576,
  collectedNet: 14894.92,
  outstandingAmount: 5906,
  outstandingInvoiceCount: 4,
  oldestOutstandingDate: "2026-09-30",
  streams: { product: 14500, spareCounter: 1000, gstAndAdjustments: 3144, service: 1062, amc: 2360, rental: 590, note: "x" },
  unitsSold: 3,
  avgSaleValue: 3728.8,
  leads: { new: 5, won: 2, lost: 1, wonPercent: 40 },
  repeatBuyers: { buying: 4, repeat: 1, new: 3, ratePercent: 25 },
}
const service: NonNullable<KpiTiles["service"]> = {
  openTickets: { count: 3, urgent: 2, pastSla: 1 },
  resolvedWithin24h: { resolved: 1, completed: 2, percent: 50 },
  rating: { average: 4, count: 3, below45: 2 },
  amc: { active: 2, renewalWindow: 1, revenue: 2360 },
}
const money: NonNullable<KpiTiles["moneyOut"]> = {
  spendTotal: 14200,
  spendByCategory: [],
  operatingSpendExclPurchase: 10200,
  cashProfit: 694.92,
  itemMargin: { revenue: 10950, cost: 7600, giftsCost: 0, profit: 3350, marginPercent: 30.6, missingCostCount: 1, costMissing: true },
}
const window = { from: "2026-10-01", to: "2026-10-31", todayIst: "2026-10-12" }
const master: KpiTiles = { window, role: "master", sales, service, moneyOut: money }

const ids = (xs: { id: string }[]) => xs.map((x) => x.id)

describe("buildKpiView - roles and headline", () => {
  it("master: six headline tiles in the approved order, all three groups", () => {
    const v = buildKpiView(master)
    expect(ids(v.headline)).toEqual(["invoiced", "collected", "cashProfit", "leadWon", "openTickets", "rating"])
    expect(v.groups.map((g) => g.group)).toEqual(["sales", "service", "moneyOut"])
  })
  it("operation_admin: outstanding replaces cash profit, no money-out group", () => {
    const v = buildKpiView({ ...master, role: "operation_admin", moneyOut: null })
    expect(ids(v.headline)).toEqual(["invoiced", "collected", "outstanding", "leadWon", "openTickets", "rating"])
    expect(v.groups.map((g) => g.group)).toEqual(["sales", "service"])
  })
  it("sales_admin: sales group only, headline of six sales tiles", () => {
    const v = buildKpiView({ ...master, role: "sales_admin", service: null, moneyOut: null })
    expect(ids(v.headline)).toEqual(["invoiced", "collected", "outstanding", "leadsNew", "leadWon", "repeat"])
    expect(v.groups.map((g) => g.group)).toEqual(["sales"])
    expect(ids(v.groups[0].tiles)).toEqual(["unitsSold", "avgSale"])
  })
  it("a group the server nulled never appears, whatever the role says", () => {
    const v = buildKpiView({ ...master, role: "master", moneyOut: null })
    expect(v.headline.map((h) => h.id)).not.toContain("cashProfit")
    expect(v.groups.map((g) => g.group)).not.toContain("moneyOut")
  })
  it("no tile is shown twice (headline tiles are not repeated in their group)", () => {
    const v = buildKpiView(master)
    const all = [...ids(v.headline), ...v.groups.flatMap((g) => ids(g.tiles))]
    expect(new Set(all).size).toBe(all.length)
  })
})

describe("buildKpiView - values", () => {
  const v = buildKpiView(master)
  const tile = (id: string) => [...v.headline, ...v.groups.flatMap((g) => g.tiles)].find((t) => t.id === id)!
  it("headline revenue is net of GST with the gross as the sub-line", () => {
    expect(tile("invoiced").value.amount).toBe(19200)
    expect(tile("invoiced").sub).toEqual({ key: "kpi.invoiced.sub", params: { amount: "₹22,656.00" } })
  })
  it("live flags: outstanding, open tickets, AMC", () => {
    expect(["outstanding", "openTickets", "amc"].every((id) => tile(id).live)).toBe(true)
    expect(tile("invoiced").live).toBe(false)
  })
  it("cost-missing badge sits on the margin tile and relabels the margin", () => {
    const m = tile("itemMargin")
    expect(m.badge).toEqual({ key: "kpi.costMissing.badge", params: { count: 1 } })
    expect(m.sub?.key).toBe("kpi.itemMargin.subWithCost")
  })
  it("no badge and the plain margin label when no cost is missing", () => {
    const vv = buildKpiView({ ...master, moneyOut: { ...money, itemMargin: { ...money.itemMargin, costMissing: false, missingCostCount: 0 } } })
    const m = vv.groups.find((g) => g.group === "moneyOut")!.tiles.find((t) => t.id === "itemMargin")!
    expect(m.badge).toBeNull()
    expect(m.sub?.key).toBe("kpi.itemMargin.sub")
  })
  it("streams add up to the total and carry the service-visit note key", () => {
    const s = v.streams!
    expect(s.rows.reduce((a, r) => a + r.amount, 0)).toBe(22656)
    expect(s.total).toBe(22656)
    expect(s.noteKey).toBe("kpi.streams.note")
    expect(s.rows.map((r) => r.id)).toEqual(["product", "spareCounter", "service", "amc", "rental", "gstAdjustments"])
  })
})

describe("buildKpiView - empty window (the real org has no invoices yet)", () => {
  const empty: KpiTiles = {
    window,
    role: "master",
    sales: {
      ...sales,
      invoicedTotal: 0, invoicedGst: 0, invoicedNet: 0, invoiceCount: 0, collectedTotal: 0, collectedNet: 0,
      outstandingAmount: 0, outstandingInvoiceCount: 0, oldestOutstandingDate: null,
      streams: { product: 0, spareCounter: 0, gstAndAdjustments: 0, service: 0, amc: 0, rental: 0, note: "x" },
      unitsSold: 0, avgSaleValue: 0,
      leads: { new: 0, won: 0, lost: 0, wonPercent: null },
      repeatBuyers: { buying: 0, repeat: 0, new: 0, ratePercent: null },
    },
    service: { openTickets: { count: 0, urgent: 0, pastSla: 0 }, resolvedWithin24h: { resolved: 0, completed: 0, percent: null }, rating: { average: null, count: 0, below45: 0 }, amc: { active: 0, renewalWindow: 0, revenue: 0 } },
    moneyOut: { spendTotal: 0, spendByCategory: [], operatingSpendExclPurchase: 0, cashProfit: 0, itemMargin: { revenue: 0, cost: 0, giftsCost: 0, profit: 0, marginPercent: null, missingCostCount: 0, costMissing: false } },
  }
  const v = buildKpiView(empty)
  const tile = (id: string) => [...v.headline, ...v.groups.flatMap((g) => g.tiles)].find((t) => t.id === id)!
  it("money tiles show a real zero, never a dash", () => {
    expect(formatKpiValue(tile("invoiced").value)).toBe("₹0.00")
    expect(formatKpiValue(tile("collected").value)).toBe("₹0.00")
    expect(tile("invoiced").sub?.key).toBe("kpi.noSales")
  })
  it("ratios with no basis show a dash and 'no data yet'", () => {
    expect(formatKpiValue(tile("leadWon").value)).toBe("—")
    expect(tile("leadWon").sub?.key).toBe("kpi.noData")
    expect(formatKpiValue(tile("rating").value)).toBe("—")
    expect(tile("rating").empty).toBe(true)
  })
  it("live tiles with nothing in them still show 0", () => {
    expect(formatKpiValue(tile("openTickets").value)).toBe("0")
    expect(tile("outstanding").sub?.key).toBe("kpi.outstanding.none")
  })
  it("streams are flagged empty with 0 percentages (no NaN)", () => {
    expect(v.streams?.empty).toBe(true)
    expect(v.streams?.rows.every((r) => r.percent === 0)).toBe(true)
  })
})

describe("pickTiles and formatting", () => {
  const v = buildKpiView(master)
  it("returns only the requested tiles, skipping any the server did not send", () => {
    const sa = buildKpiView({ ...master, role: "sales_admin", service: null, moneyOut: null })
    expect(ids(pickTiles(sa, ["leadsNew", "openTickets", "leadWon"]).tiles)).toEqual(["leadsNew", "leadWon"])
    expect(pickTiles(v, ["streams"]).streams).not.toBeNull()
    expect(pickTiles(v, ["unitsSold"]).streams).toBeNull()
  })
  it("compact currency uses lakh and crore only on narrow screens; the full figure otherwise", () => {
    expect(formatKpiValue({ kind: "currency", amount: 1234567 }, { compact: true })).toBe("₹12.35L")
    expect(formatKpiValue({ kind: "currency", amount: 123456789 }, { compact: true })).toBe("₹12.35Cr")
    expect(formatKpiValue({ kind: "currency", amount: 1234567 })).toBe("₹12,34,567.00")
    expect(formatKpiValue({ kind: "currency", amount: 999 }, { compact: true })).toBe("₹999.00")
    expect(formatKpiValue({ kind: "percent", amount: 40 })).toBe("40%")
    expect(formatKpiValue({ kind: "rating", amount: 4 })).toBe("4.0")
  })
})

describe("every translation key the view-model emits exists in en.json and ta.json", () => {
  const has = (o: object, key: string) => key.split(".").reduce<unknown>((a, k) => (a && typeof a === "object" ? (a as Record<string, unknown>)[k] : undefined), o) !== undefined
  it("covers titles, help, subs, badges, streams and group titles", () => {
    const keys = new Set<string>()
    const emptyKpi = buildKpiView(master)
    for (const t of [...emptyKpi.headline, ...emptyKpi.groups.flatMap((g) => g.tiles)]) {
      keys.add(t.titleKey); keys.add(t.helpKey)
      if (t.sub) keys.add(t.sub.key)
      if (t.badge) keys.add(t.badge.key)
    }
    for (const g of emptyKpi.groups) keys.add(g.titleKey)
    const s = emptyKpi.streams!
    ;[s.titleKey, s.helpKey, s.noteKey, s.totalKey, ...s.rows.map((r) => r.labelKey)].forEach((k) => keys.add(k))
    ;["kpi.noSales", "kpi.noData", "kpi.live", "kpi.period", "kpi.error", "kpi.helpButton", "kpi.exactAmount", "kpi.updating", "kpi.toggleGroup", "kpi.todaySales", "kpi.outstanding.none", "kpi.itemMargin.sub", "kpi.itemMargin.subWithCost"].forEach((k) => keys.add(k))
    const missing = [...keys].filter((k) => !has(en, k) || !has(ta, k))
    expect(missing).toEqual([])
  })
})
