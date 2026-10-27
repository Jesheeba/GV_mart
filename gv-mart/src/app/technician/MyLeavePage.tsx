import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { CalendarOff, Plus } from "lucide-react"
import { Card } from "@/components/ui/card"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { useToast } from "@/components/ui/toast-context"
import { FullPageLoader } from "@/components/shared/FullPageLoader"
import { InlineErrorState } from "@/components/shared/InlineErrorState"
import { useMyTechnician } from "@/hooks/useTechnician"
import { useCancelTechnicianLeave, useMyLeaveRequests } from "@/hooks/useTechnicianLeave"
import { formatDate } from "@/lib/formatDate"
import { isNotYetAvailableError } from "@/lib/supabaseErrors"
import { resolveSectionState } from "@/lib/listState"

const STATUS_VARIANT = {
  pending: "warning",
  approved: "success",
  rejected: "danger",
  cancelled: "outline",
  revoked: "outline",
} as const

export function MyLeavePage() {
  const { t } = useTranslation()
  const { toast } = useToast()
  const navigate = useNavigate()
  const technician = useMyTechnician()
  const { data, isLoading, isError, error, refetch } = useMyLeaveRequests(technician.data?.id)
  const cancel = useCancelTechnicianLeave()

  if (technician.isLoading) return <FullPageLoader />

  const today = new Date()
  const rows = data ?? []
  const state = resolveSectionState({ isLoading, isError, isEmpty: rows.length === 0 })

  return (
    <div className="space-y-4 pt-2">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-bold text-text">{t("technicianLeave.myLeave.title")}</h1>
        <Button size="sm" onClick={() => navigate("/technician/leave/new")}>
          <Plus className="size-4" />
          {t("technicianLeave.myLeave.request")}
        </Button>
      </div>

      {state === "loading" ? (
        <p className="text-sm text-text-muted">{t("common.loading")}</p>
      ) : state === "error" ? (
        <InlineErrorState
          message={isNotYetAvailableError(error) ? t("technicianLeave.notAvailableYet") : t("technician.errors.loadFailed")}
          onRetry={() => void refetch()}
          retryLabel={t("common.retry")}
        />
      ) : state === "empty" ? (
        <Card className="items-center gap-2 py-10 text-center">
          <CalendarOff className="size-6 text-text-muted" />
          <p className="text-sm text-text-muted">{t("technicianLeave.myLeave.empty")}</p>
        </Card>
      ) : (
        <div className="space-y-2">
          {rows.map((r) => {
            const canCancel = r.status === "pending" || (r.status === "approved" && new Date(r.start_date) > today)
            return (
              <Card key={r.id} size="sm" className="gap-1.5 px-4 py-3">
                <div className="flex items-center justify-between gap-2">
                  <p className="font-medium text-text">
                    {formatDate(r.start_date)} – {formatDate(r.end_date)}
                  </p>
                  <Badge variant={STATUS_VARIANT[r.status as keyof typeof STATUS_VARIANT] ?? "outline"}>
                    {t(`leaveRequests.status.${r.status}`)}
                  </Badge>
                </div>
                {r.reason ? <p className="text-sm text-text-muted">{r.reason}</p> : null}
                {(r.status === "rejected" || r.status === "revoked") && r.decision_note ? (
                  <p className="text-sm text-danger">{t("leaveRequests.decisionNote", { note: r.decision_note })}</p>
                ) : null}
                {canCancel ? (
                  <Button
                    size="sm"
                    variant="ghost"
                    className="mt-1 self-start"
                    disabled={cancel.isPending}
                    onClick={() =>
                      cancel.mutate(r.id, {
                        onSuccess: () => toast.success(t("technicianLeave.myLeave.cancelled")),
                        onError: (err) => toast.error(isNotYetAvailableError(err) ? t("technicianLeave.notAvailableYet") : t("common.actionFailed")),
                      })
                    }
                  >
                    {t("technicianLeave.myLeave.cancel")}
                  </Button>
                ) : null}
              </Card>
            )
          })}
        </div>
      )}
    </div>
  )
}
