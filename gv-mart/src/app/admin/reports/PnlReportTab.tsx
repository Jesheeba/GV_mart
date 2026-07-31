import { useState } from "react"
import { useTranslation } from "react-i18next"
import { zodResolver } from "@hookform/resolvers/zod"
import { Controller, useForm } from "react-hook-form"
import { Loader2, Plus } from "lucide-react"
import { useProfile } from "@/hooks/useProfile"
import { usePnlReport, useCreateExpense } from "@/hooks/useReports"
import { defaultPeriodValue, downloadCsv, periodToRange, toCsv, type PeriodValue } from "@/services/reports"
import { createExpenseSchema, expenseCategories, type CreateExpenseFormInput, type CreateExpenseOutput } from "@/lib/validation/reports"
import { formatCurrency } from "@/lib/sale-calc"
import { cn } from "@/lib/utils"
import type { Enums } from "@/types/database"
import { Skeleton } from "@/components/ui/skeleton"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { DatePicker } from "@/components/ui/date-picker"
import { PeriodFilter } from "./PeriodFilter"

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
  const [period, setPeriod] = useState<PeriodValue>(defaultPeriodValue())
  const range = periodToRange(period)
  const [withGst, setWithGst] = useState(true)
  const [showLogExpense, setShowLogExpense] = useState(false)
  // F2 category filter — scopes the Expense Breakdown panel below to one
  // expense_category (reusing the same expenseCategories/expenseCategory.*
  // i18n pattern LogExpensePanel already uses). Revenue/COGS/OpEx/Net Profit
  // above stay whole-business figures regardless of this filter — slicing
  // "Net Profit" down to a single expense category wouldn't mean anything.
  const [category, setCategory] = useState<Enums<"expense_category"> | "all">("all")

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

  const categoryFilteredExpenses = category === "all" ? (data?.expensesByCategory ?? []) : (data?.expensesByCategory ?? []).filter((e) => e.category === category)
  const sortedExpenses = [...categoryFilteredExpenses].sort((a, b) => b.amount - a.amount)
  const maxExpense = Math.max(1, ...sortedExpenses.map((e) => e.amount))

  function handleExport() {
    if (!data) return
    const csv = toCsv(
      [t("reports.pnl.category"), t("reports.pnl.amount")],
      [
        [t("reports.pnl.revenue"), revenue ?? 0],
        [t("reports.pnl.totalExpenses"), data.totalExpenses],
        [t("reports.pnl.netProfit"), netProfit ?? 0],
        ...categoryFilteredExpenses.map((e) => [t(`reports.pnl.expenseCategory.${e.category}`), e.amount]),
      ]
    )
    downloadCsv(`pnl-report_${range.from}_${range.to}.csv`, csv)
  }

  if (!isMaster) {
    return <p className="text-sm text-text-muted">{t("reports.pnl.masterOnlyNote")}</p>
  }

  return (
    <div className="space-y-4">
      <PeriodFilter value={period} onChange={setPeriod} onExport={handleExport} />

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
            <div className="mb-[18px] flex flex-wrap items-center justify-between gap-2">
              <h3 className="text-[17px] font-bold tracking-tight text-text">{t("reports.pnl.expenseBreakdown")}</h3>
              <div className="flex items-center gap-2">
                <select
                  value={category}
                  onChange={(e) => setCategory(e.target.value as Enums<"expense_category"> | "all")}
                  aria-label={t("reports.filters.category")}
                  className="h-9 rounded-xl border border-border bg-surface px-3 text-xs text-text outline-none"
                >
                  <option value="all">{t("reports.filters.allCategories")}</option>
                  {expenseCategories.map((c) => (
                    <option key={c} value={c}>
                      {t(`reports.pnl.expenseCategory.${c}`)}
                    </option>
                  ))}
                </select>
                <Button size="sm" variant="outline" onClick={() => setShowLogExpense((v) => !v)}>
                  <Plus className="size-4" />
                  {t("reports.pnl.logExpense")}
                </Button>
              </div>
            </div>

            {showLogExpense ? (
              <LogExpensePanel
                orgId={profile?.org_id}
                onClose={() => setShowLogExpense(false)}
                onLogged={() => setShowLogExpense(false)}
              />
            ) : null}

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

      {!isError ? (
        <div className="rounded-card border border-border bg-surface p-6 shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
          <h3 className="mb-[18px] text-[17px] font-bold tracking-tight text-text">{t("reports.pnl.itemProfitTitle")}</h3>
          {isLoading ? (
            <div className="space-y-4">
              {Array.from({ length: 3 }).map((_, i) => (
                <Skeleton key={i} className="h-5 w-full" />
              ))}
              <Skeleton className="h-14 w-full rounded-[14px]" />
            </div>
          ) : data ? (
            <>
              <PnlRow label={t("reports.pnl.itemRevenue")} value={formatCurrency(data.itemProfit.revenue)} />
              <PnlRow label={t("reports.pnl.itemCost")} value={`− ${formatCurrency(data.itemProfit.cost)}`} tone="danger" />
              <PnlRow label={t("reports.pnl.giftsCost")} value={`− ${formatCurrency(data.itemProfit.giftsCost)}`} tone="danger" />

              <div
                className={cn(
                  "mt-3.5 flex items-center justify-between rounded-[14px] px-4 py-3.5",
                  data.itemProfit.profit < 0 ? "bg-danger/10" : "bg-success/10"
                )}
              >
                <span className={cn("text-sm font-bold", data.itemProfit.profit < 0 ? "text-danger" : "text-success")}>
                  {t("reports.pnl.realProfit")}
                </span>
                <span className={cn("text-[22px] font-extrabold tracking-tight tabular-nums", data.itemProfit.profit < 0 ? "text-danger" : "text-success")}>
                  {formatCurrency(data.itemProfit.profit)}
                </span>
              </div>
              <p className="mt-2 text-[11px] text-text-muted">{t("reports.pnl.itemProfitNote")}</p>
              {data.itemProfit.missingCostCount > 0 ? (
                <p className="mt-1 text-[11px] text-danger">
                  {t("reports.pnl.itemProfitMissingCostNote", { count: data.itemProfit.missingCostCount })}
                </p>
              ) : null}
            </>
          ) : null}
        </div>
      ) : null}

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

/** Inline "Log Expense" panel (ADM-28 gap fix) — mirrors the inline-expand
 * form convention established by SellAmcPanel.tsx (amc module): a button
 * toggles this panel open, react-hook-form + zodResolver validates, and a
 * successful submit calls back up to collapse the panel. Kept local to this
 * file rather than split out, since this is the only place `expenses` is
 * written to from the UI. */
function LogExpensePanel({ orgId, onClose, onLogged }: { orgId: string | undefined; onClose: () => void; onLogged: () => void }) {
  const { t } = useTranslation()
  const createExpense = useCreateExpense()

  const form = useForm<CreateExpenseFormInput, unknown, CreateExpenseOutput>({
    resolver: zodResolver(createExpenseSchema),
    mode: "onChange",
    defaultValues: { category: "marketing", amount: 0, date: new Date().toISOString().slice(0, 10) },
  })

  async function onSubmit(values: CreateExpenseOutput) {
    if (!orgId) return
    await createExpense.mutateAsync({ orgId, category: values.category, amount: values.amount, date: values.date })
    onLogged()
  }

  return (
    <Card className="mb-4 gap-3 px-5">
      <div className="flex items-center justify-between">
        <h4 className="text-sm font-semibold text-text">{t("reports.pnl.logExpense")}</h4>
        <Button size="sm" variant="ghost" onClick={onClose}>
          {t("common.cancel")}
        </Button>
      </div>

      <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
        <div className="space-y-1.5">
          <Label>{t("reports.pnl.category")}</Label>
          <select
            {...form.register("category")}
            className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
          >
            {expenseCategories.map((c) => (
              <option key={c} value={c}>
                {t(`reports.pnl.expenseCategory.${c}`)}
              </option>
            ))}
          </select>
          {form.formState.errors.category ? <p className="text-xs text-danger">{t(form.formState.errors.category.message!)}</p> : null}
        </div>
        <div className="space-y-1.5">
          <Label>{t("reports.pnl.amount")}</Label>
          <Input type="number" min={0} step="0.01" {...form.register("amount")} />
          {form.formState.errors.amount ? <p className="text-xs text-danger">{t(form.formState.errors.amount.message!)}</p> : null}
        </div>
        <div className="space-y-1.5">
          <Label>{t("reports.pnl.date")}</Label>
          <Controller control={form.control} name="date" render={({ field }) => <DatePicker value={field.value ?? ""} onChange={field.onChange} />} />
          {form.formState.errors.date ? <p className="text-xs text-danger">{t(form.formState.errors.date.message!)}</p> : null}
        </div>
      </div>

      {createExpense.error ? <p className="rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{(createExpense.error as Error).message}</p> : null}

      <div className="flex justify-end">
        <Button onClick={form.handleSubmit(onSubmit)} disabled={createExpense.isPending || !orgId}>
          {createExpense.isPending ? <Loader2 className="size-4 animate-spin" /> : t("common.save")}
        </Button>
      </div>
    </Card>
  )
}
