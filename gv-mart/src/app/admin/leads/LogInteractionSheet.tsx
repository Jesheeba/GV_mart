import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2, MessageCircle, Phone, Footprints } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useToast } from "@/components/ui/toast-context"
import { useProfile } from "@/hooks/useProfile"
import { useAddLeadNote, useLeadOutcomes, useLeadSchedule, useLogLeadOutcome, useReopenLead, useRescheduleFollowup } from "@/hooks/useLeadFollowups"
import { NextFollowupPicker } from "./NextFollowupPicker"
import { DEFAULT_LEAD_SCHEDULE, type FollowupType, type LeadOutcomeRow } from "@/services/leadFollowups"
import { addDays, defaultNextFor, formatIstDateTime, getIstNow, isNextFollowupValid, nextWorkingDay, toIso, type NextFollowupValue } from "@/lib/lead-followups"
import { LOST_REASON_PRESETS, isLostReasonPreset, type LostReasonPreset } from "@/lib/lead-lost-reasons"
import { askFollowupQuestion, canSaveOutcome, defaultFollowupNeeded, scheduleNext } from "@/lib/lead-outcome-followup"
import { cn } from "@/lib/utils"
import type { Enums } from "@/types/database"

/** A lead as the sheet needs it. `postponeCount` is optional — omit it where it isn't already loaded
 *  (e.g. the call-return prompt); the stuck-threshold warning simply won't show. */
export type InteractionLead = {
  id: string
  name: string
  mobile: string | null
  status: Enums<"lead_status">
  postponeCount?: number | null
}
type Channel = "call" | "whatsapp" | "visit"
/** "outcome" = reached the customer, "reschedule" = didn't reach them / pushing it, "note" = just a note, nothing changes. */
type Mode = "outcome" | "reschedule" | "note"

const PHRASES = ["sendWhatsapp", "wantsDiscount", "comparing", "withFamily", "outOfStation", "budget"] as const
const FOLLOWUP_TYPES: FollowupType[] = ["call", "whatsapp", "visit", "send_quote"]
const CHANNEL_ICON = { call: Phone, whatsapp: MessageCircle, visit: Footprints } as const
const RESCHEDULE_REASONS = ["customerAsked", "unreachable", "busy", "waitingStock"] as const

const chipBase = "rounded-full border px-3 py-1.5 text-xs font-semibold transition-colors"
const chipOn = "border-ink bg-ink text-white"
const chipOff = "border-border bg-surface text-text hover:bg-surface-alt"

export function LogInteractionSheet({
  lead,
  open,
  onOpenChange,
  defaultChannel = "call",
  defaultMode = "outcome",
  onDone,
}: {
  lead: InteractionLead | null
  open: boolean
  onOpenChange: (open: boolean) => void
  defaultChannel?: Channel
  defaultMode?: Mode
  onDone?: () => void
}) {
  const reopen = lead?.status === "won" || lead?.status === "lost"
  return (
    <Dialog open={open && !!lead} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-lg gap-4">
        {lead ? (
          <SheetBody
            key={lead.id}
            lead={lead}
            reopen={!!reopen}
            defaultChannel={defaultChannel}
            defaultMode={defaultMode}
            onClose={() => onOpenChange(false)}
            onDone={onDone}
          />
        ) : null}
      </DialogContent>
    </Dialog>
  )
}

