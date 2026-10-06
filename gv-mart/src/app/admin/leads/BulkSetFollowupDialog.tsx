import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useToast } from "@/components/ui/toast-context"
import { useProfile } from "@/hooks/useProfile"
import { useLeadSchedule, useSetFollowupsBulk } from "@/hooks/useLeadFollowups"
import { NextFollowupPicker } from "./NextFollowupPicker"
import { DEFAULT_LEAD_SCHEDULE } from "@/services/leadFollowups"
import { FOLLOWUP_NOTE_MAX, FOLLOWUP_TYPES, addDays, cleanFollowupNote, getIstNow, isNextFollowupValid, nextWorkingDay, toIso, type NextFollowupValue, type SetFollowupType } from "@/lib/lead-followups"
import { BULK_DEFAULT_PER_DAY, BULK_MAX_LEADS, isValidPerDay, spreadPlan, summariseSkipped } from "@/lib/lead-spread"
import { cn } from "@/lib/utils"

/**
 * Master bulk action on the "No follow-up" tab: schedule every selected lead in one go, either all at the same time or
 * spread N a day over the next working days (oldest lead first, evenly between opening+30 min and closing-1 h).
 */
export function BulkSetFollowupDialog({
  leadIds,
  open,
  onOpenChange,
  onDone,
}: {
  leadIds: string[]
  open: boolean
  onOpenChange: (open: boolean) => void
  onDone?: () => void
}) {
  const { t } = useTranslation()
  return (
    <Dialog open={open && leadIds.length > 0} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-lg gap-4">
        <div>
          <DialogTitle>{t("leads.noFollowup.bulkTitle", { count: leadIds.length })}</DialogTitle>
          <DialogDescription>{t("leads.noFollowup.bulkHint")}</DialogDescription>
        </div>
        {leadIds.length > 0 ? <Body key={leadIds.join(",")} leadIds={leadIds} onClose={() => onOpenChange(false)} onDone={onDone} /> : null}
      </DialogContent>
    </Dialog>
  )
}

