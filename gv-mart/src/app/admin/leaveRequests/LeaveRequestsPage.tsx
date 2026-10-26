import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { CalendarOff } from "lucide-react"
import { Card } from "@/components/ui/card"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { useToast } from "@/components/ui/toast-context"
import { useProfile } from "@/hooks/useProfile"
import { useOrgLeaveRequests, useDecideTechnicianLeave } from "@/hooks/useTechnicianLeave"
import { useSettings } from "@/hooks/useMasters"
import type { LeaveDecision, LeaveRequestListItem, LeaveRequestStatus } from "@/services/technicianLeave"
import { formatDate } from "@/lib/formatDate"
import { daysBetween, isInAdvance } from "@/lib/leaveNotice"
import { DecideLeaveDialog } from "./DecideLeaveDialog"

const FILTERS: { key: string; statuses: LeaveRequestStatus[] }[] = [
  { key: "pending", statuses: ["pending"] },
  { key: "approved", statuses: ["approved"] },
  { key: "closed", statuses: ["rejected", "revoked", "cancelled"] },
]

export function LeaveRequestsPage() {
  const { t } = useTranslation()
  const { toast } = useToast()
  const { data: profile } = useProfile()
  const [filterKey, setFilterKey] = useState<string>("pending")
  const statuses = FILTERS.find((f) => f.key === filterKey)?.statuses
  const { data, isLoading, isError, refetch } = useOrgLeaveRequests(profile?.org_id, statuses)
  const { data: settings } = useSettings(profile?.org_id)
  const noticeDays = settings?.leave_notice_days ?? 1
  const decide = useDecideTechnicianLeave()

  const [dialog, setDialog] = useState<{ request: LeaveRequestListItem; decision: LeaveDecision } | null>(null)

  function handleConfirm(note: string | null) {
    if (!dialog) return
    decide.mutate(
      { requestId: dialog.request.id, decision: dialog.decision, note },
      {
        onSuccess: () => {
          toast.success(t(`leaveRequests.toast.${dialog.decision}`))
          setDialog(null)
        },
        onError: (err) => toast.error(err instanceof Error && err.message ? err.message : t("common.actionFailed")),
      }
    )
  }

  const rows = useMemo(() => data ?? [], [data])

  return (
    <div className="space-y-4 pt-2">
      <div>
        <h1 className="text-2xl font-bold text-text">{t("nav.leaveRequests")}</h1>
        <p className="text-sm text-text-muted">{t("leaveRequests.subtitle")}</p>
      </div>

      <Card size="sm" className="flex-row flex-wrap gap-1.5 px-3 py-2">
        {FILTERS.map((f) => (
          <Button key={f.key} size="sm" variant={filterKey === f.key ? "default" : "ghost"} onClick={() => setFilterKey(f.key)}>
            {t(`leaveRequests.filters.${f.key}`)}
          </Button>
        ))}
      </Card>

      {isError ? (
        <Card className="items-center gap-2 py-8 text-center">
          <p className="text-sm text-danger">{t("leaveRequests.loadFailed")}</p>
          <button type="button" className="text-sm text-text underline" onClick={() => refetch()}>
            {t("common.retry")}
          </button>
        </Card>
      ) : isLoading ? (
        <Card className="items-center py-8 text-center">
          <p className="text-sm text-text-muted">{t("common.loading")}</p>
        </Card>
      ) : rows.length === 0 ? (
        <Card className="items-center gap-2 py-10 text-center">
          <CalendarOff className="size-6 text-text-muted" />
          <p className="text-sm text-text-muted">{t("leaveRequests.empty")}</p>
        </Card>
      ) : (
        <div className="space-y-2">
          {rows.map((r) => {
            const inAdvance = r.status === "pending" ? isInAdvance(r.created_at, r.start_date, noticeDays) : r.protected
            return (
              <Card key={r.id} size="sm" className="flex-row flex-wrap items-center justify-between gap-3 px-4 py-3">
                <div className="min-w-0 space-y-1">
                  <div className="flex flex-wrap items-center gap-2">
                    <p className="font-medium text-text">{r.technicians?.profiles?.full_name ?? "—"}</p>
                    <Badge variant={r.status === "pending" ? "warning" : r.status === "approved" ? "success" : "outline"}>
                      {t(`leaveRequests.status.${r.status}`)}
                    </Badge>
                    {r.status !== "rejected" && r.status !== "cancelled" ? (
                      <Badge variant={inAdvance ? "success" : "danger"}>
                        {inAdvance ? t("leaveRequests.badge.inAdvance") : t("leaveRequests.badge.late")}
                      </Badge>
                    ) : null}
                  </div>
                  <p className="text-sm text-text-muted">
                    {formatDate(r.start_date)} – {formatDate(r.end_date)} ({daysBetween(r.start_date, r.end_date)}{" "}
                    {t("leaveRequests.days")})
                  </p>
                  {r.reason ? <p className="text-sm text-text">{r.reason}</p> : null}
                  <p className="text-xs text-text-muted">{t("leaveRequests.requestedAt", { date: formatDate(r.created_at) })}</p>
                  {r.decision_note ? <p className="text-xs text-text-muted">{t("leaveRequests.decisionNote", { note: r.decision_note })}</p> : null}
                </div>
                <div className="flex shrink-0 gap-1.5">
                  {r.status === "pending" ? (
                    <>
                      <Button size="sm" onClick={() => setDialog({ request: r, decision: "approved" })}>
                        {t("leaveRequests.actions.approve")}
                      </Button>
                      <Button size="sm" variant="destructive" onClick={() => setDialog({ request: r, decision: "rejected" })}>
                        {t("leaveRequests.actions.reject")}
                      </Button>
                    </>
                  ) : null}
                  {r.status === "approved" && new Date(r.start_date) > new Date() ? (
                    <Button size="sm" variant="destructive" onClick={() => setDialog({ request: r, decision: "revoked" })}>
                      {t("leaveRequests.actions.revoke")}
                    </Button>
                  ) : null}
                </div>
              </Card>
            )
          })}
        </div>
      )}

      <DecideLeaveDialog
        request={dialog?.request ?? null}
        decision={dialog?.decision ?? null}
        open={!!dialog}
        onClose={() => setDialog(null)}
        onConfirm={handleConfirm}
        isPending={decide.isPending}
      />
    </div>
  )
}
