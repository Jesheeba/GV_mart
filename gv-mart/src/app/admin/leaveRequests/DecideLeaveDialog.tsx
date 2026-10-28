import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import { Label } from "@/components/ui/label"
import { InlineErrorState } from "@/components/shared/InlineErrorState"
import { useAssignedVisitsInRange } from "@/hooks/useTechnicianLeave"
import type { LeaveDecision, LeaveRequestListItem } from "@/services/technicianLeave"
import { formatDate } from "@/lib/formatDate"
import { isNotYetAvailableError } from "@/lib/supabaseErrors"

/**
 * One dialog for all three admin decisions. Approve shows the technician's already-assigned
 * visits on those days as a warning (§2.2: "so ops can reassign them" — nothing here reassigns
 * anything automatically). Reject and revoke require a short note.
 */
export function DecideLeaveDialog({
  request,
  decision,
  open,
  onClose,
  onConfirm,
  isPending,
}: {
  request: LeaveRequestListItem | null
  decision: LeaveDecision | null
  open: boolean
  onClose: () => void
  onConfirm: (note: string | null) => void
  isPending: boolean
}) {
  const { t } = useTranslation()
  const [note, setNote] = useState("")
  const visits = useAssignedVisitsInRange(
    decision === "approved" ? request?.technician_id : undefined,
    request?.start_date,
    request?.end_date
  )
  const noteRequired = decision === "rejected" || decision === "revoked"

  if (!request || !decision) return null

  return (
    <Dialog
      open={open}
      onOpenChange={(o) => {
        if (!o && !isPending) {
          setNote("")
          onClose()
        }
      }}
    >
      <DialogContent className="max-w-md">
        <DialogTitle>{t(`leaveRequests.decideDialog.title.${decision}`)}</DialogTitle>
        <DialogDescription>
          {t("leaveRequests.decideDialog.range", {
            technician: request.technicians?.profiles?.full_name ?? "—",
            start: formatDate(request.start_date),
            end: formatDate(request.end_date),
          })}
        </DialogDescription>

        {decision === "approved" ? (
          visits.isLoading ? (
            <p className="text-sm text-text-muted">{t("common.loading")}</p>
          ) : visits.isError ? (
            // Never fall through to "no assigned visits" on a failed check — that would read as
            // "nothing to warn about" when the truth is "we don't know, the check failed".
            <InlineErrorState
              message={isNotYetAvailableError(visits.error) ? t("leaveRequests.notAvailableYet") : t("leaveRequests.decideDialog.assignedVisitsCheckFailed")}
              onRetry={() => visits.refetch()}
              retryLabel={t("common.retry")}
            />
          ) : visits.data && visits.data.length > 0 ? (
            <div className="space-y-1 rounded-xl border border-warning/30 bg-warning/10 p-3 text-sm text-warning">
              <p className="font-medium">{t("leaveRequests.decideDialog.assignedVisitsWarning", { count: visits.data.length })}</p>
              <ul className="list-inside list-disc space-y-0.5">
                {visits.data.map((v) => (
                  <li key={v.appointment_id}>
                    {formatDate(v.scheduled_at)} — {v.customer_name ?? "—"} ({v.name_of_complaint ?? "—"})
                  </li>
                ))}
              </ul>
            </div>
          ) : (
            <p className="text-sm text-text-muted">{t("leaveRequests.decideDialog.noAssignedVisits")}</p>
          )
        ) : (
          <div className="space-y-1.5">
            <Label htmlFor="leave-decision-note">{t("leaveRequests.decideDialog.noteLabel")}</Label>
            <textarea
              id="leave-decision-note"
              value={note}
              onChange={(e) => setNote(e.target.value)}
              maxLength={500}
              rows={3}
              className="w-full rounded-xl border border-border bg-surface px-3 py-2 text-sm text-text outline-none"
              placeholder={t("leaveRequests.decideDialog.notePlaceholder")}
            />
          </div>
        )}

        <div className="flex justify-end gap-1.5">
          <Button variant="ghost" disabled={isPending} onClick={onClose}>
            {t("common.cancel")}
          </Button>
          <Button
            variant={decision === "approved" ? "default" : "destructive"}
            disabled={isPending || (noteRequired && note.trim() === "")}
            onClick={() => onConfirm(noteRequired ? note.trim() : null)}
          >
            {isPending ? <Loader2 className="size-3.5 animate-spin" /> : t(`leaveRequests.decideDialog.confirm.${decision}`)}
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  )
}
