import { useState } from "react"
import { useTranslation } from "react-i18next"
import { IndianRupee, TrendingDown, TrendingUp } from "lucide-react"
import { HighlightKpiCard } from "@/components/shared/HighlightKpiCard"
import { KpiCard } from "@/components/shared/KpiCard"
import { useProfile } from "@/hooks/useProfile"
import { usePnlReport } from "@/hooks/useReports"
import { defaultDateRange, downloadCsv, toCsv, type DateRange } from "@/services/reports"
import { formatCurrency } from "@/lib/sale-calc"
import { cn } from "@/lib/utils"
import { DateRangeFilter } from "./DateRangeFilter"

export function PnlReportTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const [range, setRange] = useState<DateRange>(() => defaultDateRange())
  const [withGst, setWithGst] = useState(true)

  const { data, isLoading, isError, refetch } = usePnlReport(profile?.org_id, range)
  const isMaster = profile?.role === "master"

  const revenue = withGst ? data?.revenueWithGst : data?.revenueWithoutGst
  const netProfit = withGst ? data?.netProfitWithGst : data?.netProfitWithoutGst

  function handleExport() {
    if (!data) return
    const csv = toCsv(
      [t("reports.pnl.category"), t("reports.pnl.amount")],
      [
        [t("reports.pnl.revenue"), revenue ?? 0],
        [t("reports.pnl.totalExpenses"), data.totalExpenses],
        [t("reports.pnl.netProfit"), netProfit ?? 0],
        ...data.expensesByCategory.map((e) => [t(`reports.pnl.expenseCategory.${e.category}`), e.amount]),
      ]
    )
    downloadCsv(`pnl-report_${range.from}_${range.to}.csv`, csv)
  }

  if (!isMaster) {
    return <p className="text-sm text-text-muted">{t("reports.pnl.masterOnlyNote")}</p>
  }

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <DateRangeFilter range={range} onChange={setRange} onExport={handleExport} />
      </div>

      <div className="flex items-center gap-2">
        <span className="text-sm font-medium text-text">{t("reports.pnl.gstToggle")}</span>
        <div className="flex gap-1 rounded-full bg-surface-alt p-1">
          <button
            type="button"
            onClick={() => setWithGst(true)}
            aria-pressed={withGst}
            className={cn("rounded-full px-3 py-1.5 text-sm font-medium transition-colors", withGst ? "bg-ink text-white" : "text-text-muted")}
          >
            {t("reports.pnl.withGst")}
          </button>
          <button
            type="button"
            onClick={() => setWithGst(false)}
            aria-pressed={!withGst}
            className={cn("rounded-full px-3 py-1.5 text-sm font-medium transition-colors", !withGst ? "bg-ink text-white" : "text-text-muted")}
          >
            {t("reports.pnl.withoutGst")}
          </button>
        </div>
      </div>

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
            label={t("reports.pnl.revenue")}
            value={revenue !== undefined ? formatCurrency(revenue) : "—"}
            icon={<IndianRupee className="size-4" />}
            loading={isLoading}
          />
          <KpiCard label={t("reports.pnl.totalExpenses")} value={data ? formatCurrency(data.totalExpenses) : "—"} icon={<TrendingDown className="size-4" />} loading={isLoading} />
          <KpiCard
            label={t("reports.pnl.netProfit")}
            value={netProfit !== undefined ? formatCurrency(netProfit) : "—"}
            icon={<TrendingUp className="size-4" />}
            loading={isLoading}
            className={netProfit !== undefined && netProfit < 0 ? "border-danger/40" : undefined}
          />
        </div>
      )}

      <div className="space-y-2">
        <p className="px-1 text-sm font-semibold text-text">{t("reports.pnl.expenseBreakdown")}</p>
        {isLoading ? (
          <p className="text-sm text-text-muted">{t("common.loading")}</p>
        ) : (data?.expensesByCategory.length ?? 0) === 0 ? (
          <p className="text-sm text-text-muted">{t("reports.empty")}</p>
        ) : (
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-6">
            {data!.expensesByCategory.map((e) => (
              <div key={e.category} className="rounded-xl border border-border bg-surface p-3">
                <p className="text-xs font-medium text-text-muted">{t(`reports.pnl.expenseCategory.${e.category}`)}</p>
                <p className="mt-1 text-lg font-bold text-text">{formatCurrency(e.amount)}</p>
              </div>
            ))}
          </div>
        )}
      </div>

      <p className="text-xs text-text-muted">{t("reports.pnl.dataSafetyNote")}</p>
    </div>
  )
}
