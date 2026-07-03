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
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex items-center gap-2">
          <Label htmlFor="incentives-month" className="text-sm">
            {t("hr.incentives.month")}
          </Label>
          <Input id="incentives-month" type="month" value={month} onChange={(e) => setMonth(e.target.value)} className="max-w-44" />
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
