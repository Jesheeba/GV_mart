import { useState } from "react"
import { useNavigate } from "react-router-dom"
import { toLocalDateString } from "@/lib/local-date"
import { useTranslation } from "react-i18next"
import { zodResolver } from "@hookform/resolvers/zod"
import { Controller, useForm } from "react-hook-form"
import { Loader2, Plus, TrendingDown, ListTodo } from "lucide-react"
import { useProfile } from "@/hooks/useProfile"
import { usePnlReport, useCreateExpense, useExpensesList, useExpensesYearOverYear, useOpenRecurringTasks, useSalarySpendByStaff } from "@/hooks/useReports"
import {
  useExpenseCategories,
  useCreateExpenseCategory,
  useRenameExpenseCategory,
  useDeactivateExpenseCategory,
  useDeleteExpenseCategory,
  useOverdueOrDueTodayReminderCount,
} from "@/hooks/useAccountsFollowup"
import { defaultPeriodValue, periodToRange, type PeriodValue } from "@/services/reports"
import { createExpenseSchema, type CreateExpenseFormInput, type CreateExpenseOutput } from "@/lib/validation/reports"
import { resolveLegacyExpenseCategoryEnum } from "@/services/reportMappers"
import { formatCurrency } from "@/lib/sale-calc"
import { cn } from "@/lib/utils"
import { Skeleton } from "@/components/ui/skeleton"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { DatePicker } from "@/components/ui/date-picker"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import { PeriodFilter } from "../reports/PeriodFilter"
import { PnlReportTab } from "../reports/PnlReportTab"

/** Accounts / Expenses (money-out) dashboard — 2026-09-24 change request
 * against the v2.2 scope guard's "bank-payment-tracking screen" item (see
 * 20260924120000_expense_tracking_change_request.sql). This tracks what the
 * business spent (salary/rent/EB/other), not anything about a bank account —
 * no bank_accounts table, no reconciliation, exists or is planned here.
 *
 * 2026-10-28 nav audit: the full P&L report moved here from Reports (both
 * pulled the same usePnlReport data, just styled differently — one home now)
 * as a second tab, alongside this page's existing overview. */
export function AccountsPage() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const isMaster = profile?.role === "master"

  if (!isMaster) {
    return <p className="text-sm text-text-muted">{t("accounts.masterOnlyNote")}</p>
  }

  return (
    <div className="space-y-4 pt-2">
      <div>
        <h1 className="text-2xl font-bold text-text">{t("accounts.title")}</h1>
        <p className="text-sm text-text-muted">{t("accounts.subtitle")}</p>
      </div>

      <Tabs defaultValue="overview">
        <TabsList>
          <TabsTrigger value="overview">{t("accounts.tabs.overview")}</TabsTrigger>
          <TabsTrigger value="pnl">{t("accounts.tabs.pnl")}</TabsTrigger>
        </TabsList>
        <TabsContent value="overview" className="mt-3">
          <AccountsOverviewTab orgId={profile?.org_id} />
        </TabsContent>
        <TabsContent value="pnl" className="mt-3">
          <PnlReportTab />
        </TabsContent>
      </Tabs>
    </div>
  )
}

