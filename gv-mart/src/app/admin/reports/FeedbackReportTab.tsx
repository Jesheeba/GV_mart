import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Star } from "lucide-react"
import { HighlightKpiCard } from "@/components/shared/HighlightKpiCard"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { useProfile } from "@/hooks/useProfile"
import { useFeedbackReport } from "@/hooks/useReports"
import { defaultDateRange, downloadCsv, periodToRange, toCsv, type FeedbackReport, type PeriodValue } from "@/services/reports"
import { PeriodFilter } from "./PeriodFilter"

export function FeedbackReportTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  // NPS/feedback trend analysis genuinely wants a wider default window than
  // "this month" (defaultPeriodValue's default) — starts in Custom-range
  // mode with the original rolling 90-day window; switching to Month/Year
  // mode still works normally from there.
  const [period, setPeriod] = useState<PeriodValue>(() => ({ mode: "range", range: defaultDateRange(90) }))
  const range = periodToRange(period)

  const { data, isLoading, isError, refetch } = useFeedbackReport(profile?.org_id, range)

  const columns: DataTableColumn<FeedbackReport["lowRatingEntries"][number]>[] = [
    { key: "date", header: t("reports.feedback.date"), render: (r) => new Date(r.createdAt).toLocaleDateString() },
    { key: "customer", header: t("reports.feedback.customer"), render: (r) => r.customerName ?? "—" },
    { key: "technician", header: t("reports.feedback.technician"), render: (r) => r.technicianName ?? "—" },
    {
      key: "stars",
      header: t("reports.feedback.stars"),
      render: (r) => (
        <span className="flex items-center gap-1">
          <Star className="size-3.5 fill-warning text-warning" /> {r.stars}
        </span>
      ),
    },
    { key: "reason", header: t("reports.feedback.reason"), render: (r) => r.reason ?? t("reports.feedback.noReason") },
  ]

  function handleExport() {
    if (!data) return
    const csv = toCsv(
      [t("reports.feedback.date"), t("reports.feedback.customer"), t("reports.feedback.technician"), t("reports.feedback.stars"), t("reports.feedback.reason")],
      data.lowRatingEntries.map((r) => [new Date(r.createdAt).toLocaleDateString(), r.customerName, r.technicianName, r.stars, r.reason])
    )
    downloadCsv(`feedback-report_${range.from}_${range.to}.csv`, csv)
  }

  const maxCount = data ? Math.max(1, ...data.starsDistribution.map((d) => d.count)) : 1

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
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
          <HighlightKpiCard
            label={t("reports.feedback.averageRating")}
            value={data?.averageRating != null ? `${data.averageRating} ★` : "—"}
            icon={<Star className="size-4" />}
            loading={isLoading}
          />
          <div className="rounded-card border border-border bg-surface p-4 sm:col-span-2">
            <p className="mb-2 text-xs font-medium text-text-muted">{t("reports.feedback.starsDistribution")}</p>
            <div className="space-y-1.5">
              {(data?.starsDistribution ?? []).slice().reverse().map((d) => (
                <div key={d.stars} className="flex items-center gap-2">
                  <span className="w-10 shrink-0 text-xs text-text-muted">{d.stars} ★</span>
                  <div className="h-2.5 flex-1 overflow-hidden rounded-full bg-surface-alt">
                    <div className="h-full rounded-full bg-accent" style={{ width: `${(d.count / maxCount) * 100}%` }} />
                  </div>
                  <span className="w-8 shrink-0 text-right text-xs text-text-muted">{d.count}</span>
                </div>
              ))}
            </div>
          </div>
        </div>
      )}

      <div className="space-y-2">
        <p className="px-1 text-sm font-semibold text-text">{t("reports.feedback.trendTitle")}</p>
        {isLoading ? (
          <p className="text-sm text-text-muted">{t("common.loading")}</p>
        ) : (data?.trend.length ?? 0) === 0 ? (
          <p className="text-sm text-text-muted">{t("reports.empty")}</p>
        ) : (
          <div className="flex items-end gap-1 overflow-x-auto rounded-card border border-border bg-surface p-4">
            {data!.trend.map((pt) => (
              <div key={pt.date} className="flex w-8 shrink-0 flex-col items-center gap-1" title={`${pt.date}: ${pt.averageRating}`}>
                <div className="flex h-24 w-full items-end">
                  <div className="w-full rounded-t bg-ink" style={{ height: `${(pt.averageRating / 5) * 100}%` }} />
                </div>
                <span className="text-[10px] text-text-muted">{pt.date.slice(5)}</span>
              </div>
            ))}
          </div>
        )}
      </div>

      <div className="space-y-2">
        <p className="px-1 text-sm font-semibold text-text">{t("reports.feedback.lowRatingsTitle")}</p>
        <DataTable columns={columns} rows={data?.lowRatingEntries ?? []} rowKey={(r) => r.ratingId} loading={isLoading} emptyMessage={t("reports.feedback.noLowRatings")} />
      </div>
    </div>
  )
}
