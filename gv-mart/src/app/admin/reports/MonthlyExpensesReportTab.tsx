import { useState } from "react"
import { useTranslation } from "react-i18next"
import { getIstNow } from "@/lib/ist"
import { Wallet } from "lucide-react"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { KpiCard } from "@/components/shared/KpiCard"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { useProfile } from "@/hooks/useProfile"
import { useMonthlyExpensesReport } from "@/hooks/useMonthlyExpenses"
import { formatCurrency } from "@/lib/sale-calc"
import type { MonthlyExpensesReportRow } from "@/services/monthlyExpenses"

function currentMonthIso() {
  return getIstNow().date.slice(0, 7)
}

function monthToPeriodDate(month: string) {
  return `${month}-01`
}

/**
 * Unit 7 (GVMART_MONTHLY_EXPENSES_SPEC.md) — per-technician and
 * organisation-wide breakdown of the four Monthly Expenses lines, reading
 * `salaries` (same source of truth `compute_salary` itemises into, same
 * client-side-aggregation convention as every other report tab here — see
 * CoverageReportTab). `compute_salary` is an exact-period RPC, so this uses
 * SalaryTab's own `<input type="month">` rather than the range-based
 * PeriodFilter.
 */
export function MonthlyExpensesReportTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id
  const [month, setMonth] = useState(currentMonthIso())
  const period = monthToPeriodDate(month)

  const { data, isLoading, isError, refetch } = useMonthlyExpensesReport(orgId, period)
  const rows = data ?? []

  const sum = (f: (r: MonthlyExpensesReportRow) => number) => rows.reduce((s, r) => s + f(r), 0)

  const columns: DataTableColumn<MonthlyExpensesReportRow>[] = [
    { key: "name", header: t("reports.monthlyExpenses.technician"), render: (r) => r.technicianName },
    { key: "recharge", header: t("reports.monthlyExpenses.recharge"), render: (r) => formatCurrency(r.rechargeAmount) },
    { key: "petrol", header: t("reports.monthlyExpenses.petrol"), render: (r) => formatCurrency(r.petrolAmount) },
    { key: "maintenance", header: t("reports.monthlyExpenses.maintenance"), render: (r) => formatCurrency(r.maintenanceAmount) },
    { key: "bikeAllowance", header: t("reports.monthlyExpenses.bikeAllowance"), render: (r) => formatCurrency(r.bikeAllowanceAmount) },
    {
      key: "total",
      header: t("reports.monthlyExpenses.total"),
      render: (r) => formatCurrency(r.rechargeAmount + r.petrolAmount + r.maintenanceAmount + r.bikeAllowanceAmount),
    },
  ]

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div className="space-y-1">
          <Label htmlFor="monthly-expenses-report-month" className="block text-xs font-medium text-text-muted">
            {t("reports.monthlyExpenses.month")}
          </Label>
          <Input
            id="monthly-expenses-report-month"
            type="month"
            value={month}
            onChange={(e) => setMonth(e.target.value)}
            className="h-9 max-w-44 border-border"
          />
        </div>
      </div>

      {isError ? (
        <p className="text-sm text-danger">
          {t("reports.loadFailed")}{" "}
          <button type="button" className="underline" onClick={() => refetch()}>
            {t("common.retry")}
          </button>
        </p>
      ) : null}

      <div className="grid grid-cols-2 gap-4 sm:grid-cols-4">
        <KpiCard
          label={t("reports.monthlyExpenses.recharge")}
          value={isLoading ? "—" : formatCurrency(sum((r) => r.rechargeAmount))}
          icon={<Wallet className="size-4" />}
          loading={isLoading}
        />
        <KpiCard
          label={t("reports.monthlyExpenses.petrol")}
          value={isLoading ? "—" : formatCurrency(sum((r) => r.petrolAmount))}
          icon={<Wallet className="size-4" />}
          loading={isLoading}
        />
        <KpiCard
          label={t("reports.monthlyExpenses.maintenance")}
          value={isLoading ? "—" : formatCurrency(sum((r) => r.maintenanceAmount))}
          icon={<Wallet className="size-4" />}
          loading={isLoading}
        />
        <KpiCard
          label={t("reports.monthlyExpenses.bikeAllowance")}
          value={isLoading ? "—" : formatCurrency(sum((r) => r.bikeAllowanceAmount))}
          icon={<Wallet className="size-4" />}
          loading={isLoading}
        />
      </div>

      <DataTable columns={columns} rows={rows} rowKey={(r) => r.technicianId} loading={isLoading} emptyMessage={t("reports.empty")} />
    </div>
  )
}
