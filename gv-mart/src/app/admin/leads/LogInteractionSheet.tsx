import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { ChoiceSelect } from "@/components/shared/ChoiceSelect"
import { useToast } from "@/components/ui/toast-context"
import { useProfile } from "@/hooks/useProfile"
import { useAddLeadNote, useLeadOutcomes, useLeadSchedule, useLogLeadOutcome, useReopenLead, useRescheduleFollowup } from "@/hooks/useLeadFollowups"
import { NextFollowupPicker } from "./NextFollowupPicker"
import { DEFAULT_LEAD_SCHEDULE, type FollowupType, type LeadOutcomeRow } from "@/services/leadFollowups"
import { addDays, defaultNextFor, formatIstDateTime, getIstNow, isNextFollowupValid, nextWorkingDay, toIso, type NextFollowupValue } from "@/lib/lead-followups"
import { LOST_REASON_PRESETS, type LostReasonPreset } from "@/lib/lead-lost-reasons"
import { askFollowupQuestion, canSaveOutcome, missingOutcomeChoice, outcomePrefill, scheduleNext, type OutcomeChoice } from "@/lib/lead-outcome-followup"
import { cn, focusChoice } from "@/lib/utils"
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
const CHANNELS: Channel[] = ["call", "whatsapp", "visit"]
const RESCHEDULE_REASONS = ["customerAsked", "unreachable", "busy", "waitingStock"] as const
/** Inline message per required dropdown left on "Not set" (class C). */
const CHOICE_ERROR: Record<OutcomeChoice, string> = {
  outcome: "common.chooseOption",
  channel: "leads.outcomeSheet.channelRequired",
  lostReason: "common.chooseOption",
  followupNeeded: "common.chooseOption",
  nextType: "leads.outcomeSheet.nextTypeRequired",
}

const chipBase = "rounded-full border px-3 py-1.5 text-xs font-semibold transition-colors"
const chipOn = "border-ink bg-ink text-white"
const chipOff = "border-border bg-surface text-text hover:bg-surface-alt"