function AccountsOverviewTab({ orgId }: { orgId: string | undefined }) {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const [period, setPeriod] = useState<PeriodValue>(defaultPeriodValue())
  const range = periodToRange(period)
  const [showLogExpense, setShowLogExpense] = useState(false)
  const [showManageCategories, setShowManageCategories] = useState(false)
  const [categoryFilter, setCategoryFilter] = useState("")

  const { data: pnl, isLoading: pnlLoading } = usePnlReport(orgId, range)
  const { data: yoy, isLoading: yoyLoading } = useExpensesYearOverYear(orgId, 3)
  const { data: expenses, isLoading: expensesLoading, isError: expensesError, refetch } = useExpensesList(orgId, range)
  const { data: salaryByStaff, isLoading: salaryByStaffLoading } = useSalarySpendByStaff(orgId, range)

  // Reminder-management batch, item 3: ONE resolved "Category" per expense (see
  // resolveExpenseCategoryName), with a filter and a per-category total for the
  // selected date range -- both computed client-side from the already-fetched list.
  const categoryTotals = (() => {
    const totals = new Map<string, number>()
    for (const e of expenses ?? []) {
      const name = e.categoryName ?? t("accounts.uncategorised")
      totals.set(name, (totals.get(name) ?? 0) + e.amount)
    }
    return Array.from(totals.entries())
      .map(([name, total]) => ({ name, total }))
      .sort((a, b) => b.total - a.total)
  })()
  const filteredExpenses = categoryFilter ? (expenses ?? []).filter((e) => (e.categoryName ?? t("accounts.uncategorised")) === categoryFilter) : expenses

  const currentYearRow = yoy?.[0]
  const priorYearRow = yoy?.[1]
  const yoyDeltaPct =
    currentYearRow && priorYearRow && priorYearRow.ytdComparableTotal > 0
      ? Math.round(((currentYearRow.ytdComparableTotal - priorYearRow.ytdComparableTotal) / priorYearRow.ytdComparableTotal) * 100)
      : null

  const overdueOrDueTodayCount = useOverdueOrDueTodayReminderCount()

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap justify-end gap-2">
        <Button variant="outline" onClick={() => navigate("/accounts/outstanding")} className="relative">
          <ListTodo className="size-4" />
          {t("accounts.outstanding.navLink")}
          {overdueOrDueTodayCount > 0 ? (
            <span className="absolute -right-1.5 -top-1.5 flex size-5 items-center justify-center rounded-full bg-danger text-[11px] font-bold text-white">
              {overdueOrDueTodayCount > 9 ? "9+" : overdueOrDueTodayCount}
            </span>
          ) : null}
        </Button>
        <Button variant="outline" onClick={() => setShowManageCategories(true)}>
          {t("accounts.manageCategories")}
        </Button>
        <Button onClick={() => setShowLogExpense((v) => !v)}>
          <Plus className="size-4" />
          {t("accounts.logExpense")}
        </Button>
      </div>

      {showLogExpense ? (
        <LogExpensePanel orgId={orgId} onClose={() => setShowLogExpense(false)} onLogged={() => setShowLogExpense(false)} />
      ) : null}

      {showManageCategories ? <ManageCategoriesDialog orgId={orgId} onClose={() => setShowManageCategories(false)} /> : null}

      <div className="grid grid-cols-1 gap-4.5 sm:grid-cols-2 lg:grid-cols-4">
        <StatTile label={t("accounts.thisMonth")} value={pnlLoading ? "—" : formatCurrency(pnl?.totalExpenses ?? 0)} />
        <StatTile
          label={t("accounts.thisYearSoFar")}
          value={yoyLoading ? "—" : formatCurrency(currentYearRow?.ytdComparableTotal ?? 0)}
        />
        <StatTile
          label={t("accounts.lastYearSamePeriod")}
          value={yoyLoading ? "—" : formatCurrency(priorYearRow?.ytdComparableTotal ?? 0)}
        />
        <StatTile
          label={t("accounts.yoyChange")}
          value={yoyDeltaPct === null ? "—" : `${yoyDeltaPct > 0 ? "+" : ""}${yoyDeltaPct}%`}
          tone={yoyDeltaPct !== null && yoyDeltaPct > 0 ? "danger" : yoyDeltaPct !== null && yoyDeltaPct < 0 ? "success" : undefined}
        />
      </div>

      <YearOverYearPanel yoy={yoy} isLoading={yoyLoading} />

      <SalaryByStaffPanel data={salaryByStaff} isLoading={salaryByStaffLoading} />

      <div className="rounded-card border border-border bg-surface p-6 shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
        <h3 className="mb-[18px] text-[17px] font-bold tracking-tight text-text">{t("accounts.expensesForPeriod")}</h3>
        <div className="flex flex-wrap items-center justify-between gap-3">
          <PeriodFilter value={period} onChange={setPeriod} />
          {categoryTotals.length > 0 ? (
            <select
              value={categoryFilter}
              onChange={(e) => setCategoryFilter(e.target.value)}
              className="h-9 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
            >
              <option value="">{t("accounts.allCategories")}</option>
              {categoryTotals.map((c) => (
                <option key={c.name} value={c.name}>
                  {c.name}
                </option>
              ))}
            </select>
          ) : null}
        </div>

        {categoryTotals.length > 0 ? (
          <div className="mt-3 flex flex-wrap gap-2">
            {categoryTotals.map((c) => (
              <span key={c.name} className="rounded-full bg-surface-alt px-3 py-1 text-xs font-medium text-text">
                {c.name}: <span className="font-bold tabular-nums">{formatCurrency(c.total)}</span>
              </span>
            ))}
          </div>
        ) : null}

        <div className="mt-4">
          {expensesError ? (
            <p className="text-sm text-danger">
              {t("reports.loadFailed")}{" "}
              <button type="button" className="underline" onClick={() => refetch()}>
                {t("common.retry")}
              </button>
            </p>
          ) : expensesLoading ? (
            <div className="space-y-2">
              {Array.from({ length: 4 }).map((_, i) => (
                <Skeleton key={i} className="h-9 w-full" />
              ))}
            </div>
          ) : !expenses || expenses.length === 0 ? (
            <p className="text-sm text-text-muted">{t("reports.empty")}</p>
          ) : !filteredExpenses || filteredExpenses.length === 0 ? (
            <p className="text-sm text-text-muted">{t("reports.empty")}</p>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b border-border text-left text-xs font-semibold text-text-muted">
                    <th className="py-2 pr-3">{t("reports.pnl.date")}</th>
                    <th className="py-2 pr-3">{t("reports.pnl.category")}</th>
                    <th className="py-2 pr-3">{t("accounts.staff")}</th>
                    <th className="py-2 pr-3">{t("accounts.note")}</th>
                    <th className="py-2 pr-3">{t("accounts.loggedBy")}</th>
                    <th className="py-2 pr-0 text-right">{t("reports.pnl.amount")}</th>
                  </tr>
                </thead>
                <tbody>
                  {filteredExpenses.map((e) => (
                    <tr key={e.id} className="border-b border-[#F1EDE6]">
                      <td className="py-2 pr-3 text-text-muted">{e.date}</td>
                      <td className="py-2 pr-3 font-medium text-text">{e.categoryName ?? t("accounts.uncategorised")}</td>
                      <td className="py-2 pr-3 text-text-muted">{e.staffName ?? "—"}</td>
                      <td className="py-2 pr-3 text-text-muted">{e.note ?? "—"}</td>
                      <td className="py-2 pr-3 text-text-muted">{e.loggedByName ?? "—"}</td>
                      <td className="py-2 pr-0 text-right font-bold tabular-nums text-text">{formatCurrency(e.amount)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      </div>
    </div>
  )
}

function StatTile({ label, value, tone }: { label: string; value: string; tone?: "danger" | "success" }) {
  return (
    <div className="flex flex-col gap-4.5 rounded-card border border-border bg-surface p-5.5 shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
      <div className="flex items-center justify-between">
        <span className="text-[13px] font-semibold text-text-muted">{label}</span>
        <span className="flex size-8.5 items-center justify-center rounded-[11px] bg-surface-alt text-text">
          <TrendingDown className="size-4.5" />
        </span>
      </div>
      <div className={cn("text-[26px] font-extrabold tabular-nums leading-none tracking-tight text-text", tone === "danger" && "text-danger", tone === "success" && "text-success")}>
        {value}
      </div>
    </div>
  )
}

/** Grouped-by-year bars: full-year totals for complete past years, the
 * current (partial) year shown as its YTD-comparable total so it never
 * looks artificially low next to a complete year. Rank-colored the same way
 * PnlReportTab's expense-breakdown bars already are (ink = current year,
 * accent = prior years) rather than introducing a new categorical palette. */
function YearOverYearPanel({ yoy, isLoading }: { yoy: { year: number; fullYearTotal: number; ytdComparableTotal: number }[] | undefined; isLoading: boolean }) {
  const { t } = useTranslation()
  const rows = yoy ?? []
  const max = Math.max(1, ...rows.map((r) => (r.year === rows[0]?.year ? r.ytdComparableTotal : r.fullYearTotal)))

  return (
    <div className="rounded-card border border-border bg-surface p-6 shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
      <h3 className="mb-1 text-[17px] font-bold tracking-tight text-text">{t("accounts.yearOverYear")}</h3>
      <p className="mb-[18px] text-xs text-text-muted">{t("accounts.yearOverYearNote")}</p>
      {isLoading ? (
        <div className="space-y-4">
          {Array.from({ length: 3 }).map((_, i) => (
            <Skeleton key={i} className="h-8 w-full" />
          ))}
        </div>
      ) : rows.every((r) => r.fullYearTotal === 0) ? (
        <p className="text-sm text-text-muted">{t("reports.empty")}</p>
      ) : (
        <div className="flex flex-col gap-4">
          {rows.map((r, i) => {
            const isCurrent = i === 0
            const value = isCurrent ? r.ytdComparableTotal : r.fullYearTotal
            return (
              <div key={r.year}>
                <div className="mb-[7px] flex items-center justify-between">
                  <span className="text-[13px] font-semibold text-text">
                    {r.year}
                    {isCurrent ? <span className="ml-1.5 text-[11px] font-medium text-text-muted">{t("accounts.soFar")}</span> : null}
                  </span>
                  <span className="text-[13px] font-bold tabular-nums text-text">{formatCurrency(value)}</span>
                </div>
                <div className="h-2 overflow-hidden rounded-full bg-border">
                  <div
                    className={cn("h-full rounded-full", isCurrent ? "bg-ink" : "bg-accent")}
                    style={{ width: `${Math.max(4, Math.round((value / max) * 100))}%` }}
                  />
                </div>
              </div>
            )
          })}
        </div>
      )}
    </div>
  )
}

/** Salary spend by staff (item 1 drill-down) — sums every category='salary'
 * expense for the selected period regardless of which path wrote it
 * (technician "Log to Accounts" or manual staff entry), one combined total
 * per person. */
function SalaryByStaffPanel({ data, isLoading }: { data: { staffId: string; staffName: string; total: number }[] | undefined; isLoading: boolean }) {
  const { t } = useTranslation()
  const rows = data ?? []
  const max = Math.max(1, ...rows.map((r) => r.total))

  if (!isLoading && rows.length === 0) return null

  return (
    <div className="rounded-card border border-border bg-surface p-6 shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
      <h3 className="mb-[18px] text-[17px] font-bold tracking-tight text-text">{t("accounts.salaryByStaff")}</h3>
      {isLoading ? (
        <div className="space-y-4">
          {Array.from({ length: 3 }).map((_, i) => (
            <Skeleton key={i} className="h-8 w-full" />
          ))}
        </div>
      ) : (
        <div className="flex flex-col gap-4">
          {rows.map((r) => (
            <div key={r.staffId}>
              <div className="mb-[7px] flex items-center justify-between">
                <span className="text-[13px] font-semibold text-text">{r.staffName}</span>
                <span className="text-[13px] font-bold tabular-nums text-text">{formatCurrency(r.total)}</span>
              </div>
              <div className="h-2 overflow-hidden rounded-full bg-border">
                <div className="h-full rounded-full bg-accent" style={{ width: `${Math.max(4, Math.round((r.total / max) * 100))}%` }} />
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  )
}

/** Log Expense — extended from PnlReportTab's original panel (ADM-28 gap
 * fix) with note + optional recurring-task link, per the 2026-09-24 Accounts
 * change request. The task link is optional: an unplanned expense (emergency
 * repair, surprise purchase) is logged exactly the same way as a routine
 * one, with no requirement to pick a task. */
function LogExpensePanel({ orgId, onClose, onLogged }: { orgId: string | undefined; onClose: () => void; onLogged: () => void }) {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const createExpense = useCreateExpense()
  const { data: openTasks } = useOpenRecurringTasks(orgId)
  const { data: expenseCategoryOptions } = useExpenseCategories(orgId)
  const [showCreateCategory, setShowCreateCategory] = useState(false)
  const [newCategoryName, setNewCategoryName] = useState("")
  const createCategory = useCreateExpenseCategory()

  const form = useForm<CreateExpenseFormInput, unknown, CreateExpenseOutput>({
    resolver: zodResolver(createExpenseSchema),
    mode: "onChange",
    defaultValues: { categoryId: "", amount: 0, date: toLocalDateString(new Date()), note: "", recurringTaskId: "" },
  })

  async function onSubmit(values: CreateExpenseOutput) {
    if (!orgId) return
    const category = (expenseCategoryOptions ?? []).find((c) => c.id === values.categoryId)
    if (!category) return
    await createExpense.mutateAsync({
      orgId,
      // "Under Category" is the one field the user picks; the legacy enum this
      // table still requires is derived from it, never shown or chosen directly.
      category: resolveLegacyExpenseCategoryEnum(category),
      amount: values.amount,
      date: values.date,
      note: values.note?.trim() ? values.note.trim() : null,
      recurringTaskId: values.recurringTaskId || null,
      loggedBy: profile?.id ?? null,
      categoryId: values.categoryId,
    })
    onLogged()
  }

  async function handleCreateCategory() {
    if (!newCategoryName.trim()) return
    const created = await createCategory.mutateAsync(newCategoryName.trim())
    form.setValue("categoryId", created.id, { shouldValidate: true })
    setNewCategoryName("")
    setShowCreateCategory(false)
  }

  return (
    <Card className="gap-3 px-5">
      <div className="flex items-center justify-between">
        <h4 className="text-sm font-semibold text-text">{t("accounts.logExpense")}</h4>
        <Button size="sm" variant="ghost" onClick={onClose}>
          {t("common.cancel")}
        </Button>
      </div>

      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <div className="space-y-1.5">
          <Label htmlFor="accounts-expense-under-category">{t("accounts.underCategory")}</Label>
          {showCreateCategory ? (
            <div className="flex gap-1.5">
              <Input
                autoFocus
                placeholder={t("accounts.newCategoryName")}
                value={newCategoryName}
                onChange={(e) => setNewCategoryName(e.target.value)}
              />
              <Button type="button" size="sm" onClick={handleCreateCategory} disabled={createCategory.isPending}>
                {t("common.save")}
              </Button>
              <Button type="button" size="sm" variant="ghost" onClick={() => setShowCreateCategory(false)}>
                {t("common.cancel")}
              </Button>
            </div>
          ) : (
            <Controller
              control={form.control}
              name="categoryId"
              render={({ field }) => (
                <select
                  id="accounts-expense-under-category"
                  value={field.value}
                  onChange={(e) => {
                    if (e.target.value === "__create__") {
                      setShowCreateCategory(true)
                    } else {
                      field.onChange(e.target.value)
                    }
                  }}
                  className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
                >
                  <option value="" disabled>
                    {t("accounts.chooseCategory")}
                  </option>
                  {(expenseCategoryOptions ?? [])
                    .filter((c) => c.is_active)
                    .map((c) => (
                      <option key={c.id} value={c.id}>
                        {c.name}
                        {c.is_system ? ` (${t("accounts.systemCategory")})` : ""}
                      </option>
                    ))}
                  <option value="__create__">{t("accounts.createNewCategory")}</option>
                </select>
              )}
            />
          )}
          {form.formState.errors.categoryId ? <p className="text-xs text-danger">{t(form.formState.errors.categoryId.message!)}</p> : null}
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="accounts-expense-amount">{t("reports.pnl.amount")}</Label>
          <Input id="accounts-expense-amount" type="number" min={0} step="0.01" {...form.register("amount")} />
          {form.formState.errors.amount ? <p className="text-xs text-danger">{t(form.formState.errors.amount.message!)}</p> : null}
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="accounts-expense-date">{t("reports.pnl.date")}</Label>
          <Controller
            control={form.control}
            name="date"
            render={({ field }) => <DatePicker id="accounts-expense-date" value={field.value ?? ""} onChange={field.onChange} />}
          />
          {form.formState.errors.date ? <p className="text-xs text-danger">{t(form.formState.errors.date.message!)}</p> : null}
        </div>
      </div>

      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <div className="space-y-1.5">
          <Label htmlFor="accounts-expense-note">{t("accounts.note")}</Label>
          <Input id="accounts-expense-note" placeholder={t("accounts.notePlaceholder")} {...form.register("note")} />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="accounts-expense-task">{t("accounts.linkToTask")}</Label>
          <select
            id="accounts-expense-task"
            {...form.register("recurringTaskId")}
            className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
          >
            <option value="">{t("accounts.noTaskLink")}</option>
            {(openTasks ?? []).map((task) => (
              <option key={task.id} value={task.id}>
                {task.title} {task.due_date ? `(${task.due_date})` : ""}
              </option>
            ))}
          </select>
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

/** Manage Categories — add/rename/deactivate/delete-if-unused. System
 * categories (one per existing expense_category enum value, plus
 * Incentives) are locked at the DB level and show as read-only here. */
function ManageCategoriesDialog({ orgId, onClose }: { orgId: string | undefined; onClose: () => void }) {
  const { t } = useTranslation()
  const { data: categories, isLoading } = useExpenseCategories(orgId)
  const renameCategory = useRenameExpenseCategory()
  const deactivateCategory = useDeactivateExpenseCategory()
  const deleteCategory = useDeleteExpenseCategory()
  const createCategory = useCreateExpenseCategory()
  const [newName, setNewName] = useState("")
  const [editingId, setEditingId] = useState<string | null>(null)
  const [editingName, setEditingName] = useState("")
  const [error, setError] = useState<string | null>(null)

  async function handleCreate() {
    if (!newName.trim()) return
    setError(null)
    try {
      await createCategory.mutateAsync(newName.trim())
      setNewName("")
    } catch (e) {
      setError((e as Error).message)
    }
  }

  async function handleDelete(id: string) {
    setError(null)
    try {
      await deleteCategory.mutateAsync(id)
    } catch (e) {
      setError((e as Error).message)
    }
  }

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent>
        <DialogTitle>{t("accounts.manageCategories")}</DialogTitle>
        <DialogDescription>{t("accounts.manageCategoriesHint")}</DialogDescription>

        <div className="flex gap-1.5">
          <Input placeholder={t("accounts.newCategoryName")} value={newName} onChange={(e) => setNewName(e.target.value)} />
          <Button size="sm" onClick={handleCreate} disabled={createCategory.isPending}>
            {t("accounts.createNewCategory")}
          </Button>
        </div>

        {error ? <p className="rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{error}</p> : null}

        {isLoading ? (
          <Skeleton className="h-24 w-full" />
        ) : (
          <div className="max-h-80 space-y-1.5 overflow-y-auto">
            {(categories ?? []).map((c) => (
              <div key={c.id} className="flex items-center justify-between gap-2 rounded-xl border border-border px-3 py-2">
                {editingId === c.id ? (
                  <Input value={editingName} onChange={(e) => setEditingName(e.target.value)} className="h-8" />
                ) : (
                  <span className={cn("text-sm", !c.is_active && "text-text-muted line-through")}>
                    {c.name}
                    {c.is_system ? <span className="ml-1.5 text-xs text-text-muted">({t("accounts.systemCategory")})</span> : null}
                  </span>
                )}
                {!c.is_system ? (
                  editingId === c.id ? (
                    <div className="flex gap-1">
                      <Button
                        size="sm"
                        variant="ghost"
                        onClick={async () => {
                          await renameCategory.mutateAsync({ id: c.id, name: editingName })
                          setEditingId(null)
                        }}
                      >
                        {t("common.save")}
                      </Button>
                      <Button size="sm" variant="ghost" onClick={() => setEditingId(null)}>
                        {t("common.cancel")}
                      </Button>
                    </div>
                  ) : (
                    <div className="flex gap-1">
                      <Button
                        size="sm"
                        variant="ghost"
                        onClick={() => {
                          setEditingId(c.id)
                          setEditingName(c.name)
                        }}
                      >
                        {t("accounts.rename")}
                      </Button>
                      {c.is_active ? (
                        <Button size="sm" variant="ghost" onClick={() => deactivateCategory.mutate(c.id)}>
                          {t("accounts.deactivate")}
                        </Button>
                      ) : null}
                      <Button size="sm" variant="ghost" onClick={() => handleDelete(c.id)}>
                        {t("common.delete")}
                      </Button>
                    </div>
                  )
                ) : null}
              </div>
            ))}
          </div>
        )}

        <div className="flex justify-end">
          <Button variant="outline" onClick={onClose}>
            {t("common.cancel")}
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  )
}