function SheetBody({
  lead,
  reopen,
  defaultChannel,
  defaultMode,
  onClose,
  onDone,
}: {
  lead: InteractionLead
  reopen: boolean
  defaultChannel: Channel
  defaultMode: Mode
  onClose: () => void
  onDone?: () => void
}) {
  const { t, i18n } = useTranslation()
  const lang = i18n.language
  const { toast } = useToast()
  const { data: profile } = useProfile()
  const outcomes = useLeadOutcomes(profile?.org_id)
  const schedule = useLeadSchedule(profile?.org_id).data ?? DEFAULT_LEAD_SCHEDULE
  const logOutcome = useLogLeadOutcome()
  const reopenLead = useReopenLead()
  const reschedule = useRescheduleFollowup()
  const addNote = useAddLeadNote()

  const [mode, setMode] = useState<Mode>(defaultMode)
  // Shared across modes so switching never loses what was typed.
  const [note, setNote] = useState("")
  const [reopenReason, setReopenReason] = useState("")
  const [channel, setChannel] = useState<Channel>(defaultChannel)

  // Mode "outcome"
  const [outcomeId, setOutcomeId] = useState<string | null>(null)
  const [next, setNext] = useState<NextFollowupValue>(() => {
    if (!reopen) return { date: null, time: null, exact: false }
    const n = defaultNextFor({ followup_mode: "offset", default_offset_days: 1 }, getIstNow(), schedule.lead_work_days, schedule.lead_work_end)
    return { date: n.date, time: n.time, exact: false }
  })
  const [keepNonWorking, setKeepNonWorking] = useState<string | null>(null)
  const [followupType, setFollowupType] = useState<FollowupType>("call")
  const [lostPreset, setLostPreset] = useState<LostReasonPreset | "">("")
  const [lostOther, setLostOther] = useState("")
  const [needsFollowup, setNeedsFollowup] = useState(false)

  // Mode "reschedule"
  const [rescheduleReason, setRescheduleReason] = useState("")
  const [rescheduleNext, setRescheduleNext] = useState<NextFollowupValue>(() => {
    const now = getIstNow()
    return { date: nextWorkingDay(addDays(now.date, 0), schedule.lead_work_days), time: "10:00", exact: false }
  })
  const [rescheduleKeepNonWorking, setRescheduleKeepNonWorking] = useState<string | null>(null)

  const active = useMemo(() => (outcomes.data ?? []).filter((o) => o.is_active), [outcomes.data])
  const selected = active.find((o) => o.id === outcomeId) ?? null
  const needsLostReason = selected?.stage_effect === "lost"
  const outcomeLabel = (o: LeadOutcomeRow) => (lang.startsWith("ta") && o.label_ta ? o.label_ta : o.label_en)
  const busy = logOutcome.isPending || reopenLead.isPending || reschedule.isPending || addNote.isPending

  function chooseOutcome(o: LeadOutcomeRow) {
    setOutcomeId(o.id)
    setNeedsFollowup(defaultFollowupNeeded(o))
    setFollowupType(o.default_followup_type)
    const d = defaultNextFor(o, getIstNow(), schedule.lead_work_days, schedule.lead_work_end)
    setNext({ date: d.date, time: d.time, exact: d.exact })
    setKeepNonWorking(null)
    const hint = o.lost_reason_hint
    setLostPreset(o.stage_effect === "lost" && hint && isLostReasonPreset(hint) ? hint : "")
    setLostOther("")
  }

  function chooseFollowup(yes: boolean) {
    setNeedsFollowup(yes)
    if (yes && !next.date) {
      const n = defaultNextFor({ followup_mode: "offset", default_offset_days: 1 }, getIstNow(), schedule.lead_work_days, schedule.lead_work_end)
      setNext({ date: n.date, time: n.time, exact: false })
      setKeepNonWorking(null)
    }
  }

  const lostReasonValue = lostPreset === "other" ? lostOther.trim() : lostPreset
  const nextValid = isNextFollowupValid(next)
  const rescheduleNextValid = isNextFollowupValid(rescheduleNext)

  const canSave = reopen
    ? nextValid && reopenReason.trim().length >= 3
    : mode === "outcome"
      ? canSaveOutcome({ selected, needsLostReason, lostReasonValue, needsFollowup, nextValid })
      : mode === "reschedule"
        ? rescheduleReason.trim() !== "" && rescheduleNextValid
        : note.trim().length > 0

  // Reschedule always counts toward the stuck streak when pushed later (documented, unambiguous rule).
  // Outcome mode has no client-visible field for which outcomes count as a postpone server-side, so no
  // warning is shown there rather than guessing and risking a wrong one.
  const willStuck = !reopen && mode === "reschedule" && lead.postponeCount != null && lead.postponeCount + 1 >= schedule.lead_stuck_postpones

  async function save() {
    try {
      if (reopen) {
        const res = await reopenLead.mutateAsync({
          leadId: lead.id,
          nextDueAt: toIso(next.date!, next.time!),
          reason: reopenReason.trim(),
          type: followupType,
          note: note.trim() || null,
          isExact: next.exact,
        })
        toast.success(t("leads.outcomeSheet.reopened", { when: formatIstDateTime(res.next_due_at, lang) }))
      } else if (mode === "outcome" && selected) {
        const withNext = scheduleNext(selected, needsFollowup)
        const res = await logOutcome.mutateAsync({
          leadId: lead.id,
          outcomeId: selected.id,
          note: note.trim() || null,
          channel,
          nextDueAt: withNext ? toIso(next.date!, next.time!) : null,
          nextType: withNext ? followupType : null,
          nextIsExact: withNext ? next.exact : false,
          lostReason: needsLostReason ? lostReasonValue : null,
          followupNeeded: askFollowupQuestion(selected) ? needsFollowup : null,
        })
        if (res.next_due_at) toast.success(t("leads.outcomeSheet.savedNext", { when: formatIstDateTime(res.next_due_at, lang) }))
        else if (res.status === "won" || res.status === "lost")
          toast.success(t(res.status === "won" ? "leads.outcomeSheet.savedWon" : "leads.outcomeSheet.savedLost"))
        else toast.success(t("leads.outcomeSheet.savedNoFollowup"))
      } else if (mode === "reschedule") {
        const res = await reschedule.mutateAsync({
          leadId: lead.id,
          newDueAt: toIso(rescheduleNext.date!, rescheduleNext.time!),
          reason: rescheduleReason.trim(),
          note: note.trim() || null,
          isExact: rescheduleNext.exact,
        })
        toast.success(t("leads.reschedule.saved", { when: formatIstDateTime(res.next_due_at, lang) }))
      } else {
        await addNote.mutateAsync({ leadId: lead.id, note: note.trim() })
        toast.success(t("leads.detail.noteSaved"))
      }
      onClose()
      onDone?.()
    } catch (e) {
      toast.error(e instanceof Error && e.message ? e.message : t("common.actionFailed"))
    }
  }

  const title = reopen
    ? t("leads.outcomeSheet.reopenTitle")
    : mode === "outcome"
      ? t("leads.outcomeSheet.title")
      : mode === "reschedule"
        ? t("leads.reschedule.title")
        : t("leads.detail.addNote")

  return (
    <div className="space-y-4">
      <div>
        <DialogTitle>{title}</DialogTitle>
        <DialogDescription>
          {lead.name}
          {lead.mobile ? ` · ${lead.mobile}` : ""}
        </DialogDescription>
      </div>

      {!reopen ? (
        <div className="flex gap-1.5" role="radiogroup" aria-label={t("leads.interaction.title")}>
          {(["outcome", "reschedule", "note"] as const).map((m) => (
            <button
              key={m}
              type="button"
              role="radio"
              aria-checked={mode === m}
              onClick={() => setMode(m)}
              className={cn(chipBase, mode === m ? chipOn : chipOff)}
            >
              {t(`leads.interaction.mode.${m}`)}
            </button>
          ))}
        </div>
      ) : null}

      {!reopen && mode === "outcome" ? (
        <section className="space-y-2">
          <Label>{t("leads.outcomeSheet.step1")}</Label>
          {outcomes.isLoading ? (
            <p className="text-xs text-text-muted">{t("common.loading")}</p>
          ) : (
            <div className="flex flex-wrap gap-1.5">
              {active.map((o) => (
                <button
                  key={o.id}
                  type="button"
                  onClick={() => chooseOutcome(o)}
                  aria-pressed={outcomeId === o.id}
                  className={cn(chipBase, outcomeId === o.id ? chipOn : chipOff, o.stage_effect === "lost" && outcomeId !== o.id && "border-danger/30")}
                >
                  {outcomeLabel(o)}
                </button>
              ))}
            </div>
          )}
        </section>
      ) : null}

      {reopen ? (
        <section className="space-y-2">
          <Label htmlFor="reopen-reason">{t("leads.outcomeSheet.reopenReason")}</Label>
          <Input id="reopen-reason" autoFocus value={reopenReason} onChange={(e) => setReopenReason(e.target.value)} placeholder={t("leads.outcomeSheet.reopenReasonPlaceholder")} />
        </section>
      ) : null}

      {!reopen && mode === "reschedule" ? (
        <section className="space-y-2">
          <Label htmlFor="reschedule-reason">{t("leads.reschedule.reason")}</Label>
          <Input id="reschedule-reason" value={rescheduleReason} onChange={(e) => setRescheduleReason(e.target.value)} placeholder={t("leads.reschedule.reasonPlaceholder")} />
          <div className="flex flex-wrap gap-1.5">
            {RESCHEDULE_REASONS.map((r) => {
              const text = t(`leads.reschedule.reasons.${r}`)
              return (
                <button
                  key={r}
                  type="button"
                  onClick={() => setRescheduleReason(text)}
                  className={cn("rounded-full px-2.5 py-1 text-[11px] font-medium", rescheduleReason === text ? "bg-ink text-white" : "bg-surface-alt text-text-muted hover:text-text")}
                >
                  {text}
                </button>
              )
            })}
          </div>
        </section>
      ) : null}

      {selected || reopen || mode === "note" || mode === "reschedule" ? (
        <section className="space-y-2">
          <div className="flex items-center justify-between gap-2">
            <Label htmlFor="interaction-note">{mode === "note" ? t("leads.detail.notePlaceholder") : t("leads.outcomeSheet.step2")}</Label>
            {!reopen && mode === "outcome" ? (
              <div className="flex gap-1" role="group" aria-label={t("leads.outcomeSheet.how")}>
                {(["call", "whatsapp", "visit"] as const).map((c) => {
                  const Icon = CHANNEL_ICON[c]
                  return (
                    <button
                      key={c}
                      type="button"
                      onClick={() => setChannel(c)}
                      aria-pressed={channel === c}
                      title={t(`leads.followup.type.${c}`)}
                      className={cn("flex items-center gap-1 rounded-full border px-2.5 py-1 text-[11px] font-semibold", channel === c ? chipOn : chipOff)}
                    >
                      <Icon className="size-3" />
                      {t(`leads.followup.type.${c}`)}
                    </button>
                  )
                })}
              </div>
            ) : null}
          </div>
          <textarea
            id="interaction-note"
            rows={4}
            maxLength={2000}
            value={note}
            onChange={(e) => setNote(e.target.value)}
            placeholder={t("leads.outcomeSheet.notePlaceholder")}
            className="w-full rounded-xl border border-border bg-surface px-3 py-2 text-sm text-text outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"
          />
          {mode === "outcome" ? (
            <div className="flex flex-wrap gap-1.5">
              {PHRASES.map((p) => (
                <button
                  key={p}
                  type="button"
                  onClick={() => setNote((n) => (n ? `${n.replace(/[.\s]+$/, "")}. ${t(`leads.outcomeSheet.phrases.${p}`)}` : t(`leads.outcomeSheet.phrases.${p}`)))}
                  className="rounded-full bg-surface-alt px-2.5 py-1 text-[11px] font-medium text-text-muted hover:text-text"
                >
                  + {t(`leads.outcomeSheet.phrases.${p}`)}
                </button>
              ))}
            </div>
          ) : null}
        </section>
      ) : null}

      {needsLostReason && mode === "outcome" ? (
        <section className="space-y-2">
          <Label>{t("leads.detail.lostReasonLabel")}</Label>
          <div className="flex flex-wrap gap-1.5">
            {LOST_REASON_PRESETS.map((r) => (
              <button key={r} type="button" onClick={() => setLostPreset(r)} aria-pressed={lostPreset === r} className={cn(chipBase, lostPreset === r ? chipOn : chipOff)}>
                {t(`leads.lostReason.${r}`)}
              </button>
            ))}
          </div>
          {lostPreset === "other" ? <Input autoFocus placeholder={t("leads.detail.lostReasonOtherPlaceholder")} value={lostOther} onChange={(e) => setLostOther(e.target.value)} /> : null}
        </section>
      ) : null}

      {mode === "outcome" && selected?.stage_effect === "won" ? <p className="rounded-xl bg-success/10 px-3 py-2 text-xs text-text">{t("leads.outcomeSheet.wonHint")}</p> : null}

      {!reopen && mode === "outcome" && askFollowupQuestion(selected) ? (
        <section className="space-y-2">
          <Label id="followup-needed-label">{t("leads.outcomeSheet.followupNeeded")}</Label>
          <div className="flex gap-1.5" role="radiogroup" aria-labelledby="followup-needed-label">
            {([true, false] as const).map((yes) => (
              <button
                key={String(yes)}
                type="button"
                role="radio"
                aria-checked={needsFollowup === yes}
                onClick={() => chooseFollowup(yes)}
                className={cn(chipBase, needsFollowup === yes ? chipOn : chipOff)}
              >
                {t(yes ? "leads.outcomeSheet.yes" : "leads.outcomeSheet.no")}
              </button>
            ))}
          </div>
          {!needsFollowup ? <p className="text-xs text-text-muted">{t("leads.outcomeSheet.noFollowupHint")}</p> : null}
        </section>
      ) : null}

      {(reopen || (mode === "outcome" && askFollowupQuestion(selected) && needsFollowup)) && (
        <section className="space-y-2">
          <div className="flex items-center justify-between gap-2">
            <Label>{t("leads.outcomeSheet.step3")}</Label>
            <div className="flex gap-1" role="group" aria-label={t("leads.outcomeSheet.nextType")}>
              {FOLLOWUP_TYPES.map((ty) => (
                <button
                  key={ty}
                  type="button"
                  onClick={() => setFollowupType(ty)}
                  aria-pressed={followupType === ty}
                  className={cn("rounded-full border px-2.5 py-1 text-[11px] font-semibold", followupType === ty ? chipOn : chipOff)}
                >
                  {t(`leads.followup.type.${ty}`)}
                </button>
              ))}
            </div>
          </div>
          <NextFollowupPicker
            value={next}
            onChange={setNext}
            workDays={schedule.lead_work_days}
            workEnd={schedule.lead_work_end}
            keepNonWorking={keepNonWorking}
            onKeepNonWorking={setKeepNonWorking}
          />
        </section>
      )}

      {!reopen && mode === "reschedule" ? (
        <section className="space-y-2">
          <Label>{t("leads.reschedule.newTime")}</Label>
          <NextFollowupPicker
            value={rescheduleNext}
            onChange={setRescheduleNext}
            workDays={schedule.lead_work_days}
            workEnd={schedule.lead_work_end}
            keepNonWorking={rescheduleKeepNonWorking}
            onKeepNonWorking={setRescheduleKeepNonWorking}
          />
          <p className="text-xs text-text-muted">{t("leads.reschedule.hint")}</p>
        </section>
      ) : null}

      {willStuck ? <p className="rounded-xl bg-warning/10 px-3 py-2 text-xs font-medium text-text">{t("leads.interaction.stuckWarning")}</p> : null}

      <div className="flex justify-end gap-2 pt-1">
        <Button variant="ghost" onClick={onClose} disabled={busy}>
          {t("common.cancel")}
        </Button>
        <Button variant="accent" onClick={save} disabled={!canSave || busy}>
          {busy ? <Loader2 className="size-4 animate-spin" /> : reopen ? t("leads.outcomeSheet.reopenSave") : t("common.save")}
        </Button>
      </div>
    </div>
  )
}