function Body({ leadIds, onClose, onDone }: { leadIds: string[]; onClose: () => void; onDone?: () => void }) {
  const { t } = useTranslation()
  const { toast } = useToast()
  const { data: profile } = useProfile()
  const schedule = useLeadSchedule(profile?.org_id).data ?? DEFAULT_LEAD_SCHEDULE
  const bulk = useSetFollowupsBulk()
  const [type, setType] = useState<SetFollowupType>("call")
  const [note, setNote] = useState("")
  const [mode, setMode] = useState<"spread" | "same">("spread")
  const [perDay, setPerDay] = useState(String(BULK_DEFAULT_PER_DAY))
  const [startDate, setStartDate] = useState(() => nextWorkingDay(addDays(getIstNow().date, 1), schedule.lead_work_days))
  const [next, setNext] = useState<NextFollowupValue>(() => ({ date: nextWorkingDay(addDays(getIstNow().date, 1), schedule.lead_work_days), time: "10:00", exact: false }))
  const [keepNonWorking, setKeepNonWorking] = useState<string | null>(null)

  const tomorrow = addDays(getIstNow().date, 1)
  const perDayOk = isValidPerDay(perDay)
  const plan = mode === "spread" && perDayOk ? spreadPlan(leadIds.length, Number(perDay)) : null
  const tooMany = leadIds.length > BULK_MAX_LEADS
  const canSave = !tooMany && (mode === "spread" ? perDayOk && startDate >= tomorrow : isNextFollowupValid(next))

  async function save() {
    try {
      const res = await bulk.mutateAsync({
        leadIds,
        dueAt: mode === "spread" ? toIso(startDate, "10:00") : toIso(next.date!, next.time!),
        type,
        note: cleanFollowupNote(note),
        perDay: mode === "spread" ? Number(perDay) : null,
      })
      const skipped = summariseSkipped(res.skipped)
      const skippedText = Object.entries(skipped)
        .map(([reason, n]) => `${n} ${t(`leads.noFollowup.skipped.${reason}`)}`)
        .join(", ")
      toast.success(t("leads.noFollowup.bulkDone", { count: res.created }) + (skippedText ? " " + t("leads.noFollowup.bulkSkipped", { detail: skippedText }) : ""))
      onClose()
      onDone?.()
    } catch (e) {
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
              className={cn("rounded-full border px-3 py-1.5 text-xs font-semibold transition-colors", type === c ? "border-ink bg-ink text-white" : "border-border bg-surface text-text hover:bg-surface-alt")}
            >
              {t(`leads.followup.type.${c}`)}
            </button>
          ))}
        </div>
      </section>

      <fieldset className="space-y-2">
        <legend className="text-xs font-medium text-text-muted">{t("leads.followup.setWhen")}</legend>
        <label className="flex items-center gap-2 text-sm text-text">
          <input type="radio" name="bulk-mode" checked={mode === "spread"} onChange={() => setMode("spread")} />
          {t("leads.noFollowup.modeSpread")}
        </label>
        <label className="flex items-center gap-2 text-sm text-text">
          <input type="radio" name="bulk-mode" checked={mode === "same"} onChange={() => setMode("same")} />
          {t("leads.noFollowup.modeSame")}
        </label>
      </fieldset>

      {mode === "spread" ? (
        <section className="space-y-2">
          <div className="flex flex-wrap items-end gap-3">
            <div className="space-y-1">
              <Label htmlFor="bulk-start" className="block text-xs font-medium text-text-muted">
                {t("leads.noFollowup.startDay")}
              </Label>
              <Input id="bulk-start" type="date" min={tomorrow} value={startDate} onChange={(e) => setStartDate(e.target.value)} className="w-44" />
            </div>
            <div className="space-y-1">
              <Label htmlFor="bulk-per-day" className="block text-xs font-medium text-text-muted">
                {t("leads.noFollowup.perDay")}
              </Label>
              <Input id="bulk-per-day" inputMode="numeric" value={perDay} onChange={(e) => setPerDay(e.target.value)} className="w-24" aria-invalid={!perDayOk} />
            </div>
          </div>
          <p className="text-xs text-text-muted" data-testid="spread-preview">
            {plan ? t("leads.noFollowup.preview", { count: leadIds.length, days: plan.days, perDay: Number(perDay), last: plan.lastDayCount }) : t("leads.noFollowup.perDayInvalid")}
          </p>
          <p className="text-[11px] text-text-muted">{t("leads.noFollowup.spreadRule")}</p>
        </section>
      ) : (
        <section>
          <NextFollowupPicker value={next} onChange={setNext} workDays={schedule.lead_work_days} workEnd={schedule.lead_work_end} keepNonWorking={keepNonWorking} onKeepNonWorking={setKeepNonWorking} />
        </section>
      )}

      <section className="space-y-2">
        <Label htmlFor="bulk-note">{t("leads.followup.setNote")}</Label>
        <Input id="bulk-note" value={note} maxLength={FOLLOWUP_NOTE_MAX} onChange={(e) => setNote(e.target.value)} placeholder={t("leads.followup.setNotePlaceholder")} />
      </section>

      {tooMany ? <p className="text-xs text-danger">{t("leads.noFollowup.tooMany", { max: BULK_MAX_LEADS })}</p> : null}

      <div className="flex justify-end gap-2">
        <Button variant="ghost" onClick={onClose} disabled={bulk.isPending}>
          {t("common.cancel")}
        </Button>
        <Button variant="accent" onClick={save} disabled={!canSave || bulk.isPending} data-testid="bulk-save">
          {bulk.isPending ? <Loader2 className="size-4 animate-spin" /> : t("leads.noFollowup.bulkSave", { count: leadIds.length })}
        </Button>
      </div>
    </div>
  )
}
