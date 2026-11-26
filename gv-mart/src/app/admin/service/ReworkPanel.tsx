// Rework on the ticket detail page (build-docs/features/rework.md): the links between an original job and
// its rework, and the "Mark as rework" form. The server (mark_ticket_rework) re-checks every rule shown here.
import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Link, useNavigate } from "react-router-dom"
import { Loader2, RotateCcw } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Label } from "@/components/ui/label"
import { DatePicker } from "@/components/ui/date-picker"
import { useToast } from "@/components/ui/toast-context"
import { AvailabilityTimeline } from "@/app/customer/components/AvailabilityTimeline"
import type { TimeWindow } from "@/lib/booking-window"
import { getIstNow } from "@/lib/ist"
import { useMarkTicketRework, useReworkChild } from "@/hooks/useRework"
import { getConflictAppointmentInfo } from "@/services/service"
import { formatDateTime } from "@/lib/formatDate"

const textareaClass =
  "w-full min-w-0 rounded-xl border border-input bg-surface px-3.5 py-2.5 text-sm text-text transition-colors outline-none placeholder:text-text-muted focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"

type TicketLike = {
  id: string
  status: string
  type: string | null
  rework_of_ticket_id?: string | null
  rework_reason?: string | null
  rework_outcome?: "free" | "paid" | null
  rework_escalation_reason?: string | null
  rework_responsible_technician_id?: string | null
}

type TechOption = { id: string; full_name: string; is_on_duty?: boolean }

/** "Rework of #…" on a rework ticket, "Rework raised → #…" on an original that has one. */
export function ReworkBanners({ ticket, technicians }: { ticket: TicketLike; technicians: TechOption[] | undefined }) {
  const { t } = useTranslation()
  const child = useReworkChild(ticket.rework_of_ticket_id ? undefined : ticket.id)
  const responsible = technicians?.find((x) => x.id === ticket.rework_responsible_technician_id)?.full_name

  if (ticket.rework_of_ticket_id) {
    return (
      <Card className="gap-1.5 border-danger/30 bg-danger/5 px-5">
        <p className="flex items-center gap-1.5 text-sm font-semibold text-danger">
          <RotateCcw className="size-4" />
          {t("service.rework.reworkOf")}{" "}
          <Link to={`/admin/service/${ticket.rework_of_ticket_id}`} className="underline">
            #{ticket.rework_of_ticket_id.slice(0, 8)}
          </Link>
        </p>
        {ticket.rework_reason ? <p className="text-sm text-text">{ticket.rework_reason}</p> : null}
        <p className="text-xs text-text-muted">
          {t("service.rework.responsible")}: {responsible ?? "—"}
          {ticket.rework_outcome ? ` · ${t(`service.rework.outcome.${ticket.rework_outcome}`)}` : ""}
        </p>
        {ticket.rework_escalation_reason ? (
          <p className="text-xs text-text-muted">
            {t("service.rework.escalationReason")}: {ticket.rework_escalation_reason}
          </p>
        ) : null}
      </Card>
    )
  }

  if (child.data) {
    return (
      <Card className="gap-1 border-danger/30 bg-danger/5 px-5">
        <p className="flex items-center gap-1.5 text-sm font-semibold text-danger">
          <RotateCcw className="size-4" />
          {t("service.rework.raised")}{" "}
          <Link to={`/admin/service/${child.data.id}`} className="underline">
            #{child.data.id.slice(0, 8)}
          </Link>
        </p>
      </Card>
    )
  }
  return null
}

/**
 * Inline "Mark as rework" form (same inline-card pattern as Cancel ticket). Defaults the technician to the
 * one who did the last finished visit; master / operation_admin may pick someone else.
 */
