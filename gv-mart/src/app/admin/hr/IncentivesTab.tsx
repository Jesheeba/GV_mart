import { useState } from "react"
import { toLocalMonthString } from "@/lib/local-date"
import { useTranslation } from "react-i18next"
import { Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { useProfile } from "@/hooks/useProfile"
import { useComputeIncentives, useIncentivesEarned } from "@/hooks/useHr"
import { useReferralBonusReport } from "@/hooks/useReferrals"
import { InstallationCreditsPanel } from "./InstallationCreditsPanel"
import type { IncentiveEarnedListItem } from "@/services/hr"

function currentMonthIso() {
  return toLocalMonthString(new Date())
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
  const [referralOnly, setReferralOnly] = useState(false)
  // Referral incentives, Stage 2 — `referral_bonus_report` isn't built on the
  // DB side yet (see useReferrals.ts header); the "N pending — month locked"
  // banner below reads its summary once that RPC lands. Request is made
  // regardless so the banner appears the moment the DB package is applied,
  // with no further UI change needed.
  const { data: referralReport } = useReferralBonusReport(period)
  const pendingLocked = referralReport?.summary.pending_month_locked ?? 0

  const visibleRows = referralOnly ? (rows ?? []).filter((r) => !!r.referral_bonus_event_id) : rows ?? []

  const columns: DataTableColumn<IncentiveEarnedListItem>[] = [
    { key: "technician", header: t("hr.incentives.technician"), render: (r) => r.technicians?.profiles?.full_name ?? "—" },
    { key: "type", header: t("hr.incentives.ruleType"), render: (r) =>
        r.incentive_rules
          ? t(`masters.incentives.types.${r.incentive_rules.type}`)
          : r.installation_incentive_rates
            ? `${t("hr.incentives.perUnitInstall")}${[r.installation_incentive_rates.category, r.installation_incentive_rates.capacity, r.installation_incentive_rates.configuration].filter(Boolean).length ? ` (${[r.installation_incentive_rates.category, r.installation_incentive_rates.capacity, r.installation_incentive_rates.configuration].filter(Boolean).join(" · ")})` : ""}`
            : r.credit_source === "installation_ticket"
              ? t("hr.incentives.creditsEarned")
              : "—",
    },
    {
      key: "threshold",
      header: t("hr.incentives.threshold"),
      render: (r) => (r.incentive_rules ? money(r.incentive_rules.threshold) : r.installation_incentive_rates ? `${money(r.installation_incentive_rates.flat_amount)} ${t("hr.incentives.perUnit")}` : "—"),
    },
    { key: "amount", header: t("hr.incentives.amountEarned"), render: (r) => <span className="font-semibold text-success">{money(r.amount)}</span> },
  ]

  const totalEarned = visibleRows.reduce((sum, r) => sum + r.amount, 0)

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

      <InstallationCreditsPanel orgId={orgId} />

      {pendingLocked > 0 ? (
        <p className="rounded-xl bg-warning/10 px-3.5 py-2.5 text-sm font-medium text-warning">
          {t("hr.incentives.referralPendingLocked", { count: pendingLocked })}
        </p>
      ) : null}

      <label className="flex items-center gap-2 text-sm font-medium text-text">
        <input type="checkbox" checked={referralOnly} onChange={(e) => setReferralOnly(e.target.checked)} className="size-4" />
        {t("hr.incentives.referralOnly")}
      </label>

      {visibleRows.length > 0 ? (
        <p className="text-sm text-text-muted">{t("hr.incentives.totalEarned", { amount: money(totalEarned) })}</p>
      ) : null}

      <DataTable
        columns={columns}
        rows={visibleRows}
        rowKey={(r) => r.id}
        loading={isLoading}
        error={isError ? t("hr.incentives.loadFailed") : null}
        onRetry={() => refetch()}
        emptyMessage={referralOnly ? t("hr.incentives.referralEmpty") : t("hr.incentives.empty")}
      />
    </div>
  )
}
