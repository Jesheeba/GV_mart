import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Funnel, Users, UserPlus, Repeat } from "lucide-react"
import { KpiCard } from "@/components/shared/KpiCard"
import { ColumnPicker } from "@/components/shared/ColumnPicker"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { useColumnPrefs } from "@/hooks/useColumnPrefs"
import { useProfile } from "@/hooks/useProfile"
import { useCustomerTotals, useLeadFunnel, useProductSalesReport } from "@/hooks/useReports"
import { defaultPeriodValue, downloadCsv, periodToRange, toCsv, type PeriodValue } from "@/services/reports"
import type { ProductSalesRow } from "@/services/reportsInsights"
import { formatCurrency } from "@/lib/sale-calc"
import { PeriodFilter } from "./PeriodFilter"

const PRODUCT_COLUMNS = ["type", "qty", "invoices", "revenue", "share", "avgPrice", "cost", "margin"] as const
type ProductColumn = (typeof PRODUCT_COLUMNS)[number]
const PRODUCT_DEFAULTS: ProductColumn[] = ["type", "qty", "revenue", "share", "avgPrice"]

/** Phase 2 Part G — customer totals, lead-to-sale funnel, product-wise sales. */
export function SalesInsightsReportTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const [period, setPeriod] = useState<PeriodValue>(defaultPeriodValue())
  const range = periodToRange(period)
  const orgId = profile?.org_id

  const customers = useCustomerTotals(orgId, range)
  const funnel = useLeadFunnel(orgId, range)
  const products = useProductSalesReport(orgId, range)
  const cols = useColumnPrefs<ProductColumn>("productSales", PRODUCT_COLUMNS, PRODUCT_DEFAULTS)

  const c = customers.data
  const f = funnel.data
  const rows = products.data ?? []

  const defs: Record<ProductColumn, DataTableColumn<ProductSalesRow>> = {
    type: { key: "type", header: t("reports.insights.type"), render: (r) => (r.itemType === "product" ? (r.category ?? t("reports.insights.product")) : t("reports.insights.spare")) },
    qty: { key: "qty", header: t("reports.insights.qty"), render: (r) => r.qty },
    invoices: { key: "invoices", header: t("reports.insights.invoices"), render: (r) => r.invoiceCount },
    revenue: { key: "revenue", header: t("reports.insights.revenue"), render: (r) => formatCurrency(r.revenue) },
    share: { key: "share", header: t("reports.insights.share"), render: (r) => `${r.sharePercent}%` },
    avgPrice: { key: "avgPrice", header: t("reports.insights.avgPrice"), render: (r) => formatCurrency(r.avgPrice) },
    cost: { key: "cost", header: t("reports.insights.cost"), render: (r) => (r.cost == null ? "—" : formatCurrency(r.cost)) },
    margin: { key: "margin", header: t("reports.insights.margin"), render: (r) => (r.marginPercent == null ? "—" : `${r.marginPercent}%`) },
  }
  const columns: DataTableColumn<ProductSalesRow>[] = [
    { key: "name", header: t("reports.insights.item"), render: (r) => r.name },
    ...PRODUCT_COLUMNS.filter((k) => cols.isVisible(k)).map((k) => defs[k]),
  ]

  function handleExport() {
    const csv = toCsv(
      [t("reports.insights.item"), ...PRODUCT_COLUMNS.map((k) => t(`reports.insights.${k}`))],
      rows.map((r) => [r.name, r.itemType, r.qty, r.invoiceCount, r.revenue, r.sharePercent, r.avgPrice, r.cost, r.marginPercent])
    )
    downloadCsv(`product-sales_${range.from}_${range.to}.csv`, csv)
  }

  const maxStage = Math.max(1, ...(f?.stages.map((s) => s.count) ?? [1]))

  return (
    <div className="space-y-4">
      <PeriodFilter value={period} onChange={setPeriod} onExport={handleExport} />

      <div className="space-y-2">
        <p className="px-1 text-sm font-semibold text-text">{t("reports.insights.customersTitle")}</p>
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
          <KpiCard label={t("reports.insights.totalCustomers")} value={c?.totalCustomers ?? "—"} subValue={c ? `${t("reports.insights.newInRange")}: ${c.newCustomers}` : undefined} icon={<Users className="size-4" />} loading={customers.isLoading} />
          <KpiCard label={t("reports.insights.buyingCustomers")} value={c?.buyingCustomers ?? "—"} subValue={c ? `${t("reports.insights.avgPerBuyer")}: ${formatCurrency(c.avgRevenuePerBuyer)}` : undefined} icon={<Users className="size-4" />} loading={customers.isLoading} />
          <KpiCard label={t("reports.insights.newBuyers")} value={c?.newBuyers ?? "—"} icon={<UserPlus className="size-4" />} loading={customers.isLoading} />
          <KpiCard label={t("reports.insights.repeatBuyers")} value={c?.repeatBuyers ?? "—"} subValue={c?.repeatRatePercent != null ? `${c.repeatRatePercent}%` : undefined} icon={<Repeat className="size-4" />} loading={customers.isLoading} />
        </div>
      </div>

      <div className="space-y-2">
        <p className="flex items-center gap-1.5 px-1 text-sm font-semibold text-text">
          <Funnel className="size-4" />
          {t("reports.insights.funnelTitle")}
        </p>
        <div className="rounded-xl border border-border bg-surface p-4">
          {funnel.isLoading ? (
            <p className="text-sm text-text-muted">…</p>
          ) : !f || f.total === 0 ? (
            <p className="text-sm text-text-muted">{t("reports.empty")}</p>
          ) : (
            <div className="space-y-3">
              {f.stages.map((s) => (
                <div key={s.key}>
                  <div className="mb-1 flex items-center justify-between text-[13px]">
                    <span className="font-semibold text-text">{t(`reports.insights.stage.${s.key}`)}</span>
                    <span className="font-bold tabular-nums text-text">{s.count}</span>
                  </div>
                  <div className="h-2 overflow-hidden rounded-full bg-border">
                    <div className="h-full rounded-full bg-accent" style={{ width: `${Math.max(3, Math.round((s.count / maxStage) * 100))}%` }} />
                  </div>
                </div>
              ))}
              <div className="flex flex-wrap items-center justify-between gap-2 border-t border-border pt-2 text-xs text-text-muted">
                <span>
                  {t("reports.insights.lost")}: <b className="text-text">{f.lost}</b>
                  {f.lostStageUnknown > 0 ? <span> ({t("reports.insights.lostUnknown", { count: f.lostStageUnknown })})</span> : null}
                </span>
                <span>
                  {t("reports.insights.conversion")}: <b className="text-text">{f.conversionPercent != null ? `${f.conversionPercent}%` : "—"}</b>
                </span>
              </div>
              {f.bySource.length > 0 ? (
                <DataTable
                  columns={[
                    { key: "s", header: t("reports.insights.source"), render: (r) => r.source },
                    { key: "t", header: t("reports.insights.leads"), render: (r) => r.total },
                    { key: "w", header: t("reports.insights.won"), render: (r) => r.won },
                    { key: "c", header: t("reports.insights.conversion"), render: (r) => (r.conversionPercent != null ? `${r.conversionPercent}%` : "—") },
                  ]}
                  rows={f.bySource}
                  rowKey={(r) => r.source}
                />
              ) : null}
              <p className="text-[11px] text-text-muted">{t("reports.insights.funnelNote")}</p>
            </div>
          )}
        </div>
      </div>

      <div className="space-y-2">
        <div className="flex items-center justify-between gap-2 px-1">
          <p className="text-sm font-semibold text-text">{t("reports.insights.productTitle")}</p>
          <ColumnPicker
            options={PRODUCT_COLUMNS.map((k) => ({ key: k, label: t(`reports.insights.${k}`) }))}
            visible={cols.visible}
            onToggle={cols.toggle}
            onReset={cols.reset}
          />
        </div>
        <DataTable columns={columns} rows={rows} rowKey={(r) => `${r.itemType}:${r.itemId}`} loading={products.isLoading} emptyMessage={t("reports.empty")} />
        <p className="px-1 text-[11px] text-text-muted">{t("reports.insights.productNote")}</p>
      </div>
    </div>
  )
}
