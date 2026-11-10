import { useState } from "react"
import { getIstNow } from "@/lib/ist"
import { useTranslation } from "react-i18next"
import { CheckCircle2, Loader2, Printer, Unlock, Wallet } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { useProfile } from "@/hooks/useProfile"
import { useActiveTechnicians, useComputeSalary, useLogSalaryToAccounts, useReopenSalaryPosting, useSalaries } from "@/hooks/useHr"
import { formatCurrency } from "@/lib/sale-calc"
import { canLogToAccounts, canRecompute, canReopen, hasShortfall } from "@/lib/salary-lock"
import { useToast } from "@/components/ui/toast-context"
import type { SalaryListItem } from "@/services/hr"

function currentMonthIso() {
  return getIstNow().date.slice(0, 7)
}

function monthToPeriodDate(month: string) {
  return `${month}-01`
}

/**
 * ADM-24. `net = base + revenue_component - late_deduction + incentives`;
 * `base` is the technician's tier monthly_salary (fixed, from Masters >
 * Technician Tiers) and `revenue_component` is their attributed service
 * revenue for the period; `late_deduction = late_hours x 2` — see
 * compute_salary() in supabase/migrations/20261001110000_compute_salary_tier_base.sql.
 */
export function SalaryTab() {
  const { t } = useTranslation()
  const { toast } = useToast()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id
  const [month, setMonth] = useState(currentMonthIso())
  const period = monthToPeriodDate(month)

  const { data: technicians } = useActiveTechnicians(orgId)
  const { data: salaries, isLoading, isError, refetch } = useSalaries(orgId, period)
  const computeMut = useComputeSalary()
  const [computingIds, setComputingIds] = useState<Set<string>>(new Set())
  const [printing, setPrinting] = useState<SalaryListItem | null>(null)

  // "Log to Accounts" (item 1, 2026-09-24 change request; made idempotent +
  // DB-enforced by the incentive audit's Finding H-01, 2026-10-29) — posts the
  // computed net salary into `expenses` (category='salary') via
  // log_salary_to_accounts(), which locks this `salaries` row in the same
  // transaction. `row.locked_at` (server-set, not a client guess) is now the
  // single source of truth for "already logged" — see Finding H-03.
  const logMut = useLogSalaryToAccounts()
  const reopenMut = useReopenSalaryPosting()
  const [loggingIds, setLoggingIds] = useState<Set<string>>(new Set())
  const [reopenTarget, setReopenTarget] = useState<SalaryListItem | null>(null)
  const [reopenReason, setReopenReason] = useState("")

  function logToAccounts(row: SalaryListItem) {
    const profileId = row.technicians?.profiles?.id
    if (!orgId || !profileId) return
    setLoggingIds((prev) => new Set(prev).add(row.id))
    logMut.mutate(
      {
        orgId,
        staffId: profileId,
        amount: row.net,
        date: getIstNow().date,
        note: `Salary — ${month}`,
        salaryId: row.id,
      },
      {
        onSuccess: (result) => {
          // result.message is a ready-made sentence from the DB ("already logged
          // on <date>" or "logged") -- not translated, same as every other raw
          // server-originated message surfaced via toast in this codebase.
          if (!result.inserted) toast.success(result.message)
        },
        onError: (e) => toast.error(e instanceof Error ? e.message : t("hr.salary.logFailed")),
        onSettled: () =>
          setLoggingIds((prev) => {
            const next = new Set(prev)
            next.delete(row.id)
            return next
          }),
      }
    )
  }

  function submitReopen() {
    if (!reopenTarget || !reopenReason.trim()) return
    reopenMut.mutate(
      { salaryId: reopenTarget.id, reason: reopenReason.trim() },
      {
        onSuccess: () => {
          toast.success(t("hr.salary.reopened"))
          setReopenTarget(null)
          setReopenReason("")
        },
        onError: (e) => toast.error(e instanceof Error ? e.message : t("hr.salary.reopenFailed")),
      }
    )
  }

  function computeFor(technicianId: string) {
    if (!orgId) return
    setComputingIds((prev) => new Set(prev).add(technicianId))
    computeMut.mutate(
      { orgId, technicianId, period },
      {
        onSettled: () =>
          setComputingIds((prev) => {
            const next = new Set(prev)
            next.delete(technicianId)
            return next
          }),
      }
    )
  }

  function computeAll() {
    if (!orgId || !technicians) return
    for (const tech of technicians) computeFor(tech.id)
  }

  const isBulkComputing = computingIds.size > 0

  const columns: DataTableColumn<SalaryListItem>[] = [
    { key: "technician", header: t("hr.salary.technician"), render: (r) => r.technicians?.profiles?.full_name ?? "—" },
    { key: "base", header: t("hr.salary.base"), render: (r) => formatCurrency(r.base) },
    { key: "revenueComponent", header: t("hr.salary.revenueComponent"), render: (r) => formatCurrency(r.revenue_component) },
    { key: "lateDeduction", header: t("hr.salary.lateDeduction"), render: (r) => `-${formatCurrency(r.late_deduction)}` },
    { key: "incentives", header: t("hr.salary.incentives"), render: (r) => `+${formatCurrency(r.incentives)}` },
    {
      key: "net",
      header: t("hr.salary.net"),
      // F-01 — net is floored at zero server-side; shortfall_amount is the
      // amount the floor absorbed, shown here as a visible warning rather
      // than hidden (a technician whose deductions exceeded their pay needs
      // this surfaced, not silently zeroed).
      render: (r) => (
        <div className="flex flex-col items-end">
          <span className="font-semibold text-text">{formatCurrency(r.net)}</span>
          {hasShortfall(r) ? (
            <span className="text-xs font-medium text-danger" title={t("hr.salary.shortfallHint")}>
              {t("hr.salary.shortfall", { amount: formatCurrency(r.shortfall_amount) })}
            </span>
          ) : null}
        </div>
      ),
    },
    {
      key: "__actions",
      header: "",
      className: "text-right",
      render: (r) => {
        const profileId = r.technicians?.profiles?.id
        // Finding H-03: locked_at is server-set (by log_salary_to_accounts), not a
        // client-side guess — canRecompute/canLogToAccounts/canReopen (src/lib/
        // salary-lock.ts) are the single source of truth for both "already
        // logged" AND "recompute must be refused" (compute_salary enforces the
        // latter server-side too; disabling it here is just not making the
        // master wait for an error that is already certain).
        const locked = !canRecompute(r)
        return (
          <div className="flex justify-end gap-1.5">
            <Button
              size="xs"
              variant="outline"
              onClick={() => computeFor(r.technician_id)}
              disabled={computingIds.has(r.technician_id) || !canRecompute(r)}
              title={locked ? t("hr.salary.lockedHint") : undefined}
            >
              {computingIds.has(r.technician_id) ? <Loader2 className="size-3 animate-spin" /> : t("hr.salary.recompute")}
            </Button>
            <Button
              size="xs"
              variant={locked ? "ghost" : "accent"}
              onClick={() => logToAccounts(r)}
              disabled={!profileId || !canLogToAccounts(r) || loggingIds.has(r.id)}
              title={t("hr.salary.logToAccounts")}
            >
              {loggingIds.has(r.id) ? (
                <Loader2 className="size-3 animate-spin" />
              ) : locked ? (
                <CheckCircle2 className="size-3 text-success" />
              ) : (
                <Wallet className="size-3" />
              )}
              {locked ? t("hr.salary.logged") : t("hr.salary.logToAccounts")}
            </Button>
            {canReopen(r) ? (
              <Button
                size="xs"
                variant="outline"
                onClick={() => {
                  setReopenTarget(r)
                  setReopenReason("")
                }}
                title={t("hr.salary.lockedHint")}
              >
                <Unlock className="size-3" />
                {t("hr.salary.reopen")}
              </Button>
            ) : null}
            <Button size="icon-xs" variant="ghost" onClick={() => setPrinting(r)} title={t("hr.salary.payslip")}>
              <Printer className="size-3.5" />
            </Button>
          </div>
        )
      },
    },
  ]

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end justify-between gap-3">
        {/* Owner request 2026-07-29: cosmetic-only alignment with the
            Month/Year/Custom PeriodFilter's month-input styling used
            elsewhere (Dashboard, Reports) — compute_salary is an exact-period
            RPC (one calendar month at a time, never a range), so this stays
            its own <input type="month"> rather than adopting PeriodFilter's
            mode-switch machinery. */}
        <div className="space-y-1">
          <Label htmlFor="salary-month" className="block text-xs font-medium text-text-muted">
            {t("hr.salary.month")}
          </Label>
          <Input id="salary-month" type="month" value={month} onChange={(e) => setMonth(e.target.value)} className="h-9 max-w-44 border-border" />
        </div>
        <Button variant="accent" onClick={computeAll} disabled={!technicians || technicians.length === 0 || isBulkComputing}>
          {isBulkComputing ? <Loader2 className="size-3.5 animate-spin" /> : null}
          {t("hr.salary.computeAll")}
        </Button>
      </div>

      <DataTable
        columns={columns}
        rows={salaries ?? []}
        rowKey={(r) => r.id}
        loading={isLoading}
        error={isError ? t("hr.salary.loadFailed") : null}
        onRetry={() => refetch()}
        emptyMessage={t("hr.salary.empty")}
      />

      {printing ? (
        <Dialog
          open
          onOpenChange={(next) => {
            if (!next) setPrinting(null)
          }}
        >
          <DialogContent className="gap-3 print:static print:max-h-none print:w-full print:max-w-none print:translate-x-0 print:translate-y-0 print:border-none print:p-0 print:shadow-none">
            <DialogTitle className="text-lg font-bold">{t("hr.salary.payslip")}</DialogTitle>
            <p className="text-sm text-text-muted">
              {printing.technicians?.profiles?.full_name ?? "—"} · {month}
            </p>
            <div className="space-y-1.5 border-t border-border pt-3 text-sm">
              <div className="flex justify-between">
                <span className="text-text-muted">{t("hr.salary.base")}</span>
                <span className="text-text">{formatCurrency(printing.base)}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-text-muted">{t("hr.salary.revenueComponent")}</span>
                <span className="text-text">{formatCurrency(printing.revenue_component)}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-text-muted">{t("hr.salary.lateDeduction")}</span>
                <span className="text-danger">-{formatCurrency(printing.late_deduction)}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-text-muted">{t("hr.salary.incentives")}</span>
                <span className="text-success">+{formatCurrency(printing.incentives)}</span>
              </div>
              <div className="mt-1 flex justify-between border-t border-border pt-2 text-base font-bold">
                <span className="text-text">{t("hr.salary.net")}</span>
                <span className="text-text">{formatCurrency(printing.net)}</span>
              </div>
              {hasShortfall(printing) ? (
                <div className="flex justify-between text-xs font-medium text-danger">
                  <span>{t("hr.salary.shortfallHint")}</span>
                  <span>{formatCurrency(printing.shortfall_amount)}</span>
                </div>
              ) : null}
            </div>
            <div className="flex justify-end gap-2 print:hidden">
              <Button size="sm" variant="ghost" onClick={() => setPrinting(null)}>
                {t("common.cancel")}
              </Button>
              <Button size="sm" onClick={() => window.print()}>
                <Printer className="size-3.5" />
                {t("hr.salary.print")}
              </Button>
            </div>
          </DialogContent>
        </Dialog>
      ) : null}

      <Dialog open={!!reopenTarget} onOpenChange={(open) => !open && setReopenTarget(null)}>
        <DialogContent>
          <DialogTitle>{t("hr.salary.reopenDialogTitle")}</DialogTitle>
          <DialogDescription>
            {t("hr.salary.reopenDialogHint", { name: reopenTarget?.technicians?.profiles?.full_name ?? "" })}
          </DialogDescription>
          <form
            className="space-y-3"
            onSubmit={(e) => {
              e.preventDefault()
              submitReopen()
            }}
          >
            <div className="space-y-1">
              <Label htmlFor="reopen-reason" className="block text-xs font-medium text-text-muted">
                {t("hr.salary.reopenReason")}
              </Label>
              <textarea
                id="reopen-reason"
                required
                rows={3}
                value={reopenReason}
                onChange={(e) => setReopenReason(e.target.value)}
                className="w-full rounded-md border border-border bg-surface px-3 py-2 text-sm"
              />
            </div>
            <div className="flex justify-end gap-2">
              <Button type="button" variant="outline" onClick={() => setReopenTarget(null)}>
                {t("common.cancel")}
              </Button>
              <Button type="submit" variant="destructive" disabled={!reopenReason.trim() || reopenMut.isPending}>
                {reopenMut.isPending && <Loader2 className="size-3.5 animate-spin" />}
                {t("hr.salary.reopenConfirm")}
              </Button>
            </div>
          </form>
        </DialogContent>
      </Dialog>
    </div>
  )
}
