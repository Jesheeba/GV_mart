import { useState } from "react"
import { useTranslation } from "react-i18next"
import { useProfile } from "@/hooks/useProfile"
import { usePnlReport } from "@/hooks/useReports"
import { defaultDateRange, downloadCsv, toCsv, type DateRange } from "@/services/reports"
import { formatCurrency } from "@/lib/sale-calc"
import { cn } from "@/lib/utils"
import { Skeleton } from "@/components/ui/skeleton"
import { DateRangeFilter } from "./DateRangeFilter"

// Expense bar color rank: biggest category = ink, smallest = the muted
// tan-grey swatch already established in AmcWarrantyListPage.tsx (tier-0
// swatch, #C9C4BA) for a "third neutral tone" beyond ink/accent, everything
// in between = accent.
function barColor(index: number, count: number) {
  if (index === 0) return "bg-ink"
  if (count > 1 && index === count - 1) return "bg-[#C9C4BA]"
  return "bg-accent"
}

export function PnlReportTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const [range, setRange] = useState<DateRange>(() => defaultDateRange())
  const [withGst, setWithGst] = useState(true)

  const { data, isLoading, isError, refetch } = usePnlReport(profile?.org_id, range)
  const isMaster = profile?.role === "master"

  const revenue = withGst ? data?.revenueWithGst : data?.revenueWithoutGst
  const netProfit = withGst ? data?.netProfitWithGst : data?.netProfitWithoutGst

  // "purchase" is the expense category used for stock/inventory buy-ins
  // (supabase expense_category enum: marketing/stationery/salary/petrol/
  // purchase/other) — the closest real analog to "Cost of Goods". Every
  // other category is bucketed as Operating Expenses. The two always sum to
  // data.totalExpenses exactly, so Revenue − COGS − OpEx === the real
  // netProfit figure below (no separate math is invented).
  const costOfGoods = data?.expensesByCategory.find((e) => e.category === "purchase")?.amount ?? 0
  const operatingExpenses = (data?.totalExpenses ?? 0) - costOfGoods

  const sortedExpenses = [...(data?.expensesByCategory ?? [])].sort((a, b) => b.amount - a.amount)
  const maxExpense = Math.max(1, ...sortedExpenses.map((e) => e.amount))

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
      <DateRangeFilter range={range} onChange={setRange} onExport={handleExport} />

      <div className="flex items-center gap-2">
        <span className="text-sm font-medium text-text">{t("reports.pnl.gstToggle")}</span>
        <div className="flex gap-[3px] rounded-full border border-border bg-surface-alt p-1">
          <button
            type="button"
            onClick={() => setWithGst(true)}
            aria-pressed={withGst}
            className={cn("rounded-full px-4 py-[7px] text-xs font-semibold transition-colors", withGst ? "bg-ink text-white" : "text-text-muted")}
          >
            {t("reports.pnl.withGst")}
          </button>
          <button
            type="button"
            onClick={() => setWithGst(false)}
            aria-pressed={!withGst}
            className={cn("rounded-full px-4 py-[7px] text-xs font-semibold transition-colors", !withGst ? "bg-ink text-white" : "text-text-muted")}
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
        <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
          <div className="rounded-card border border-border bg-surface p-6 shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
            <h3 className="mb-[18px] text-[17px] font-bold tracking-tight text-text">{t("reports.pnl.title")}</h3>
            {isLoading ? (
              <div className="space-y-4">
                {Array.from({ length: 4 }).map((_, i) => (
                  <Skeleton key={i} className="h-5 w-full" />
                ))}
                <Skeleton className="h-14 w-full rounded-[14px]" />
              </div>
            ) : (
              <>
                <PnlRow label={t("reports.pnl.revenue")} value={revenue !== undefined ? formatCurrency(revenue) : "—"} />
                <PnlRow label={t("reports.pnl.costOfGoods")} value={`− ${formatCurrency(costOfGoods)}`} tone="danger" />
                <PnlRow label={t("reports.pnl.operatingExpenses")} value={`− ${formatCurrency(operatingExpenses)}`} tone="danger" />
                {withGst && data ? <PnlRow label={t("reports.pnl.gstCollected")} value={formatCurrency(data.gstCollected)} /> : null}

                <div
                  className={cn(
                    "mt-3.5 flex items-center justify-between rounded-[14px] px-4 py-3.5",
                    netProfit !== undefined && netProfit < 0 ? "bg-danger/10" : "bg-success/10"
                  )}
                >
                  <span className={cn("text-sm font-bold", netProfit !== undefined && netProfit < 0 ? "text-danger" : "text-success")}>
                    {t("reports.pnl.netProfit")}
                  </span>
                  <span
                    className={cn(
                      "text-[22px] font-extrabold tracking-tight tabular-nums",
                      netProfit !== undefined && netProfit < 0 ? "text-danger" : "text-success"
                    )}
                  >
                    {netProfit !== undefined ? formatCurrency(netProfit) : "—"}
                  </span>
                </div>
                {withGst ? <p className="mt-2 text-[11px] text-text-muted">{t("reports.pnl.gstCollectedNote")}</p> : null}
              </>
            )}
          </div>

          <div className="rounded-card border border-border bg-surface p-6 shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
            <h3 className="mb-[18px] text-[17px] font-bold tracking-tight text-text">{t("reports.pnl.expenseBreakdown")}</h3>
            {isLoading ? (
              <div className="space-y-4">
                {Array.from({ length: 4 }).map((_, i) => (
                  <Skeleton key={i} className="h-8 w-full" />
                ))}
              </div>
            ) : sortedExpenses.length === 0 ? (
              <p className="text-sm text-text-muted">{t("reports.empty")}</p>
            ) : (
              <div className="flex flex-col gap-4">
                {sortedExpenses.map((e, i) => (
                  <div key={e.category}>
                    <div className="mb-[7px] flex items-center justify-between">
                      <span className="text-[13px] font-semibold text-text">{t(`reports.pnl.expenseCategory.${e.category}`)}</span>
                      <span className="text-[13px] font-bold tabular-nums text-text">{formatCurrency(e.amount)}</span>
                    </div>
                    <div className="h-2 overflow-hidden rounded-full bg-border">
                      <div
                        className={cn("h-full rounded-full", barColor(i, sortedExpenses.length))}
                        style={{ width: `${Math.max(4, Math.round((e.amount / maxExpense) * 100))}%` }}
                      />
                    </div>
                  </div>
                ))}
              </div>
            )}
          </div>
        </div>
      )}

      <p className="text-xs text-text-muted">{t("reports.pnl.dataSafetyNote")}</p>
    </div>
  )
}

function PnlRow({ label, value, tone }: { label: string; value: string; tone?: "danger" }) {
  return (
    <div className="flex items-center justify-between border-b border-[#F1EDE6] py-[11px]">
      <span className="text-[13px] font-medium text-text-muted">{label}</span>
      <span className={cn("text-[15px] font-bold tabular-nums", tone === "danger" ? "text-danger" : "text-text")}>{value}</span>
    </div>
  )
}
