import type { KpiTiles } from "@/services/reportMappers"
import { formatCurrency } from "@/lib/sale-calc"

/**
 * Pure view-model for the KPI tile strip (docs/plan-kpi-tiles.md, Step 3). No React, no i18n lookups: it returns
 * translation KEYS and parameters, so it is unit-testable in plain Node.
 *
 * Visibility is decided only by which groups the server returned (a null group is simply absent). The role string is
 * used for ONE thing: the order of the six headline tiles.
 */
export type KpiGroup = "sales" | "service" | "moneyOut"
export type KpiTileId =
  | "invoiced"
  | "collected"
  | "outstanding"
  | "spend"
  | "cashProfit"
  | "itemMargin"
  | "unitsSold"
  | "avgSale"
  | "leadsNew"
  | "leadWon"
  | "openTickets"
  | "resolved"
  | "rating"
  | "amc"
  | "repeat"

export type KpiValue = { kind: "currency" | "count" | "percent" | "rating"; amount: number | null }
export type KpiText = { key: string; params?: Record<string, string | number> }

export type KpiTileView = {
  id: KpiTileId
  group: KpiGroup
  titleKey: string
  helpKey: string
  value: KpiValue
  sub: KpiText | null
  /** live tiles ignore the period (open tickets, outstanding, AMC book) */
  live: boolean
  badge: KpiText | null
  /** the tile has no data to show (renders softer, value shows an em dash when amount is null) */
  empty: boolean
}

export type KpiStreamRow = { id: "product" | "spareCounter" | "service" | "amc" | "rental" | "gstAdjustments"; labelKey: string; amount: number; percent: number }
export type KpiStreamsView = { rows: KpiStreamRow[]; total: number; titleKey: string; helpKey: string; noteKey: string; totalKey: string; empty: boolean }

export type KpiView = {
  role: KpiTiles["role"]
  period: { from: string; to: string; todayIst: string }
  headline: KpiTileView[]
  groups: { group: KpiGroup; titleKey: string; tiles: KpiTileView[] }[]
  streams: KpiStreamsView | null
}

const GROUP_TITLE: Record<KpiGroup, string> = { sales: "kpi.group.sales", service: "kpi.group.service", moneyOut: "kpi.group.moneyOut" }

/** Headline order per role (condition from the approved plan, section 11.1). Tiles in a group the server did not return drop out. */
const HEADLINE: Record<KpiTiles["role"], KpiTileId[]> = {
  master: ["invoiced", "collected", "cashProfit", "leadWon", "openTickets", "rating"],
  operation_admin: ["invoiced", "collected", "outstanding", "leadWon", "openTickets", "rating"],
  sales_admin: ["invoiced", "collected", "outstanding", "leadsNew", "leadWon", "repeat"],
}

const GROUP_ORDER: Record<KpiGroup, KpiTileId[]> = {
  sales: ["invoiced", "collected", "outstanding", "unitsSold", "avgSale", "leadsNew", "leadWon", "repeat"],
  service: ["openTickets", "resolved", "rating", "amc"],
  moneyOut: ["spend", "cashProfit", "itemMargin"],
}

const text = (key: string, params?: Record<string, string | number>): KpiText => ({ key, params })

