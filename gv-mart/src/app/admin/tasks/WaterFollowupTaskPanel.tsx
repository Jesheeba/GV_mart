import { useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Label } from "@/components/ui/label"
import { DatePicker } from "@/components/ui/date-picker"
import { useToast } from "@/components/ui/toast-context"
import { useCustomer, usePostponeWaterFollowup } from "@/hooks/useCustomers"
import { getIstNow } from "@/lib/ist"
import { postponeDateError } from "@/lib/waterFollowup"
import type { OrgTask } from "@/services/tasks"

/** Navigation state LeadsPage reads to open New Lead prefilled, then close this task once the lead is saved. */
export type WaterFollowupLeadState = {
  newLeadForCustomer: { id: string; name: string; mobile: string | null }
  fromWaterFollowup: { taskId: string; requirement: string }
}

/**
 * Water solution follow-up task (ref_type customer_water_followup, ref_id = customer): postpone with a required
 * reason, or convert to a lead. See build-docs/features/water-solution-followup.md.
 */
export function WaterFollowupTaskPanel({ task, canAct, onDone }: { task: OrgTask; canAct: boolean; onDone: () => void }) {
  const { t } = useTranslation()
  const { toast } = useToast()
  const navigate = useNavigate()
  const customer = useCustomer(task.ref_id ?? undefined)
  const postpone = usePostponeWaterFollowup()
  const [postponing, setPostponing] = useState(false)
  const [newDate, setNewDate] = useState("")
  const [reason, setReason] = useState("")
  const today = getIstNow().date
  const isOpen = task.status === "open"
  const dateError = newDate ? postponeDateError(newDate, task.due_date, today) : null
  const canPostpone = !!newDate && !dateError && reason.trim().length > 0 && reason.trim().length <= 500 && !postpone.isPending

  function submitPostpone() {
    if (!canPostpone) return
    postpone.mutate(
      { taskId: task.id, newDate, reason: reason.trim() },
      {
        onSuccess: () => {
          toast.success(t("tasks.waterFollowup.postponed"))
          onDone()
        },
        onError: () => toast.error(t("common.actionFailed")),
      }
    )
  }

  function convertToLead() {
    const c = customer.data
    if (!c) return
    const state: WaterFollowupLeadState = {
      newLeadForCustomer: { id: c.id, name: c.name, mobile: c.mobile },
      fromWaterFollowup: { taskId: task.id, requirement: task.description ?? "" },
    }
    navigate("/admin/leads", { state })
  }

  return (
    <div className="space-y-2.5 rounded-xl border border-border bg-surface-alt px-3 py-2.5 text-sm">
      <p className="font-medium text-text">{t("tasks.waterFollowup.title")}</p>
      {task.description ? <p className="whitespace-pre-line text-text-muted">{task.description}</p> : null}
      <div className="flex flex-wrap gap-2">
        {task.ref_id ? (
          <Button type="button" size="sm" variant="outline" onClick={() => navigate(`/admin/customers/${task.ref_id}`)}>
            {t("tasks.waterFollowup.viewCustomer")}
          </Button>
        ) : null}
        {isOpen && canAct ? (
          <>
            <Button type="button" size="sm" variant="outline" onClick={() => setPostponing((v) => !v)} aria-expanded={postponing}>
              {t("tasks.waterFollowup.postpone")}
            </Button>
            <Button type="button" size="sm" onClick={convertToLead} disabled={!customer.data}>
              {customer.isLoading ? <Loader2 className="size-3.5 animate-spin" /> : null}
              {t("tasks.waterFollowup.convertToLead")}
            </Button>
          </>
        ) : null}
      </div>
      {postponing && isOpen && canAct ? (
        <div className="space-y-2 border-t border-border pt-2.5">
          <div className="space-y-1.5">
            <Label htmlFor="waterFollowupNewDate">{t("tasks.waterFollowup.newDate")}</Label>
            <DatePicker id="waterFollowupNewDate" value={newDate} onChange={setNewDate} min={today} aria-invalid={!!dateError} />
            {dateError ? <p className="text-xs text-danger">{t(dateError)}</p> : null}
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="waterFollowupReason">{t("tasks.waterFollowup.reason")}</Label>
            <textarea
              id="waterFollowupReason"
              rows={2}
              maxLength={500}
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              placeholder={t("tasks.waterFollowup.reasonPlaceholder")}
              className="w-full resize-none rounded-xl border border-input bg-surface px-3 py-2 text-sm text-text outline-none focus-visible:border-ring"
            />
          </div>
          <div className="flex justify-end">
            <Button type="button" size="sm" onClick={submitPostpone} disabled={!canPostpone}>
              {postpone.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("tasks.waterFollowup.confirmPostpone")}
            </Button>
          </div>
        </div>
      ) : null}
    </div>
  )
}
