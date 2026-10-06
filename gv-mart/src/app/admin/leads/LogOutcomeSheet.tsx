import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2, MessageCircle, Phone, Footprints } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useToast } from "@/components/ui/toast-context"
import { useProfile } from "@/hooks/useProfile"
import { useLeadOutcomes, useLeadSchedule, useLogLeadOutcome, useReopenLead } from "@/hooks/useLeadFollowups"
import { NextFollowupPicker } from "./NextFollowupPicker"
import { DEFAULT_LEAD_SCHEDULE, type FollowupType, type LeadOutcomeRow } from "@/services/leadFollowups"
import { defaultNextFor, formatIstDateTime, getIstNow, isNextFollowupValid, toIso, type NextFollowupValue } from "@/lib/lead-followups"
import { LOST_REASON_PRESETS, isLostReasonPreset, type LostReasonPreset } from "@/lib/lead-lost-reasons"
import { cn } from "@/lib/utils"
import type { Enums } from "@/types/database"

export type OutcomeSheetLead = { id: string; name: string; mobile: string | null; status: Enums<"lead_status"> }
type Channel = "call" | "whatsapp" | "visit"

const PHRASES = ["sendWhatsapp", "wantsDiscount", "comparing", "withFamily", "outOfStation", "budget"] as const
const FOLLOWUP_TYPES: FollowupType[] = ["call", "whatsapp", "visit", "send_quote"]
const CHANNEL_ICON = { call: Phone, whatsapp: MessageCircle, visit: Footprints } as const

const chipBase = "rounded-full border px-3 py-1.5 text-xs font-semibold transition-colors"
const chipOn = "border-ink bg-ink text-white"
const chipOff = "border-border bg-surface text-text hover:bg-surface-alt"

export function LogOutcomeSheet({
  lead,
  open,
  onOpenChange,
  defaultChannel = "call",
  onDone,
}: {
  lead: OutcomeSheetLead | null
  open: boolean
  onOpenChange: (open: boolean) => void
  defaultChannel?: Channel
  onDone?: () => void
}) {
  const { t } = useTranslation()
  const reopen = lead?.status === "won" || lead?.status === "lost"
  return (
    <Dialog open={open && !!lead} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-lg gap-4">
        <div>
          <DialogTitle>{reopen ? t("leads.outcomeSheet.reopenTitle") : t("leads.outcomeSheet.title")}</DialogTitle>
          <DialogDescription>
            {lead?.name}
            {lead?.mobile ? ` · ${lead.mobile}` : ""}
          </DialogDescription>
        </div>
        {lead ? (
          <SheetBody key={lead.id} lead={lead} reopen={!!reopen} defaultChannel={defaultChannel} onClose={() => onOpenChange(false)} onDone={onDone} />
        ) : null}
      </DialogContent>
    </Dialog>
  )
}

function SheetBody({
  lead,
  reopen,
  defaultChannel,
  onClose,
  onDone,
}: {
  lead: OutcomeSheetLead
  reopen: boolean
  defaultChannel: Channel
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

  const [outcomeId, setOutcomeId] = useState<string | null>(null)
  const [note, setNote] = useState("")
  const [reopenReason, setReopenReason] = useState("")
  const [channel, setChannel] = useState<Channel>(defaultChannel)
  const [next, setNext] = useState<NextFollowupValue>(() => {
    if (!reopen) return { date: null, time: null, exact: false }
    const n = defaultNextFor({ followup_mode: "offset", default_offset_days: 1 }, getIstNow(), schedule.lead_work_days, schedule.lead_work_end)
    return { date: n.date, time: n.time, exact: false }
  })
  const [keepNonWorking, setKeepNonWorking] = useState<string | null>(null)
  const [followupType, setFollowupType] = useState<FollowupType>("call")
  const [lostPreset, setLostPreset] = useState<LostReasonPreset | "">("")
  const [lostOther, setLostOther] = useState("")

  const active = useMemo(() => (outcomes.data ?? []).filter((o) => o.is_active), [outcomes.data])
  const selected = active.find((o) => o.id === outcomeId) ?? null
  const closing = selected?.stage_effect === "won" || selected?.stage_effect === "lost"
  const needsLostReason = selected?.stage_effect === "lost"
  const outcomeLabel = (o: LeadOutcomeRow) => (lang.startsWith("ta") && o.label_ta ? o.label_ta : o.label_en)
  const busy = logOutcome.isPending || reopenLead.isPending

  function chooseOutcome(o: LeadOutcomeRow) {
    setOutcomeId(o.id)
    setFollowupType(o.default_followup_type)
    const d = defaultNextFor(o, getIstNow(), schedule.lead_work_days, schedule.lead_work_end)
    setNext({ date: d.date, time: d.time, exact: d.exact })
    setKeepNonWorking(null)
    const hint = o.lost_reason_hint
    setLostPreset(o.stage_effect === "lost" && hint && isLostReasonPreset(hint) ? hint : "")
    setLostOther("")
  }

  const lostReasonValue = lostPreset === "other" ? lostOther.trim() : lostPreset
  const nextValid = isNextFollowupValid(next)
  const canSave = reopen
    ? nextValid && reopenReason.trim().length >= 3
    : !!selected && (closing ? (needsLostReason ? !!lostReasonValue : true) : !selected.requires_followup || nextValid)

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
      } else if (selected) {
        const withNext = !closing && selected.requires_followup
        const res = await logOutcome.mutateAsync({
          leadId: lead.id,
          outcomeId: selected.id,
          note: note.trim() || null,
          channel,
          nextDueAt: withNext ? toIso(next.date!, next.time!) : null,
          nextType: withNext ? followupType : null,
          nextIsExact: withNext ? next.exact : false,
          lostReason: needsLostReason ? lostReasonValue : null,
        })
        if (res.next_due_at) toast.success(t("leads.outcomeSheet.savedNext", { when: formatIstDateTime(res.next_due_at, lang) }))
        else toast.success(t(res.status === "won" ? "leads.outcomeSheet.savedWon" : "leads.outcomeSheet.savedLost"))
      }
      onClose()
      onDone?.()
    } catch (e) {
      toast.error(e instanceof Error && e.message ? e.message : t("common.actionFailed"))
    }
  }

  return (
    <div className="space-y-4">
      {!reopen ? (
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

      {selected || reopen ? (
        <section className="space-y-2">
          <div className="flex items-center justify-between gap-2">
            <Label htmlFor="outcome-note">{t("leads.outcomeSheet.step2")}</Label>
            {!reopen ? (
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
          <Input id="outcome-note" value={note} onChange={(e) => setNote(e.target.value)} placeholder={t("leads.outcomeSheet.notePlaceholder")} />
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
        </section>
      ) : null}

      {needsLostReason ? (
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

      {selected?.stage_effect === "won" ? <p className="rounded-xl bg-success/10 px-3 py-2 text-xs text-text">{t("leads.outcomeSheet.wonHint")}</p> : null}

      {(reopen || (selected && !closing && selected.requires_followup)) && (
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
