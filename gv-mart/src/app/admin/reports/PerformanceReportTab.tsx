import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Award, CheckCircle2, Inbox, TriangleAlert } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Skeleton } from "@/components/ui/skeleton"
import { KpiCard } from "@/components/shared/KpiCard"
import { useProfile } from "@/hooks/useProfile"
import { useOpsResolutionKpi, usePerformanceReport } from "@/hooks/useReports"
import { defaultDateRange, downloadCsv, toCsv, type DateRange } from "@/services/reports"
import { formatCurrency } from "@/lib/sale-calc"
import { cn } from "@/lib/utils"
import { DateRangeFilter } from "./DateRangeFilter"

// Design's scoreboard grid track widths (design-template-decoded.html line
// 1242: "0.5fr 1.6fr 1fr 1fr 1fr 1fr 0.9fr") — fractional tracks a <table>
// can't express, same rationale AmcWarrantyListPage.tsx uses for its
// bespoke CSS-grid rows instead of the shared <table>-based DataTable.
// Extended from 7 to 9 tracks for Requirement 8's avg-completion-time and
// productivity columns, inserted between "1st-fix" and "Reviews".
const SCOREBOARD_GRID = "grid-cols-[0.5fr_1.6fr_1fr_1fr_1fr_1fr_1fr_1fr_0.9fr]"

// "Xh Ym" once we cross an hour, plain minutes below that — kept simple per
// spec, no need for day-level rollover on a single service visit's duration.
function formatCompletionMinutes(minutes: number | null) {
  if (minutes == null) return "—"
  if (minutes < 60) return `${minutes} min`
  const hours = Math.floor(minutes / 60)
  const rest = minutes % 60
  return rest > 0 ? `${hours}h ${rest}m` : `${hours}h`
}

function formatProductivity(jobsPerHour: number | null) {
  if (jobsPerHour == null) return "—"
  return `${jobsPerHour.toFixed(1)} jobs/hr`
}

// Avatar swatch cycles through real design tokens only (ink/accent/info/
// success) — purely presentational, keyed to row order, not identity.
const AVATAR_COLORS = ["bg-ink", "bg-accent", "bg-info", "bg-success"]

function initials(name: string) {
  if (!name || name === "—") return "—"
  const parts = name.trim().split(/\s+/).filter(Boolean)
  return parts.slice(0, 2).map((p) => p[0]?.toUpperCase() ?? "").join("")
}

// Thresholds mirror the design's legend (≥90 strong / 80–89 watch / <80
// coach) applied to the real onTimePercent field — see reports.ts's comment
// on PerformanceRow.onTimePercent: "closest available signal of a clean
// first-time fix" (no needs_revisit on the visit == counted on-time).
function firstFixTone(percent: number | null) {
  if (percent == null) return "text-text-muted"
  if (percent >= 90) return "text-success"
  if (percent >= 80) return "text-warning"
  return "text-danger"
}

