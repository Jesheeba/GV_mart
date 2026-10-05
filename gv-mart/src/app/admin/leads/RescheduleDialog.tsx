import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useToast } from "@/components/ui/toast-context"
import { useProfile } from "@/hooks/useProfile"
import { useLeadSchedule, useRescheduleFollowup } from "@/hooks/useLeadFollowups"
import { NextFollowupPicker } from "./NextFollowupPicker"
import { DEFAULT_LEAD_SCHEDULE } from "@/services/leadFollowups"
import { addDays, formatIstDateTime, getIstNow, isNextFollowupValid, nextWorkingDay, toIso, type NextFollowupValue } from "@/lib/lead-followups"
import { cn } from "@/lib/utils"

const REASONS = ["customerAsked", "unreachable", "busy", "waitingStock"] as const

/**
 * Postpone a follow-up WITHOUT having spoken to the customer. The old task is
 * kept (cancelled with this reason) and a new one is created, so the history
 * shows every postponement. Pushing it later counts toward the lead's
 * postpone count (3+ = stuck).
 */
export function RescheduleDialog({
  lead,
  open,
  onOpenChange,
  onDone,
}: {
  lead: { id: string; name: string } | null
  open: boolean
  onOpenChange: (open: boolean) => void
  onDone?: () => void
}) {
  const { t } = useTranslation()
  return (
    <Dialog open={open && !!lead} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-lg gap-4">
        <div>
          <DialogTitle>{t("leads.reschedule.title")}</DialogTitle>
          <DialogDescription>{lead?.name}</DialogDescription>
        </div>
        {lead ? <Body key={lead.id} leadId={lead.id} onClose={() => onOpenChange(false)} onDone={onDone} /> : null}
      </DialogContent>
    </Dialog>
  )
}

function Body({ leadId, onClose, onDone }: { leadId: string; onClose: () => void; onDone?: () => void }) {
  const { t, i18n } = useTranslation()
  const { toast } = useToast()
  const { data: profile } = useProfile()
  const schedule = useLeadSchedule(profile?.org_id).data ?? DEFAULT_LEAD_SCHEDULE
  const reschedule = useRescheduleFollowup()
  const [reason, setReason] = useState("")
  const [next, setNext] = useState<NextFollowupValue>(() => {
    const now = getIstNow()
    return { date: nextWorkingDay(addDays(now.date, 0), schedule.lead_work_days), time: "10:00", exact: false }
  })
  const [keepNonWorking, setKeepNonWorking] = useState<string | null>(null)

  const canSave = reason.trim() !== "" && isNextFollowupValid(next)

  async function save() {
    try {
      const res = await reschedule.mutateAsync({ leadId, newDueAt: toIso(next.date!, next.time!), reason: reason.trim(), isExact: next.exact })
      toast.success(t("leads.reschedule.saved", { when: formatIstDateTime(res.next_due_at, i18n.language) }))
      onClose()
      onDone?.()
    } catch (e) {
      toast.error(e instanceof Error && e.message ? e.message : t("common.actionFailed"))
    }
  }

  return (
    <div className="space-y-4">
      <section className="space-y-2">
        <Label htmlFor="reschedule-reason">{t("leads.reschedule.reason")}</Label>
        <Input id="reschedule-reason" value={reason} onChange={(e) => setReason(e.target.value)} placeholder={t("leads.reschedule.reasonPlaceholder")} />
        <div className="flex flex-wrap gap-1.5">
          {REASONS.map((r) => {
            const text = t(`leads.reschedule.reasons.${r}`)
            return (
              <button
                key={r}
                type="button"
                onClick={() => setReason(text)}
                className={cn("rounded-full px-2.5 py-1 text-[11px] font-medium", reason === text ? "bg-ink text-white" : "bg-surface-alt text-text-muted hover:text-text")}
              >
                {text}
              </button>
            )
          })}
        </div>
      </section>
      <section className="space-y-2">
        <Label>{t("leads.reschedule.newTime")}</Label>
        <NextFollowupPicker
          value={next}
          onChange={setNext}
          workDays={schedule.lead_work_days}
          workEnd={schedule.lead_work_end}
          keepNonWorking={keepNonWorking}
          onKeepNonWorking={setKeepNonWorking}
        />
      </section>
      <p className="text-xs text-text-muted">{t("leads.reschedule.hint")}</p>
      <div className="flex justify-end gap-2">
        <Button variant="ghost" onClick={onClose} disabled={reschedule.isPending}>
          {t("common.cancel")}
        </Button>
        <Button variant="accent" onClick={save} disabled={!canSave || reschedule.isPending}>
          {reschedule.isPending ? <Loader2 className="size-4 animate-spin" /> : t("leads.reschedule.save")}
        </Button>
      </div>
    </div>
  )
}