function salesTiles(s: NonNullable<KpiTiles["sales"]>): KpiTileView[] {
  const noSales = s.invoiceCount === 0
  const base = (id: KpiTileId, partial: Partial<KpiTileView> & Pick<KpiTileView, "value">): KpiTileView => ({
    id,
    group: "sales",
    titleKey: `kpi.${id}.title`,
    helpKey: `kpi.${id}.help`,
    sub: null,
    live: false,
    badge: null,
    empty: false,
    ...partial,
  })
  return [
    base("invoiced", {
      value: { kind: "currency", amount: s.invoicedNet },
      sub: noSales ? text("kpi.noSales") : text("kpi.invoiced.sub", { amount: formatCurrency(s.invoicedTotal) }),
      empty: noSales,
    }),
    base("collected", {
      value: { kind: "currency", amount: s.collectedTotal },
      sub: noSales ? text("kpi.noSales") : text("kpi.collected.sub", { total: formatCurrency(s.invoicedTotal) }),
      empty: noSales,
    }),
    base("outstanding", {
      value: { kind: "currency", amount: s.outstandingAmount },
      sub:
        s.outstandingInvoiceCount > 0
          ? text("kpi.outstanding.sub", { count: s.outstandingInvoiceCount, date: s.oldestOutstandingDate ?? "—" })
          : text("kpi.outstanding.none"),
      live: true,
    }),
    base("unitsSold", { value: { kind: "count", amount: s.unitsSold }, empty: noSales }),
    base("avgSale", { value: { kind: "currency", amount: s.avgSaleValue > 0 ? s.avgSaleValue : null }, sub: s.avgSaleValue > 0 ? null : text("kpi.noData"), empty: s.avgSaleValue <= 0 }),
    base("leadsNew", { value: { kind: "count", amount: s.leads.new }, empty: false }),
    base("leadWon", {
      value: { kind: "percent", amount: s.leads.wonPercent },
      sub: s.leads.wonPercent == null ? text("kpi.noData") : text("kpi.leadWon.sub", { won: s.leads.won, total: s.leads.new }),
      empty: s.leads.wonPercent == null,
    }),
    base("repeat", {
      value: { kind: "percent", amount: s.repeatBuyers.ratePercent },
      sub: s.repeatBuyers.ratePercent == null ? text("kpi.noData") : text("kpi.repeat.sub", { repeat: s.repeatBuyers.repeat, buying: s.repeatBuyers.buying }),
      empty: s.repeatBuyers.ratePercent == null,
    }),
  ]
}

function serviceTiles(v: NonNullable<KpiTiles["service"]>): KpiTileView[] {
  const base = (id: KpiTileId, partial: Partial<KpiTileView> & Pick<KpiTileView, "value">): KpiTileView => ({
    id,
    group: "service",
    titleKey: `kpi.${id}.title`,
    helpKey: `kpi.${id}.help`,
    sub: null,
    live: false,
    badge: null,
    empty: false,
    ...partial,
  })
  return [
    base("openTickets", {
      value: { kind: "count", amount: v.openTickets.count },
      sub: text("kpi.openTickets.sub", { urgent: v.openTickets.urgent, past: v.openTickets.pastSla }),
      live: true,
    }),
    base("resolved", {
      value: { kind: "percent", amount: v.resolvedWithin24h.percent },
      sub:
        v.resolvedWithin24h.percent == null
          ? text("kpi.noData")
          : text("kpi.resolved.sub", {
              resolved: v.resolvedWithin24h.resolved,
              completed: v.resolvedWithin24h.completed,
              hours: v.resolvedWithin24h.slaHours,
            }),
      empty: v.resolvedWithin24h.percent == null,
    }),
    base("rating", {
      value: { kind: "rating", amount: v.rating.average },
      sub: v.rating.average == null ? text("kpi.noData") : text("kpi.rating.sub", { count: v.rating.count, low: v.rating.below45 }),
      empty: v.rating.average == null,
    }),
    base("amc", {
      value: { kind: "count", amount: v.amc.active },
      sub: text("kpi.amc.sub", { count: v.amc.renewalWindow }),
      live: true,
    }),
  ]
}

function moneyTiles(m: NonNullable<KpiTiles["moneyOut"]>): KpiTileView[] {
  const base = (id: KpiTileId, partial: Partial<KpiTileView> & Pick<KpiTileView, "value">): KpiTileView => ({
    id,
    group: "moneyOut",
    titleKey: `kpi.${id}.title`,
    helpKey: `kpi.${id}.help`,
    sub: null,
    live: false,
    badge: null,
    empty: false,
    ...partial,
  })
  const im = m.itemMargin
  return [
    base("spend", {
      value: { kind: "currency", amount: m.spendTotal },
      sub: text("kpi.spend.sub", { amount: formatCurrency(m.operatingSpendExclPurchase) }),
    }),
    base("cashProfit", { value: { kind: "currency", amount: m.cashProfit } }),
    base("itemMargin", {
      value: { kind: "currency", amount: im.profit },
      sub:
        im.marginPercent == null
          ? text("kpi.noData")
          : text(im.costMissing ? "kpi.itemMargin.subWithCost" : "kpi.itemMargin.sub", { percent: im.marginPercent }),
      // The cost-missing badge is part of the tile (approval condition a / 4): lines without a cost price are left out of the margin.
      badge: im.costMissing ? text("kpi.costMissing.badge", { count: im.missingCostCount }) : null,
      empty: im.marginPercent == null && !im.costMissing,
    }),
  ]
}

