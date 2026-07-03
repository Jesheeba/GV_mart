import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Award, CheckCircle2 } from "lucide-react"
import { KpiCard } from "@/components/shared/KpiCard"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { useProfile } from "@/hooks/useProfile"
import { useOpsResolutionKpi, usePerformanceReport } from "@/hooks/useReports"
import { defaultDateRange, downloadCsv, toCsv, type DateRange } from "@/services/reports"
import type { PerformanceRow } from "@/services/reports"
import { formatCurrency } from "@/lib/sale-calc"
import { DateRangeFilter } from "./DateRangeFilter"

export function PerformanceReportTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const [range, setRange] = useState<DateRange>(() => defaultDateRange())

  const { data, isLoading, isError, refetch } = usePerformanceReport(profile?.org_id, range)
  const opsKpi = useOpsResolutionKpi(profile?.org_id, range)

  const columns: DataTableColumn<PerformanceRow>[] = [
    {
      key: "name",
      header: t("reports.performance.person"),
      render: (r) => (
        <div className="flex items-center gap-1.5">
          {r.revenue > 0 && data && data[0]?.id === r.id ? <Award className="size-3.5 text-warning" /> : null}
          <span className="font-medium text-text">{r.name}</span>
        </div>
      ),
    },
    { key: "jobs", header: t("reports.performance.jobsDone"), render: (r) => r.jobsDone },
    { key: "onTime", header: t("reports.performance.onTimePercent"), render: (r) => (r.onTimePercent != null ? `${r.onTimePercent}%` : "—") },
    { key: "revenue", header: t("reports.performance.revenue"), render: (r) => formatCurrency(r.revenue) },
    { key: "rating", header: t("reports.performance.avgRating"), render: (r) => (r.avgRating != null ? `${r.avgRating} ★ (${r.reviewCount})` : "—") },
    { key: "conversion", header: t("reports.performance.conversion"), render: (r) => (r.conversionPercent != null ? `${r.conversionPercent}%` : "—") },
  ]

  function handleExport() {
    if (!data) return
    const csv = toCsv(
      [
        t("reports.performance.person"),
        t("reports.performance.jobsDone"),
        t("reports.performance.onTimePercent"),
        t("reports.performance.revenue"),
        t("reports.performance.avgRating"),
        t("reports.performance.conversion"),
      ],
      data.map((r) => [r.name, r.jobsDone, r.onTimePercent, r.revenue, r.avgRating, r.conversionPercent])
    )
    downloadCsv(`performance-report_${range.from}_${range.to}.csv`, csv)
  }

  return (
    <div className="space-y-4">
      <DateRangeFilter range={range} onChange={setRange} onExport={handleExport} />

      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <KpiCard
          label={t("reports.performance.opsKpiLabel")}
          value={opsKpi.data?.percent != null ? `${opsKpi.data.percent}%` : "—"}
          icon={<CheckCircle2 className="size-4" />}
          loading={opsKpi.isLoading}
        />
        <div className="rounded-card border border-border bg-surface p-4 text-xs text-text-muted">{t("reports.performance.kpiNote")}</div>
      </div>

      {isError ? (
        <p className="text-sm text-danger">
          {t("reports.loadFailed")}{" "}
          <button type="button" className="underline" onClick={() => refetch()}>
            {t("common.retry")}
          </button>
        </p>
      ) : (
        <DataTable columns={columns} rows={data ?? []} rowKey={(r) => r.id} loading={isLoading} emptyMessage={t("reports.empty")} />
      )}
    </div>
  )
}
