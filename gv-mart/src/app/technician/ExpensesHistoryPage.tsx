import { useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { Card } from "@/components/ui/card"
import { Button } from "@/components/ui/button"
import { StatusDot } from "@/components/shared/StatusDot"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { PeriodFilter } from "@/app/admin/reports/PeriodFilter"
import { periodToRange, type PeriodValue } from "@/services/reports"
import { useMyTechnician } from "@/hooks/useTechnician"
import { useKmLogEntries, useMyExpenseClaims } from "@/hooks/useMonthlyExpenses"

/** Monthly Expenses spec §1.5/§1.8 — a technician's own submissions and
 *  history, filtered by date range or by month, reusing PeriodFilter
 *  exactly as the admin report tabs do (confirmed dependency-free). */
export function ExpensesHistoryPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const technician = useMyTechnician()
  const [period, setPeriod] = useState<PeriodValue>({ mode: "month", month: new Date().toISOString().slice(0, 7) })
  const range = periodToRange(period)

  const claims = useMyExpenseClaims(technician.data?.id)
  const kmEntries = useKmLogEntries(technician.data?.id, range)

  if (technician.isLoading) return <FullPageLoader label={t("common.loading")} />
  if (technician.isError || !technician.data) {
    return <FullPageError message={t("technician.errors.loadFailed")} onRetry={() => technician.refetch()} retryLabel={t("common.retry")} />
  }

  const filteredClaims = (claims.data ?? []).filter((c) => c.period >= range.from.slice(0, 7) + "-01" && c.period <= range.to)

  return (
    <div className="space-y-4 pt-2">
      <h1 className="text-xl font-bold text-text">{t("technician.expenses.history")}</h1>
      <PeriodFilter value={period} onChange={setPeriod} />

      <div className="space-y-2">
        <p className="text-sm font-semibold text-text">{t("technician.expenses.myClaims")}</p>
        {filteredClaims.length === 0 ? (
          <p className="text-sm text-text-muted">{t("technician.expenses.noClaims")}</p>
        ) : (
          filteredClaims.map((c) => (
            <Card key={c.id} className="gap-1.5 py-2.5">
              <div className="flex items-center justify-between gap-2">
                <p className="text-sm font-semibold text-text">{t(`technician.expenses.claimTypeValues.${c.claim_type}`)}</p>
                <StatusDot
                  tone={c.verified_amount == null ? "warning" : c.verified_amount > 0 ? "success" : "danger"}
                  label={
                    c.verified_amount == null
                      ? t("technician.expenses.statusPending")
                      : c.verified_amount > 0
                        ? t("technician.expenses.statusApproved")
                        : t("technician.expenses.statusRejected")
                  }
                />
              </div>
              <p className="text-xs text-text-muted">
                {t("technician.expenses.submittedAmount")}: ₹{c.submitted_amount}
                {c.verified_amount != null ? ` · ${t("technician.expenses.approvedAmount")}: ₹${c.verified_amount}` : ""}
              </p>
              {c.reason ? <p className="text-xs text-text-muted">{c.reason}</p> : null}
            </Card>
          ))
        )}
      </div>

      <div className="space-y-2">
        <p className="text-sm font-semibold text-text">{t("technician.expenses.myKmLog")}</p>
        {(kmEntries.data ?? []).length === 0 ? (
          <p className="text-sm text-text-muted">{t("technician.expenses.noKmEntries")}</p>
        ) : (
          kmEntries.data!.map((e) => (
            <Card key={e.id} className="flex-row items-center justify-between gap-2 py-2">
              <span className="text-sm text-text">{e.entry_date}</span>
              <span className="text-sm font-semibold text-text">{e.km} km</span>
            </Card>
          ))
        )}
      </div>

      <Button type="button" variant="outline" onClick={() => navigate(-1)}>
        {t("common.back")}
      </Button>
    </div>
  )
}