export function PerformanceReportTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const [range, setRange] = useState<DateRange>(() => defaultDateRange())

  const { data, isLoading, isError, refetch } = usePerformanceReport(profile?.org_id, range)
  const opsKpi = useOpsResolutionKpi(profile?.org_id, range)

  const topPerformerId = data && data.length > 0 && data[0].revenue > 0 ? data[0].id : null

  function handleExport() {
    if (!data) return
    const csv = toCsv(
      [
        t("reports.performance.person"),
        t("reports.performance.jobsDone"),
        t("reports.performance.onTimePercent"),
        t("reports.performance.avgCompletionTime"),
        t("reports.performance.revenue"),
        t("reports.performance.avgRating"),
        t("reports.performance.productivity"),
        t("reports.performance.conversion"),
      ],
      data.map((r) => [
        r.name,
        r.jobsDone,
        r.onTimePercent,
        r.avgCompletionMinutes,
        r.revenue,
        r.avgRating,
        r.productivityJobsPerHour,
        r.conversionPercent,
      ])
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
        <div className="rounded-card border border-border bg-surface-alt p-4 text-xs text-text-muted">{t("reports.performance.kpiNote")}</div>
      </div>

      <div className="rounded-card border border-border bg-surface p-[22px] shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
        <div className="mb-4 flex flex-wrap items-center justify-between gap-2">
          <h3 className="text-[17px] font-bold tracking-tight text-text">{t("reports.performance.scoreboardTitle")}</h3>
          <span className="text-[11px] font-semibold text-text-muted">{t("reports.performance.scoreboardCaption")}</span>
        </div>

        {isError ? (
          <div className="flex flex-col items-center gap-3 py-12 text-center">
            <TriangleAlert className="size-6 text-danger" />
            <p className="text-sm text-text-muted">{t("reports.loadFailed")}</p>
            <Button type="button" variant="outline" size="sm" onClick={() => refetch()}>
              {t("common.retry")}
            </Button>
          </div>
        ) : (
          <div className="overflow-hidden rounded-[10px] border border-border">
            <div className={cn("grid items-center bg-surface-alt px-3.5 py-2.5", SCOREBOARD_GRID)}>
              <span className="text-[10px] font-semibold uppercase tracking-wide text-text-muted">{t("reports.performance.rank")}</span>
              <span className="text-[10px] font-semibold uppercase tracking-wide text-text-muted">{t("reports.performance.person")}</span>
              <span className="text-[10px] font-semibold uppercase tracking-wide text-text-muted">{t("reports.performance.jobsShort")}</span>
              <span className="text-[10px] font-semibold uppercase tracking-wide text-text-muted">{t("reports.performance.avgPerCall")}</span>
              <span className="text-[10px] font-semibold uppercase tracking-wide text-text-muted">{t("reports.performance.firstFix")}</span>
              <span className="text-[10px] font-semibold uppercase tracking-wide text-text-muted">{t("reports.performance.avgCompletionTime")}</span>
              <span className="text-[10px] font-semibold uppercase tracking-wide text-text-muted">{t("reports.performance.productivity")}</span>
              <span className="text-[10px] font-semibold uppercase tracking-wide text-text-muted">{t("reports.performance.reviewsShort")}</span>
              <span className="text-right text-[10px] font-semibold uppercase tracking-wide text-text-muted">{t("reports.performance.conversion")}</span>
            </div>

            {isLoading ? (
              Array.from({ length: 5 }).map((_, i) => (
                <div key={i} className={cn("grid items-center border-t border-[#F1EDE6] px-3.5 py-3", SCOREBOARD_GRID)}>
                  {Array.from({ length: 9 }).map((_, j) => (
                    <Skeleton key={j} className="h-4 w-3/4 max-w-24" />
                  ))}
                </div>
              ))
            ) : (data ?? []).length === 0 ? (
              <div className="flex flex-col items-center gap-2 py-12 text-center">
                <Inbox className="size-6 text-text-muted" />
                <p className="text-sm text-text-muted">{t("reports.empty")}</p>
              </div>
            ) : (
              (data ?? []).map((r, i) => {
                const avgPerCall = r.jobsDone > 0 ? r.revenue / r.jobsDone : null
                return (
                  <div key={r.id} className={cn("grid items-center border-t border-[#F1EDE6] px-3.5 py-3", SCOREBOARD_GRID)}>
                    <span className={cn("text-xs font-extrabold", i === 0 ? "text-accent" : "text-text-muted")}>{i + 1}</span>
                    <div className="flex items-center gap-2">
                      <span
                        className={cn(
                          "flex size-7 shrink-0 items-center justify-center rounded-[8px] text-[10px] font-bold text-white",
                          AVATAR_COLORS[i % AVATAR_COLORS.length]
                        )}
                      >
                        {initials(r.name)}
                      </span>
                      <span className="flex items-center gap-1 text-xs font-semibold text-text">
                        {r.name}
                        {r.id === topPerformerId ? <Award className="size-3.5 text-warning" /> : null}
                      </span>
                    </div>
                    <span className="text-xs font-semibold tabular-nums text-text">{r.jobsDone}</span>
                    <span className="text-xs font-semibold tabular-nums text-text">{avgPerCall != null ? formatCurrency(avgPerCall) : "—"}</span>
                    <span className={cn("text-xs font-semibold tabular-nums", firstFixTone(r.onTimePercent))}>
                      {r.onTimePercent != null ? `${r.onTimePercent}%` : "—"}
                    </span>
                    <span className="text-xs font-semibold tabular-nums text-text">{formatCompletionMinutes(r.avgCompletionMinutes)}</span>
                    <span className="text-xs font-semibold tabular-nums text-text">{formatProductivity(r.productivityJobsPerHour)}</span>
                    <span className="text-xs font-semibold tabular-nums text-text">
                      {r.reviewCount}
                      {r.avgRating != null ? <span className="ml-1 font-medium text-text-muted">({r.avgRating}★)</span> : null}
                    </span>
                    <span className="text-right text-xs font-semibold tabular-nums text-text">
                      {r.conversionPercent != null ? `${r.conversionPercent}%` : "—"}
                    </span>
                  </div>
                )
              })
            )}
          </div>
        )}

        <div className="mt-3.5 flex flex-wrap items-center gap-4">
          <span className="text-[10px] font-semibold text-text-muted">{t("reports.performance.legendCaption")}</span>
          <LegendDot toneClass="text-success" dotClass="bg-success" label={t("reports.performance.legendStrong")} />
          <LegendDot toneClass="text-warning" dotClass="bg-warning" label={t("reports.performance.legendWatch")} />
          <LegendDot toneClass="text-danger" dotClass="bg-danger" label={t("reports.performance.legendCoach")} />
        </div>
      </div>
    </div>
  )
}

function LegendDot({ toneClass, dotClass, label }: { toneClass: string; dotClass: string; label: string }) {
  return (
    <span className={cn("flex items-center gap-1.5 text-[10px] font-semibold", toneClass)}>
      <span className={cn("size-2 shrink-0 rounded-full", dotClass)} />
      {label}
    </span>
  )
}
