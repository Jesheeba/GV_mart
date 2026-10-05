import { useState } from "react"
import { useTranslation } from "react-i18next"
import { IndianRupee, PhoneCall, ReceiptText, ShieldCheck, CalendarClock, Wrench } from "lucide-react"
import { KpiCard } from "@/components/shared/KpiCard"
import { HighlightKpiCard } from "@/components/shared/HighlightKpiCard"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { useProfile } from "@/hooks/useProfile"
import { useSalesServiceReport } from "@/hooks/useReports"
import { defaultPeriodValue, downloadCsv, periodToRange, toCsv, type PeriodValue } from "@/services/reports"
import { formatCurrency } from "@/lib/sale-calc"
import { ColumnPicker } from "@/components/shared/ColumnPicker"
import { useColumnPrefs } from "@/hooks/useColumnPrefs"
import { PeriodFilter } from "./PeriodFilter"

const REVENUE_TYPE_COLUMNS = ["revenue", "collected", "share", "count", "qty", "avgValue"] as const
type RevenueTypeColumn = (typeof REVENUE_TYPE_COLUMNS)[number]

export function SalesServiceReportTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const [period, setPeriod] = useState<PeriodValue>(defaultPeriodValue())
  const range = periodToRange(period)

  const { data, isLoading, isError, refetch } = useSalesServiceReport(profile?.org_id, range)
  const typeCols = useColumnPrefs<RevenueTypeColumn>("revenueByType", REVENUE_TYPE_COLUMNS, REVENUE_TYPE_COLUMNS)

  type RevenueTypeRow = NonNullable<typeof data>["revenueByType"][number]
  const typeColumnDefs: Record<RevenueTypeColumn, DataTableColumn<RevenueTypeRow>> = {
    revenue: { key: "revenue", header: t("reports.salesService.revenueByTypeCols.revenue"), render: (r) => formatCurrency(r.revenue) },
    collected: { key: "collected", header: t("reports.collectedLabel"), render: (r) => formatCurrency(r.collected) },
    share: { key: "share", header: t("reports.salesService.revenueByTypeCols.share"), render: (r) => `${r.percent}%` },
    count: { key: "count", header: t("reports.salesService.revenueByTypeCols.count"), render: (r) => r.count },
    qty: { key: "qty", header: t("reports.salesService.revenueByTypeCols.qty"), render: (r) => r.qty },
    avgValue: { key: "avgValue", header: t("reports.salesService.revenueByTypeCols.avgValue"), render: (r) => formatCurrency(r.avgValue) },
  }
  const typeColumns: DataTableColumn<RevenueTypeRow>[] = [
    { key: "type", header: t("reports.salesService.revenueByTypeCols.type"), render: (r) => t(`reports.salesService.revenueTypeLabel.${r.type}`) },
    ...REVENUE_TYPE_COLUMNS.filter((k) => typeCols.isVisible(k)).map((k) => typeColumnDefs[k]),
  ]

  const techColumns: DataTableColumn<NonNullable<typeof data>["technicianServiceCounts"][number]>[] = [
    { key: "name", header: t("reports.salesService.technician"), render: (r) => r.technicianName },
    { key: "count", header: t("reports.salesService.serviceCount"), render: (r) => r.count },
    { key: "revenue", header: t("reports.salesService.revenue"), render: (r) => formatCurrency(r.revenue) },
  ]

  function handleExport() {
    if (!data) return
    const csv = toCsv(
      [t("reports.salesService.technician"), t("reports.salesService.serviceCount"), t("reports.salesService.revenue")],
      data.technicianServiceCounts.map((r) => [r.technicianName, r.count, r.revenue])
    )
    downloadCsv(`sales-service-report_${range.from}_${range.to}.csv`, csv)
  }

  return (
    <div className="space-y-4">
      <PeriodFilter value={period} onChange={setPeriod} onExport={handleExport} />

      {isError ? (
        <p className="text-sm text-danger">
          {t("reports.loadFailed")}{" "}
          <button type="button" className="underline" onClick={() => refetch()}>
            {t("common.retry")}
          </button>
        </p>
      ) : (
        <>
          {/* 2026-09-24 Accounts change request, item 3: Sales/Service/AMC/
              Rental shown as separate KPIs rather than folded into one
              figure. Total Revenue below is the honest sum of all four —
              it used to silently exclude service revenue (service_visits
              has no invoice_type at all), fixed as part of this change. */}
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
            <KpiCard
              label={t("reports.salesService.salesRevenue")}
              value={data ? formatCurrency(data.salesRevenue) : "—"}
              subValue={data ? `${t("reports.collectedLabel")}: ${formatCurrency(data.salesCollected)}` : undefined}
              icon={<ReceiptText className="size-4" />}
              loading={isLoading}
            />
            <KpiCard
              label={t("reports.salesService.serviceRevenue")}
              value={data ? formatCurrency(data.serviceRevenue) : "—"}
              subValue={data ? `${t("reports.collectedLabel")}: ${formatCurrency(data.serviceCollected)}` : undefined}
              icon={<Wrench className="size-4" />}
              loading={isLoading}
            />
            <KpiCard
              label={t("reports.salesService.amcRevenue")}
              value={data ? formatCurrency(data.amcRevenue) : "—"}
              subValue={data ? `${t("reports.collectedLabel")}: ${formatCurrency(data.amcCollected)}` : undefined}
              icon={<ShieldCheck className="size-4" />}
              loading={isLoading}
            />
            <KpiCard
              label={t("reports.salesService.rentalRevenue")}
              value={data ? formatCurrency(data.rentalRevenue) : "—"}
              subValue={data ? `${t("reports.collectedLabel")}: ${formatCurrency(data.rentalCollected)}` : undefined}
              icon={<CalendarClock className="size-4" />}
              loading={isLoading}
            />
          </div>

          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
            <HighlightKpiCard
              label={t("reports.salesService.totalRevenue")}
              value={data ? formatCurrency(data.totalRevenue) : "—"}
              caption={data ? `${t("reports.collectedLabel")}: ${formatCurrency(data.totalCollected)}` : undefined}
              icon={<IndianRupee className="size-4" />}
              loading={isLoading}
            />
            <KpiCard label={t("reports.salesService.salesCalls")} value={data?.salesCallsCount ?? "—"} icon={<PhoneCall className="size-4" />} loading={isLoading} />
            <KpiCard
              label={t("reports.salesService.avgValuePerCall")}
              value={data ? formatCurrency(data.avgValuePerServiceCall) : "—"}
              icon={<Wrench className="size-4" />}
              loading={isLoading}
            />
            <KpiCard
              label={t("reports.salesService.invoiceCount")}
              value={data ? data.invoiceTypeRatio.reduce((s, r) => s + r.count, 0) : "—"}
              icon={<ReceiptText className="size-4" />}
              loading={isLoading}
            />
          </div>
        </>
      )}

      <div className="space-y-2">
        <div className="flex items-center justify-between gap-2 px-1">
          <p className="text-sm font-semibold text-text">{t("reports.salesService.revenueByType")}</p>
          <ColumnPicker
            options={REVENUE_TYPE_COLUMNS.map((k) => ({ key: k, label: k === "collected" ? t("reports.collectedLabel") : t(`reports.salesService.revenueByTypeCols.${k}`) }))}
            visible={typeCols.visible}
            onToggle={typeCols.toggle}
            onReset={typeCols.reset}
          />
        </div>
        <DataTable columns={typeColumns} rows={data?.revenueByType ?? []} rowKey={(r) => r.type} loading={isLoading} emptyMessage={t("reports.empty")} />
        <p className="px-1 text-[11px] text-text-muted">{t("reports.salesService.revenueByTypeNote")}</p>
      </div>

      <div className="space-y-2">
        <p className="px-1 text-sm font-semibold text-text">{t("reports.salesService.invoiceTypeRatio")}</p>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
          {(data?.invoiceTypeRatio ?? []).map((r) => (
            <div key={r.type} className="rounded-xl border border-border bg-surface p-4">
              <p className="text-xs font-medium text-text-muted">{t(`reports.invoiceType.${r.type}`)}</p>
              <div className="mt-1 flex items-baseline gap-2">
                <p className="text-2xl font-bold text-text">{r.count}</p>
                <p className="text-sm font-semibold text-accent">{r.percent}%</p>
              </div>
              <p className="text-xs text-text-muted">{formatCurrency(r.total)}</p>
            </div>
          ))}
          {!isLoading && (data?.invoiceTypeRatio.length ?? 0) === 0 ? (
            <p className="text-sm text-text-muted">{t("reports.empty")}</p>
          ) : null}
        </div>
      </div>

      <div className="space-y-2">
        <p className="px-1 text-sm font-semibold text-text">{t("reports.salesService.technicianServiceCounts")}</p>
        <DataTable
          columns={techColumns}
          rows={data?.technicianServiceCounts ?? []}
          rowKey={(r) => r.technicianId}
          loading={isLoading}
          emptyMessage={t("reports.empty")}
        />
      </div>
    </div>
  )
}
