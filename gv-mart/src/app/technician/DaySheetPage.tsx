import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { ArrowLeft, CalendarCheck2, CheckCircle2, Clock, IndianRupee, XCircle } from "lucide-react"
import { Card } from "@/components/ui/card"
import { Button } from "@/components/ui/button"
import { HighlightKpiCard } from "@/components/shared/HighlightKpiCard"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { useProfile } from "@/hooks/useProfile"
import { useMyTechnician } from "@/hooks/useTechnician"
import { useDaySheetSummary } from "@/hooks/useWorkspace"
import { formatCurrency } from "@/lib/sale-calc"
import { ATTENDANCE_STATUS_I18N_KEY } from "@/lib/attendance-status"

export function DaySheetPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { data: profile, isLoading: profileLoading, isError: profileError, refetch: refetchProfile } = useProfile()
  const technician = useMyTechnician()
  const summary = useDaySheetSummary(profile?.org_id, technician.data?.id)

  if (profileLoading || technician.isLoading) return <FullPageLoader label={t("common.loading")} />
  if (profileError || !profile) {
    return <FullPageError message={t("auth.profileLoadError")} onRetry={() => refetchProfile()} retryLabel={t("common.retry")} />
  }

  const attendance = summary.data?.attendance ?? null
  const attendanceStatusKey = !attendance ? "technician.daySheet.attendance.notMarked" : ATTENDANCE_STATUS_I18N_KEY[attendance.status]

  return (
    <div className="space-y-4 pt-2">
      <div className="flex items-center gap-2">
        <Button type="button" variant="ghost" size="icon-sm" onClick={() => navigate(-1)} aria-label={t("common.back")}>
          <ArrowLeft className="size-4" />
        </Button>
        <div>
          <h1 className="text-xl font-bold text-text">{t("technician.daySheet.title")}</h1>
          <p className="text-xs text-text-muted">{new Date().toLocaleDateString("en-IN", { weekday: "long", year: "numeric", month: "long", day: "numeric" })}</p>
        </div>
      </div>

      {summary.isError ? (
        <Card className="items-center gap-2 py-6 text-center">
          <p className="text-sm text-danger">{t("technician.errors.loadFailed")}</p>
          <Button type="button" variant="outline" size="sm" onClick={() => summary.refetch()}>
            {t("common.retry")}
          </Button>
        </Card>
      ) : (
        <>
          <HighlightKpiCard
            label={t("technician.daySheet.earningsToday")}
            value={summary.data ? formatCurrency(summary.data.earningsToday) : "—"}
            icon={<IndianRupee className="size-4" />}
            loading={summary.isLoading}
          />

          <div className="grid grid-cols-2 gap-3">
            <Card className="items-center gap-1.5 py-5 text-center">
              <CheckCircle2 className="size-5 text-success" />
              <p className="text-2xl font-bold text-text">{summary.isLoading ? "—" : (summary.data?.jobsDone ?? 0)}</p>
              <p className="text-xs text-text-muted">{t("technician.daySheet.jobsDone")}</p>
            </Card>
            <Card className="items-center gap-1.5 py-5 text-center">
              <Clock className="size-5 text-warning" />
              <p className="text-2xl font-bold text-text">{summary.isLoading ? "—" : (summary.data?.jobsPending ?? 0)}</p>
              <p className="text-xs text-text-muted">{t("technician.daySheet.jobsPending")}</p>
            </Card>
          </div>

          <Card className="flex-row items-center gap-3">
            <span className="flex size-10 shrink-0 items-center justify-center rounded-full bg-info/10 text-info">
              <CalendarCheck2 className="size-5" />
            </span>
            <div className="min-w-0 flex-1">
              <p className="text-sm font-semibold text-text">{t("technician.daySheet.attendanceTitle")}</p>
              <p className="text-xs text-text-muted">{t(attendanceStatusKey)}</p>
            </div>
            {attendance ? (
              <CheckCircle2 className="size-5 shrink-0 text-success" />
            ) : (
              <XCircle className="size-5 shrink-0 text-text-muted" />
            )}
          </Card>

          {!attendance ? (
            <Button type="button" className="w-full" onClick={() => navigate("/technician/attendance")}>
              {t("technician.daySheet.goToAttendance")}
            </Button>
          ) : null}
        </>
      )}
    </div>
  )
}
