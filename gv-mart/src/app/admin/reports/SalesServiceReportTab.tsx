import { useState } from "react"
import { useTranslation } from "react-i18next"
import { IndianRupee, PhoneCall, ReceiptText, Wrench } from "lucide-react"
import { KpiCard } from "@/components/shared/KpiCard"
import { HighlightKpiCard } from "@/components/shared/HighlightKpiCard"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { useProfile } from "@/hooks/useProfile"
import { useSalesServiceReport } from "@/hooks/useReports"
import { defaultDateRange, downloadCsv, toCsv, type DateRange } from "@/services/reports"
import { formatCurrency } from "@/lib/sale-calc"
import { DateRangeFilter } from "./DateRangeFilter"

export function SalesServiceReportTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const [range, setRange] = useState<DateRange>(() => defaultDateRange())

  const { data, isLoading, isError, refetch } = useSalesServiceReport(profile?.org_id, range)

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
      <DateRangeFilter range={range} onChange={setRange} onExport={handleExport} />

      {isError ? (
        <p className="text-sm text-danger">
          {t("reports.loadFailed")}{" "}
          <button type="button" className="underline" onClick={() => refetch()}>
            {t("common.retry")}
          </button>
        </p>
      ) : (
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <HighlightKpiCard
            label={t("reports.salesService.totalRevenue")}
            value={data ? formatCurrency(data.totalRevenue) : "—"}
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
      )}

      <div className="space-y-2">
        <p className="px-1 text-sm font-semibold text-text">{t("reports.salesService.invoiceTypeRatio")}</p>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
          {(data?.invoiceTypeRatio ?? []).map((r) => (
            <div key={r.type} className="rounded-xl border border-border bg-surface p-4">
              <p className="text-xs font-medium text-text-muted">{t(`reports.invoiceType.${r.type}`)}</p>
              <p className="mt-1 text-2xl font-bold text-text">{r.count}</p>
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
