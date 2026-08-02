import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2, Printer } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogTitle } from "@/components/ui/dialog"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { useProfile } from "@/hooks/useProfile"
import { useActiveTechnicians, useComputeSalary, useSalaries } from "@/hooks/useHr"
import { formatCurrency } from "@/lib/sale-calc"
import type { SalaryListItem } from "@/services/hr"

function currentMonthIso() {
  return new Date().toISOString().slice(0, 7)
}

function monthToPeriodDate(month: string) {
  return `${month}-01`
}

/**
 * ADM-24. `net = base + revenue_component - late_deduction + incentives`;
 * `base` is the technician's attributed service revenue for the period,
 * `late_deduction = late_hours x 2` (v2.2's only concrete rule) — see the
 * compute_salary() header comment in
 * supabase/migrations/20260702200200_hr_functions.sql for the full
 * reasoning and the judgment call this makes (no fixed salary slab table
 * exists in-scope, so `revenue_component` computes to 0 rather than
 * inventing unstated slab boundaries).
 */
export function SalaryTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id
  const [month, setMonth] = useState(currentMonthIso())
  const period = monthToPeriodDate(month)

  const { data: technicians } = useActiveTechnicians(orgId)
  const { data: salaries, isLoading, isError, refetch } = useSalaries(orgId, period)
  const computeMut = useComputeSalary()
  const [computingIds, setComputingIds] = useState<Set<string>>(new Set())
  const [printing, setPrinting] = useState<SalaryListItem | null>(null)

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
    { key: "net", header: t("hr.salary.net"), render: (r) => <span className="font-semibold text-text">{formatCurrency(r.net)}</span> },
    {
      key: "__actions",
      header: "",
      className: "text-right",
      render: (r) => (
        <div className="flex justify-end gap-1.5">
          <Button size="xs" variant="outline" onClick={() => computeFor(r.technician_id)} disabled={computingIds.has(r.technician_id)}>
            {computingIds.has(r.technician_id) ? <Loader2 className="size-3 animate-spin" /> : t("hr.salary.recompute")}
          </Button>
          <Button size="icon-xs" variant="ghost" onClick={() => setPrinting(r)} title={t("hr.salary.payslip")}>
            <Printer className="size-3.5" />
          </Button>
        </div>
      ),
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
    </div>
  )
}
