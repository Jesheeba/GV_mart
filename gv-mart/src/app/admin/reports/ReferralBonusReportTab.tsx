import { useState } from "react"
import { useTranslation } from "react-i18next"
import { getIstNow } from "@/lib/ist"
import { Gift } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { KpiCard } from "@/components/shared/KpiCard"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { useProfile } from "@/hooks/useProfile"
import { useActiveTechnicians } from "@/hooks/useHr"
import { useReferralBonusReport } from "@/hooks/useReferrals"
import { downloadCsv, toCsv } from "@/services/reports"
import type { ReferralBonusReportRow, ReferralBonusStatus } from "@/services/referrals"
import { formatCurrency } from "@/lib/sale-calc"

function currentMonthIso() {
  return getIstNow().date.slice(0, 7)
}
function monthToPeriodDate(month: string) {
  return `${month}-01`
}

const STATUS_STYLE: Record<ReferralBonusStatus, string> = {
  pending: "bg-warning/10 text-warning",
  approved: "bg-info/10 text-info",
  paid: "bg-success/15 text-success",
  voided: "bg-danger/10 text-danger",
}

/**
 * Referral incentives, Stage 2 (scope item 3) — monthly report for master:
 * who referred, referred customer, qualifying source, amount, status, and
 * the org-wide "month locked" count. Reads the not-yet-built
 * `referral_bonus_report` RPC (see src/services/referrals.ts header) via
 * useReferralBonusReport — a NEW screen, deliberately not a rewrite of the
 * old, dead `referral_overview`/Referrals tab (see Stage 1 plan.md §3.5).
 * CSV export is generated client-side from the rows already in memory, same
 * pattern as every other Reports tab (toCsv/downloadCsv, src/services/reports.ts).
 */
export function ReferralBonusReportTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id
  const [month, setMonth] = useState(currentMonthIso())
  const period = monthToPeriodDate(month)
  const [technicianId, setTechnicianId] = useState("")

  const { data: technicians } = useActiveTechnicians(orgId)
  const { data, isLoading, isError, refetch } = useReferralBonusReport(period, technicianId || null)

  const rows = data?.rows ?? []
  const summary = data?.summary

  function statusLabel(s: ReferralBonusStatus) {
    return t(`reports.referralBonus.status.${s}`)
  }
  function sourceLabel(s: ReferralBonusReportRow["source"]) {
    return t(`reports.referralBonus.source.${s}`)
  }
  function kindLabel(k: ReferralBonusReportRow["referrer_kind"]) {
    return t(`reports.referralBonus.kind.${k}`)
  }

  const columns: DataTableColumn<ReferralBonusReportRow>[] = [
    { key: "referrer", header: t("reports.referralBonus.referrer"), render: (r) => `${r.referrer_name} (${kindLabel(r.referrer_kind)})` },
    { key: "customer", header: t("reports.referralBonus.customer"), render: (r) => r.customer_name },
    { key: "source", header: t("reports.referralBonus.source.label"), render: (r) => sourceLabel(r.source) },
    { key: "qualifiedAt", header: t("reports.referralBonus.qualifiedAt"), render: (r) => new Date(r.qualified_at).toLocaleDateString("en-IN") },
    { key: "amount", header: t("reports.referralBonus.amount"), render: (r) => formatCurrency(r.rate_amount) },
    {
      key: "status",
      header: t("reports.referralBonus.statusLabel"),
      render: (r) => <span className={`rounded-full px-2.5 py-1 text-xs font-bold ${STATUS_STYLE[r.status]}`}>{statusLabel(r.status)}</span>,
    },
  ]

  function handleExport() {
    const csv = toCsv(
      [
        t("reports.referralBonus.referrer"),
        t("reports.referralBonus.kind.label"),
        t("reports.referralBonus.customer"),
        t("reports.referralBonus.source.label"),
        t("reports.referralBonus.qualifiedAt"),
        t("reports.referralBonus.amount"),
        t("reports.referralBonus.statusLabel"),
      ],
      rows.map((r) => [r.referrer_name, kindLabel(r.referrer_kind), r.customer_name, sourceLabel(r.source), r.qualified_at, r.rate_amount, statusLabel(r.status)])
    )
    downloadCsv(`referral-bonus-report_${period}.csv`, csv)
  }

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div className="flex flex-wrap items-end gap-3">
          <div className="space-y-1">
            <Label htmlFor="referral-report-month" className="block text-xs font-medium text-text-muted">
              {t("reports.referralBonus.month")}
            </Label>
            <Input id="referral-report-month" type="month" value={month} onChange={(e) => setMonth(e.target.value)} className="h-9 max-w-44 border-border" />
          </div>
          <div className="space-y-1">
            <Label htmlFor="referral-report-technician" className="block text-xs font-medium text-text-muted">
              {t("reports.referralBonus.technician")}
            </Label>
            <select
              id="referral-report-technician"
              value={technicianId}
              onChange={(e) => setTechnicianId(e.target.value)}
              className="h-9 max-w-56 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
            >
              <option value="">{t("reports.referralBonus.allTechnicians")}</option>
              {(technicians ?? []).map((tech) => (
                <option key={tech.id} value={tech.id}>
                  {tech.full_name}
                </option>
              ))}
            </select>
          </div>
        </div>
        <Button variant="outline" onClick={handleExport} disabled={rows.length === 0}>
          {t("reports.filters.exportCsv")}
        </Button>
      </div>

      {isError ? (
        <p className="text-sm text-danger">
          {t("reports.loadFailed")}{" "}
          <button type="button" className="underline" onClick={() => refetch()}>
            {t("common.retry")}
          </button>
        </p>
      ) : null}

      {summary && summary.pending_month_locked > 0 ? (
        <p className="rounded-xl bg-warning/10 px-3.5 py-2.5 text-sm font-medium text-warning">
          {t("reports.referralBonus.pendingMonthLocked", { count: summary.pending_month_locked })}
        </p>
      ) : null}

      {summary && (summary.pending_no_rate ?? 0) > 0 ? (
        <p className="rounded-xl bg-warning/10 px-3.5 py-2.5 text-sm font-medium text-warning">
          {t("reports.referralBonus.pendingNoRate", { count: summary.pending_no_rate })}
        </p>
      ) : null}

      <div className="grid grid-cols-2 gap-4 sm:grid-cols-5">
        <KpiCard label={t("reports.referralBonus.totalEvents")} value={isLoading ? "—" : String(summary?.total_events ?? 0)} icon={<Gift className="size-4" />} loading={isLoading} />
        <KpiCard label={t("reports.referralBonus.status.pending")} value={isLoading ? "—" : String(summary?.pending ?? 0)} loading={isLoading} />
        <KpiCard label={t("reports.referralBonus.status.approved")} value={isLoading ? "—" : String(summary?.approved ?? 0)} loading={isLoading} />
        <KpiCard label={t("reports.referralBonus.status.paid")} value={isLoading ? "—" : String(summary?.paid ?? 0)} loading={isLoading} />
        <KpiCard label={t("reports.referralBonus.status.voided")} value={isLoading ? "—" : String(summary?.voided ?? 0)} loading={isLoading} />
      </div>

      <DataTable columns={columns} rows={rows} rowKey={(r) => r.referral_bonus_event_id} loading={isLoading} emptyMessage={t("reports.referralBonus.empty")} />
      <p className="px-1 text-[11px] text-text-muted">{t("reports.referralBonus.voidNote")}</p>
    </div>
  )
}