function streamsView(s: NonNullable<KpiTiles["sales"]>): KpiStreamsView {
  const r = s.streams
  const rows: Omit<KpiStreamRow, "percent">[] = [
    { id: "product", labelKey: "kpi.streams.product", amount: r.product },
    { id: "spareCounter", labelKey: "kpi.streams.spareCounter", amount: r.spareCounter },
    { id: "service", labelKey: "kpi.streams.service", amount: r.service },
    { id: "amc", labelKey: "kpi.streams.amc", amount: r.amc },
    { id: "rental", labelKey: "kpi.streams.rental", amount: r.rental },
    { id: "gstAdjustments", labelKey: "kpi.streams.gstAdjustments", amount: r.gstAndAdjustments },
  ]
  const total = rows.reduce((sum, x) => sum + x.amount, 0)
  return {
    rows: rows.map((x) => ({ ...x, percent: total > 0 ? Math.round((x.amount / total) * 1000) / 10 : 0 })),
    total,
    titleKey: "kpi.streams.title",
    helpKey: "kpi.streams.help",
    noteKey: "kpi.streams.note",
    totalKey: "kpi.streams.total",
    empty: total === 0,
  }
}

export function buildKpiView(t: KpiTiles): KpiView {
  const byGroup: Partial<Record<KpiGroup, KpiTileView[]>> = {}
  if (t.sales) byGroup.sales = salesTiles(t.sales)
  if (t.service) byGroup.service = serviceTiles(t.service)
  if (t.moneyOut) byGroup.moneyOut = moneyTiles(t.moneyOut)

  const all = new Map<KpiTileId, KpiTileView>()
  for (const tiles of Object.values(byGroup)) for (const tile of tiles ?? []) all.set(tile.id, tile)

  const headline = (HEADLINE[t.role] ?? HEADLINE.sales_admin).map((id) => all.get(id)).filter((x): x is KpiTileView => !!x)
  const headlineIds = new Set(headline.map((h) => h.id))

  const groups = (["sales", "service", "moneyOut"] as KpiGroup[])
    .filter((g) => byGroup[g])
    .map((g) => {
      const tiles = GROUP_ORDER[g]
        .map((id) => byGroup[g]!.find((x) => x.id === id))
        .filter((x): x is KpiTileView => !!x && !headlineIds.has(x.id))
      return { group: g, titleKey: GROUP_TITLE[g], tiles }
    })
    .filter((g) => g.tiles.length > 0)

  return {
    role: t.role,
    period: { from: t.window.from, to: t.window.to, todayIst: t.window.todayIst },
    headline,
    groups,
    streams: t.sales ? streamsView(t.sales) : null,
  }
}

/** Reports tabs show a hand-picked subset. Unknown or not-returned tiles are skipped silently. */
export function pickTiles(view: KpiView, ids: (KpiTileId | "streams")[]): { tiles: KpiTileView[]; streams: KpiStreamsView | null } {
  const all = new Map<KpiTileId, KpiTileView>()
  for (const t of [...view.headline, ...view.groups.flatMap((g) => g.tiles)]) all.set(t.id, t)
  const tiles = ids.filter((id): id is KpiTileId => id !== "streams").map((id) => all.get(id)).filter((x): x is KpiTileView => !!x)
  return { tiles, streams: ids.includes("streams") ? view.streams : null }
}

/** Indian digit grouping; `compact` uses lakh / crore for narrow screens (the popover always carries the exact amount). */
export function formatKpiValue(v: KpiValue, opts: { compact?: boolean } = {}): string {
  if (v.amount == null) return "—"
  switch (v.kind) {
    case "currency": {
      const n = v.amount
      if (opts.compact) {
        const abs = Math.abs(n)
        if (abs >= 1_00_00_000) return `₹${(n / 1_00_00_000).toFixed(2)}Cr`
        if (abs >= 1_00_000) return `₹${(n / 1_00_000).toFixed(2)}L`
      }
      return formatCurrency(n)
    }
    case "percent":
      return `${v.amount}%`
    case "rating":
      return v.amount.toFixed(1)
    case "count":
      return v.amount.toLocaleString("en-IN")
  }
}
