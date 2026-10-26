import { useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { Loader2 } from "lucide-react"
import { Card } from "@/components/ui/card"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useToast } from "@/components/ui/toast-context"
import { useMyTechnician } from "@/hooks/useTechnician"
import { useRequestTechnicianLeave } from "@/hooks/useTechnicianLeave"

const MAX_REASON = 500

function todayIsoPlus(days: number): string {
  const d = new Date()
  d.setDate(d.getDate() + days)
  return d.toISOString().slice(0, 10)
}

export function RequestLeavePage() {
  const { t } = useTranslation()
  const { toast } = useToast()
  const navigate = useNavigate()
  const technician = useMyTechnician()
  const requestLeave = useRequestTechnicianLeave()

  const [startDate, setStartDate] = useState(todayIsoPlus(1))
  const [endDate, setEndDate] = useState(todayIsoPlus(1))
  const [reason, setReason] = useState("")

  const minStart = todayIsoPlus(1)
  const endBeforeStart = endDate < startDate
  const tooLong = (new Date(endDate).getTime() - new Date(startDate).getTime()) / 86_400_000 > 29

  function submit() {
    requestLeave.mutate(
      { startDate, endDate, reason: reason.trim() || null },
      {
        onSuccess: () => {
          toast.success(t("technicianLeave.request.submitted"))
          navigate("/technician/leave")
        },
        onError: (err) => toast.error(err instanceof Error && err.message ? err.message : t("common.actionFailed")),
      }
    )
  }

  return (
    <div className="space-y-4 pt-2">
      <div>
        <h1 className="text-2xl font-bold text-text">{t("technicianLeave.request.title")}</h1>
        <p className="text-sm text-text-muted">{t("technicianLeave.request.subtitle")}</p>
      </div>

      <Card className="gap-3.5">
        <div className="grid grid-cols-2 gap-3">
          <div className="space-y-1.5">
            <Label htmlFor="leave-start">{t("technicianLeave.request.startDate")}</Label>
            <Input id="leave-start" type="date" min={minStart} value={startDate} onChange={(e) => setStartDate(e.target.value)} />
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="leave-end">{t("technicianLeave.request.endDate")}</Label>
            <Input id="leave-end" type="date" min={startDate} value={endDate} onChange={(e) => setEndDate(e.target.value)} />
          </div>
        </div>
        {endBeforeStart ? <p className="text-sm text-danger">{t("technicianLeave.request.errors.endBeforeStart")}</p> : null}
        {tooLong ? <p className="text-sm text-danger">{t("technicianLeave.request.errors.tooLong")}</p> : null}

        <div className="space-y-1.5">
          <Label htmlFor="leave-reason">{t("technicianLeave.request.reason")}</Label>
          <textarea
            id="leave-reason"
            value={reason}
            onChange={(e) => setReason(e.target.value.slice(0, MAX_REASON))}
            maxLength={MAX_REASON}
            rows={3}
            className="w-full rounded-xl border border-border bg-surface px-3 py-2 text-sm text-text outline-none"
          />
          <p className="text-right text-xs text-text-muted">{reason.length}/{MAX_REASON}</p>
        </div>

        <Button
          disabled={!technician.data || endBeforeStart || tooLong || requestLeave.isPending}
          onClick={submit}
        >
          {requestLeave.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("technicianLeave.request.submit")}
        </Button>
      </Card>
    </div>
  )
}
