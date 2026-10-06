import { useState } from "react"
import { useTranslation } from "react-i18next"
import { useQueryClient } from "@tanstack/react-query"
import { Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useToast } from "@/components/ui/toast-context"
import { useProfile } from "@/hooks/useProfile"
import { useLeadSchedule, useSetLeadFollowup } from "@/hooks/useLeadFollowups"
import { NextFollowupPicker } from "./NextFollowupPicker"
import { DEFAULT_LEAD_SCHEDULE } from "@/services/leadFollowups"
import {
  FOLLOWUP_NOTE_MAX,
  FOLLOWUP_TYPES,
  addDays,
  canSetFollowup,
  cleanFollowupNote,
  formatIstDateTime,
  getIstNow,
  isFollowupAlreadySetError,
  nextWorkingDay,
  toIso,
  type NextFollowupValue,
  type SetFollowupType,
} from "@/lib/lead-followups"
import { cn } from "@/lib/utils"

/**
 * Schedule the first follow-up for an open lead that has none, without logging
 * a (fake) call outcome. Unlike Reschedule nothing is postponed, so no reason
 * is asked and the postpone count is untouched.
 */
export function SetFollowupDialog({
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
          <DialogTitle>{t("leads.followup.setTitle")}</DialogTitle>
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
  const setFollowup = useSetLeadFollowup()
  const qc = useQueryClient()
  const [type, setType] = useState<SetFollowupType>("call")
  const [note, setNote] = useState("")
  const [next, setNext] = useState<NextFollowupValue>(() => {
    const now = getIstNow()
    return { date: nextWorkingDay(addDays(now.date, 0), schedule.lead_work_days), time: "10:00", exact: false }
  })
  const [keepNonWorking, setKeepNonWorking] = useState<string | null>(null)

  const canSave = canSetFollowup({ type, next })

  async function save() {
    try {
      const dueAt = toIso(next.date!, next.time!)
      await setFollowup.mutateAsync({ leadId, dueAt, type, note: cleanFollowupNote(note), isExact: next.exact })
      toast.success(t("leads.followup.setSaved", { when: formatIstDateTime(dueAt, i18n.language) }))
      onClose()
      onDone?.()
    } catch (e) {
      if (isFollowupAlreadySetError(e)) {
        // Someone else set it first: refresh so the page shows their follow-up, then close.
        qc.invalidateQueries({ queryKey: ["followups"] })
        qc.invalidateQueries({ queryKey: ["leads"] })
        toast.error(t("leads.followup.setAlreadySet"))
        onClose()
        return
      }
      const msg = (e as { message?: unknown } | null)?.message
      toast.error(typeof msg === "string" && msg ? msg : t("common.actionFailed"))
    }
  }

  return (
    <div className="space-y-4">
      <section className="space-y-2">
        <Label>{t("leads.followup.setType")}</Label>
        <div className="flex flex-wrap gap-1.5">
          {FOLLOWUP_TYPES.map((c) => (
            <button
              key={c}
              type="button"
              aria-pressed={type === c}
              onClick={() => setType(c)}
              className={cn(
                "rounded-full border px-3 py-1.5 text-xs font-semibold transition-colors",
                type === c ? "border-ink bg-ink text-white" : "border-border bg-surface text-text hover:bg-surface-alt"
              )}
            >
              {t(`leads.followup.type.${c}`)}
            </button>
          ))}
        </div>
      </section>
      <section className="space-y-2">
        <Label>{t("leads.followup.setWhen")}</Label>
        <NextFollowupPicker
          value={next}
          onChange={setNext}
          workDays={schedule.lead_work_days}
          workEnd={schedule.lead_work_end}
          keepNonWorking={keepNonWorking}
          onKeepNonWorking={setKeepNonWorking}
        />
      </section>
      <section className="space-y-2">
        <Label htmlFor="set-followup-note">{t("leads.followup.setNote")}</Label>
        <Input
          id="set-followup-note"
          value={note}
          maxLength={FOLLOWUP_NOTE_MAX}
          onChange={(e) => setNote(e.target.value)}
          placeholder={t("leads.followup.setNotePlaceholder")}
        />
      </section>
      <div className="flex justify-end gap-2">
        <Button variant="ghost" onClick={onClose} disabled={setFollowup.isPending}>
          {t("common.cancel")}
        </Button>
        <Button variant="accent" onClick={save} disabled={!canSave || setFollowup.isPending}>
          {setFollowup.isPending ? <Loader2 className="size-4 animate-spin" /> : t("leads.followup.setSave")}
        </Button>
      </div>
    </div>
  )
}