export function LogInteractionSheet({
  lead,
  open,
  onOpenChange,
  // Only a caller that knows the channel (e.g. returning from a phone call) passes one; otherwise it starts unchosen.
  defaultChannel,
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
  defaultChannel?: Channel
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
  const [channel, setChannel] = useState<Channel | null>(defaultChannel ?? null)
  // Which dropdown left on "Not set" blocked the last save (choice-dropdowns-not-set).
  const [choiceError, setChoiceError] = useState<OutcomeChoice | null>(null)

  // Mode "outcome"
  const [outcomeId, setOutcomeId] = useState<string | null>(null)
  const [next, setNext] = useState<NextFollowupValue>(() => {
    if (!reopen) return { date: null, time: null, exact: false }
    const n = defaultNextFor({ followup_mode: "offset", default_offset_days: 1 }, getIstNow(), schedule.lead_work_days, schedule.lead_work_end)
    return { date: n.date, time: n.time, exact: false }
  })
  const [keepNonWorking, setKeepNonWorking] = useState<string | null>(null)
  // Unchosen until picked — or set from the chosen outcome's configured default (chooseOutcome).
  const [followupType, setFollowupType] = useState<FollowupType | null>(null)
  const [lostPreset, setLostPreset] = useState<LostReasonPreset | "">("")
  const [lostOther, setLostOther] = useState("")
  // Unset (not "No") until an outcome pre-fills it or staff answer.
  const [needsFollowup, setNeedsFollowup] = useState<boolean | null>(null)

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

  function chooseOutcome(id: string) {
    const o = active.find((x) => x.id === id)
    setChoiceError(null)
    if (!o) return setOutcomeId(null)
    setOutcomeId(o.id)
    const prefill = outcomePrefill(o)
    setNeedsFollowup(prefill.needsFollowup)
    setFollowupType(prefill.followupType)
    const d = defaultNextFor(o, getIstNow(), schedule.lead_work_days, schedule.lead_work_end)
    setNext({ date: d.date, time: d.time, exact: d.exact })
    setKeepNonWorking(null)
    setLostPreset(prefill.lostPreset)
    setLostOther("")
  }

  /** Clears that field's "choose an option" error once it is changed. */
  function clearChoiceError(which: OutcomeChoice) {
    if (choiceError === which) setChoiceError(null)
  }

  function chooseFollowup(yes: boolean | null) {
    clearChoiceError("followupNeeded")
    setNeedsFollowup(yes)
    if (yes && !next.date) {
      const n = defaultNextFor({ followup_mode: "offset", default_offset_days: 1 }, getIstNow(), schedule.lead_work_days, schedule.lead_work_end)
      setNext({ date: n.date, time: n.time, exact: false })
      setKeepNonWorking(null)
    }
  }

  const lostReasonValue = lostPreset === "other" ? lostOther.trim() : lostPreset
  const missingChoice = missingOutcomeChoice({ selected, channel, lostPreset, needsFollowup, followupType })
  const nextValid = isNextFollowupValid(next)
  const rescheduleNextValid = isNextFollowupValid(rescheduleNext)

  const canSave = reopen
    ? nextValid && reopenReason.trim().length >= 3
    : mode === "outcome"
      ? missingChoice !== null || canSaveOutcome({ selected, needsLostReason, lostReasonValue, needsFollowup, nextValid })
      : mode === "reschedule"
        ? rescheduleReason.trim() !== "" && rescheduleNextValid
        : note.trim().length > 0

  // Reschedule always counts toward the stuck streak when pushed later (documented, unambiguous rule).
  // Outcome mode has no client-visible field for which outcomes count as a postpone server-side, so no
  // warning is shown there rather than guessing and risking a wrong one.
  const willStuck = !reopen && mode === "reschedule" && lead.postponeCount != null && lead.postponeCount + 1 >= schedule.lead_stuck_postpones

  function blockOnChoice(which: OutcomeChoice) {
    setChoiceError(which)
    focusChoice(`interaction-${which}`)
  }
  const choiceErrorFor = (which: OutcomeChoice) => (choiceError === which ? t(CHOICE_ERROR[which]) : undefined)

  async function save() {
    try {
      if (reopen) {
        if (!followupType) return blockOnChoice("nextType")
        const res = await reopenLead.mutateAsync({
          leadId: lead.id,
          nextDueAt: toIso(next.date!, next.time!),
          reason: reopenReason.trim(),
          type: followupType,
          note: note.trim() || null,
          isExact: next.exact,
        })
        toast.success(t("leads.outcomeSheet.reopened", { when: formatIstDateTime(res.next_due_at, lang) }))
      } else if (mode === "outcome") {
        if (missingChoice || !selected || !channel) return blockOnChoice(missingChoice ?? "outcome")
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
          <ChoiceSelect
            id="interaction-outcome"
            label={t("leads.outcomeSheet.step1")}
            value={outcomeId}
            options={active.map((o) => ({ value: o.id, label: outcomeLabel(o) }))}
            onChange={chooseOutcome}
            disabled={outcomes.isLoading}
            error={choiceErrorFor("outcome")}
          />
          {outcomes.isLoading ? <p className="text-xs text-text-muted">{t("common.loading")}</p> : null}
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
          {!reopen && mode === "outcome" ? (
            <ChoiceSelect
              id="interaction-channel"
              label={t("leads.outcomeSheet.how")}
              value={channel}
              options={CHANNELS.map((c) => ({ value: c, label: t(`leads.followup.type.${c}`) }))}
              onChange={(v) => {
                setChannel(v || null)
                clearChoiceError("channel")
              }}
              error={choiceErrorFor("channel")}
            />
          ) : null}
          <Label htmlFor="interaction-note">{mode === "note" ? t("leads.detail.notePlaceholder") : t("leads.outcomeSheet.step2")}</Label>
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
          <ChoiceSelect
            id="interaction-lostReason"
            label={t("leads.detail.lostReasonLabel")}
            value={lostPreset}
            options={LOST_REASON_PRESETS.map((r) => ({ value: r, label: t(`leads.lostReason.${r}`) }))}
            onChange={(v) => {
              setLostPreset(v)
              clearChoiceError("lostReason")
            }}
            error={choiceErrorFor("lostReason")}
          />
          {lostPreset === "other" ? <Input autoFocus placeholder={t("leads.detail.lostReasonOtherPlaceholder")} value={lostOther} onChange={(e) => setLostOther(e.target.value)} /> : null}
        </section>
      ) : null}

      {mode === "outcome" && selected?.stage_effect === "won" ? <p className="rounded-xl bg-success/10 px-3 py-2 text-xs text-text">{t("leads.outcomeSheet.wonHint")}</p> : null}

      {!reopen && mode === "outcome" && askFollowupQuestion(selected) ? (
        <section className="space-y-2">
          <ChoiceSelect
            id="interaction-followupNeeded"
            label={t("leads.outcomeSheet.followupNeeded")}
            value={needsFollowup === null ? "" : needsFollowup ? "yes" : "no"}
            options={[
              { value: "yes", label: t("leads.outcomeSheet.yes") },
              { value: "no", label: t("leads.outcomeSheet.no") },
            ]}
            onChange={(v) => chooseFollowup(v === "" ? null : v === "yes")}
            error={choiceErrorFor("followupNeeded")}
          />
          {needsFollowup === false ? <p className="text-xs text-text-muted">{t("leads.outcomeSheet.noFollowupHint")}</p> : null}
        </section>
      ) : null}

      {(reopen || (mode === "outcome" && askFollowupQuestion(selected) && needsFollowup)) && (
        <section className="space-y-2">
          <Label>{t("leads.outcomeSheet.step3")}</Label>
          <ChoiceSelect
            id="interaction-nextType"
            label={t("leads.outcomeSheet.nextType")}
            value={followupType}
            options={FOLLOWUP_TYPES.map((ty) => ({ value: ty, label: t(`leads.followup.type.${ty}`) }))}
            onChange={(v) => {
              setFollowupType(v || null)
              clearChoiceError("nextType")
            }}
            error={choiceErrorFor("nextType")}
          />
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