export function MarkReworkCard({
  ticketId,
  defaultTechnicianId,
  technicians,
  workStart,
  workEnd,
  narrowThreshold,
  estimatedMinutes,
  exemptionBlocks,
  onClose,
}: {
  ticketId: string
  defaultTechnicianId: string | null
  technicians: TechOption[] | undefined
  workStart: string
  workEnd: string
  narrowThreshold: number
  estimatedMinutes: number
  exemptionBlocks: TimeWindow[]
  onClose: () => void
}) {
  const { t } = useTranslation()
  const { toast } = useToast()
  const navigate = useNavigate()
  const markRework = useMarkTicketRework()
  const [reason, setReason] = useState("")
  const [date, setDate] = useState("")
  const [windows, setWindows] = useState<TimeWindow[]>([])
  const [technicianId, setTechnicianId] = useState(defaultTechnicianId ?? "")
  const reasonOk = reason.trim().length >= 5
  const today = getIstNow().date

  async function submit() {
    if (!reasonOk || !date) return
    try {
      const result = await markRework.mutateAsync({
        ticketId,
        reason: reason.trim(),
        scheduledDate: date,
        unavailableWindows: windows,
        technicianId: technicianId || null,
      })
      const assign = result.assign_result
      if (!assign || assign.assigned === false) {
        let detail: string | null = null
        if (assign?.conflict_appointment_id) {
          const info = await getConflictAppointmentInfo(assign.conflict_appointment_id).catch(() => null)
          if (info) {
            detail = t(assign.reason_key === "service.assign.customerBusy" ? "service.assign.customerBusyDetail" : "service.assign.technicianBusyDetail", {
              job: info.jobLabel,
              from: formatDateTime(info.scheduledAt),
              to: formatDateTime(info.endsAt),
            })
          }
        }
        toast.error(`${t("service.rework.createdUnassigned")} ${detail ?? (assign?.reason_key ? t(assign.reason_key) : "")}`.trim())
      } else {
        toast.success(t("service.rework.created"))
      }
      onClose()
      navigate(`/admin/service/${result.rework_ticket_id}`)
    } catch (err) {
      toast.error(err instanceof Error ? err.message : t("common.actionFailed"))
    }
  }

  return (
    <Card className="gap-3 px-5">
      <h2 className="text-sm font-semibold text-text">{t("service.rework.markTitle")}</h2>
      <p className="text-xs text-text-muted">{t("service.rework.markHelp")}</p>
      <div className="space-y-1.5">
        <Label htmlFor="rework-reason">{t("service.rework.reasonLabel")}</Label>
        <textarea
          id="rework-reason"
          rows={3}
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          placeholder={t("service.rework.reasonPlaceholder")}
          aria-invalid={reason.length > 0 && !reasonOk}
          aria-describedby="rework-reason-hint"
          className={textareaClass}
        />
        <p id="rework-reason-hint" className="text-xs text-text-muted">
          {t("service.rework.reasonHint")}
        </p>
      </div>
      <div className="space-y-1.5">
        <Label htmlFor="rework-date">{t("service.newComplaint.scheduledAt")}</Label>
        <DatePicker id="rework-date" className="w-44" min={today} value={date} onChange={setDate} />
      </div>
      <AvailabilityTimeline
        workStart={workStart}
        workEnd={workEnd}
        windows={windows}
        onChange={setWindows}
        exemptionWindows={exemptionBlocks}
        narrowThresholdMinutes={narrowThreshold}
        estimatedMinutes={estimatedMinutes}
      />
      <div className="space-y-1.5">
        <Label htmlFor="rework-technician">{t("service.newComplaint.assignTechnician")}</Label>
        <select
          id="rework-technician"
          value={technicianId}
          onChange={(e) => setTechnicianId(e.target.value)}
          className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none sm:max-w-xs"
        >
          <option value="">{t("service.rework.originalTechnician")}</option>
          {(technicians ?? []).map((tech) => (
            <option key={tech.id} value={tech.id}>
              {tech.full_name}
              {tech.id === defaultTechnicianId ? ` (${t("service.rework.original")})` : ""}
            </option>
          ))}
        </select>
        <p className="text-xs text-text-muted">{t("service.rework.responsibleNote")}</p>
      </div>
      <div className="flex gap-2">
        <Button size="sm" disabled={!reasonOk || !date || markRework.isPending} onClick={submit}>
          {markRework.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("service.rework.confirm")}
        </Button>
        <Button size="sm" variant="ghost" onClick={onClose}>
          {t("common.cancel")}
        </Button>
      </div>
    </Card>
  )
}
