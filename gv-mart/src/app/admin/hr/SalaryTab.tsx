import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2, Printer } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { useProfile } from "@/hooks/useProfile"
import { useActiveTechnicians, useComputeSalary, useSalaries } from "@/hooks/useHr"
import type { SalaryListItem } from "@/services/hr"

function currentMonthIso() {
  return new Date().toISOString().slice(0, 7)
}

function monthToPeriodDate(month: string) {
  return `${month}-01`
}

function money(n: number) {
  return `₹${n.toLocaleString("en-IN", { minimumFractionDigits: 0, maximumFractionDigits: 2 })}`
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
  const [computingId, setComputingId] = useState<string | null>(null)
  const [printing, setPrinting] = useState<SalaryListItem | null>(null)

  function computeFor(technicianId: string) {
    if (!orgId) return
    setComputingId(technicianId)
    computeMut.mutate(
      { orgId, technicianId, period },
      { onSettled: () => setComputingId(null) }
    )
  }

  function computeAll() {
    if (!orgId || !technicians) return
    for (const tech of technicians) computeFor(tech.id)
  }

  const columns: DataTableColumn<SalaryListItem>[] = [
    { key: "technician", header: t("hr.salary.technician"), render: (r) => r.technicians?.profiles?.full_name ?? "—" },
    { key: "base", header: t("hr.salary.base"), render: (r) => money(r.base) },
    { key: "revenueComponent", header: t("hr.salary.revenueComponent"), render: (r) => money(r.revenue_component) },
    { key: "lateDeduction", header: t("hr.salary.lateDeduction"), render: (r) => `-${money(r.late_deduction)}` },
    { key: "incentives", header: t("hr.salary.incentives"), render: (r) => `+${money(r.incentives)}` },
    { key: "net", header: t("hr.salary.net"), render: (r) => <span className="font-semibold text-text">{money(r.net)}</span> },
    {
      key: "__actions",
      header: "",
      className: "text-right",
      render: (r) => (
        <div className="flex justify-end gap-1.5">
          <Button size="xs" variant="outline" onClick={() => computeFor(r.technician_id)} disabled={computingId === r.technician_id}>
            {computingId === r.technician_id ? <Loader2 className="size-3 animate-spin" /> : t("hr.salary.recompute")}
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
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex items-center gap-2">
          <Label htmlFor="salary-month" className="text-sm">
            {t("hr.salary.month")}
          </Label>
          <Input id="salary-month" type="month" value={month} onChange={(e) => setMonth(e.target.value)} className="max-w-44" />
        </div>
        <Button variant="accent" onClick={computeAll} disabled={!technicians || technicians.length === 0}>
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
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4 print:static print:bg-transparent print:p-0">
          <Card size="default" className="w-full max-w-md gap-3 px-5 print:shadow-none">
            <p className="text-lg font-bold text-text">{t("hr.salary.payslip")}</p>
            <p className="text-sm text-text-muted">
              {printing.technicians?.profiles?.full_name ?? "—"} · {month}
            </p>
            <div className="space-y-1.5 border-t border-border pt-3 text-sm">
              <div className="flex justify-between">
                <span className="text-text-muted">{t("hr.salary.base")}</span>
                <span className="text-text">{money(printing.base)}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-text-muted">{t("hr.salary.revenueComponent")}</span>
                <span className="text-text">{money(printing.revenue_component)}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-text-muted">{t("hr.salary.lateDeduction")}</span>
                <span className="text-danger">-{money(printing.late_deduction)}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-text-muted">{t("hr.salary.incentives")}</span>
                <span className="text-success">+{money(printing.incentives)}</span>
              </div>
              <div className="mt-1 flex justify-between border-t border-border pt-2 text-base font-bold">
                <span className="text-text">{t("hr.salary.net")}</span>
                <span className="text-text">{money(printing.net)}</span>
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
          </Card>
        </div>
      ) : null}
    </div>
  )
}
