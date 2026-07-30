import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { useProfile } from "@/hooks/useProfile"
import { useComputeIncentives, useIncentivesEarned } from "@/hooks/useHr"
import type { IncentiveEarnedListItem } from "@/services/hr"

function currentMonthIso() {
  return new Date().toISOString().slice(0, 7)
}
function monthToPeriodDate(month: string) {
  return `${month}-01`
}
function money(n: number) {
  return `₹${n.toLocaleString("en-IN")}`
}

/**
 * ADM-25 — read view of incentives_earned joined to incentive_rules, NOT
 * the rule editor (that already exists at Masters → Incentive Rules,
 * src/app/admin/masters/IncentiveRulesTab.tsx). "Compute" evaluates every
 * active rule against real technician activity for the period via the
 * compute_incentives() RPC and inserts qualifying rows (idempotent — see
 * migration 20260702200200_hr_functions.sql).
 */
export function IncentivesTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id
  const [month, setMonth] = useState(currentMonthIso())
  const period = monthToPeriodDate(month)

  const { data: rows, isLoading, isError, refetch } = useIncentivesEarned(orgId, period)
  const computeMut = useComputeIncentives()

  const columns: DataTableColumn<IncentiveEarnedListItem>[] = [
    { key: "technician", header: t("hr.incentives.technician"), render: (r) => r.technicians?.profiles?.full_name ?? "—" },
    { key: "type", header: t("hr.incentives.ruleType"), render: (r) => (r.incentive_rules ? t(`masters.incentives.types.${r.incentive_rules.type}`) : "—") },
    { key: "threshold", header: t("hr.incentives.threshold"), render: (r) => (r.incentive_rules ? money(r.incentive_rules.threshold) : "—") },
    { key: "amount", header: t("hr.incentives.amountEarned"), render: (r) => <span className="font-semibold text-success">{money(r.amount)}</span> },
  ]

  const totalEarned = (rows ?? []).reduce((sum, r) => sum + r.amount, 0)

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end justify-between gap-3">
        {/* Owner request 2026-07-29: cosmetic-only alignment with the
            Month/Year/Custom PeriodFilter's month-input styling used
            elsewhere (Dashboard, Reports) — compute_incentives is an
            exact-period RPC (one calendar month at a time, never a range),
            so this stays its own <input type="month"> rather than adopting
            PeriodFilter's mode-switch machinery. */}
        <div className="space-y-1">
          <Label htmlFor="incentives-month" className="block text-xs font-medium text-text-muted">
            {t("hr.incentives.month")}
          </Label>
          <Input id="incentives-month" type="month" value={month} onChange={(e) => setMonth(e.target.value)} className="h-9 max-w-44 border-border" />
        </div>
        <Button
          variant="accent"
          onClick={() => orgId && computeMut.mutate({ orgId, period })}
          disabled={!orgId || computeMut.isPending}
        >
          {computeMut.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("hr.incentives.compute")}
        </Button>
      </div>

      {rows && rows.length > 0 ? (
        <p className="text-sm text-text-muted">{t("hr.incentives.totalEarned", { amount: money(totalEarned) })}</p>
      ) : null}

      <DataTable
        columns={columns}
        rows={rows ?? []}
        rowKey={(r) => r.id}
        loading={isLoading}
        error={isError ? t("hr.incentives.loadFailed") : null}
        onRetry={() => refetch()}
        emptyMessage={t("hr.incentives.empty")}
      />
    </div>
  )
}
