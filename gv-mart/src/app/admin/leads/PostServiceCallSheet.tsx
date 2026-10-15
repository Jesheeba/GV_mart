import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import { Label } from "@/components/ui/label"
import { useToast } from "@/components/ui/toast-context"
import { useProfile } from "@/hooks/useProfile"
import { useLeadSchedule } from "@/hooks/useLeadFollowups"
import { useLogPostServiceCall } from "@/hooks/usePostServiceFollowups"
import { usePostServiceQuestions } from "@/hooks/useFollowupQuestions"
import { postServiceOutcomesHooks } from "@/hooks/useMasters"
import { NextFollowupPicker } from "./NextFollowupPicker"
import { DEFAULT_LEAD_SCHEDULE } from "@/services/leadFollowups"
import type { PostServiceFollowupItem } from "@/services/postServiceFollowups"
import type { PostServiceOutcomeRow } from "@/services/masters"
import { defaultNextFor, formatIstDateTime, getIstNow, isNextFollowupValid, toIso, type NextFollowupValue } from "@/lib/lead-followups"
import {
  RATING_VALUES,
  buildAnswersPayload,
  choiceLabel,
  missingRequired,
  outcomeSkipsRequiredAnswers,
  parseChoices,
  pickText,
  type AnswerMap,
  type AnswerValue,
  type FollowupQuestion,
} from "@/lib/followup-questions"
import { cn } from "@/lib/utils"

const chipBase = "min-h-11 rounded-full border px-3.5 py-2 text-xs font-semibold transition-colors"
const chipOn = "border-ink bg-ink text-white"
const chipOff = "border-border bg-surface text-text hover:bg-surface-alt"

/** Log the result of a post-service call: pick an outcome, answer the master's questions, write what was said; a "call later" outcome (or "follow-up needed") asks for the next date. */
export function PostServiceCallSheet({ item, open, onOpenChange }: { item: PostServiceFollowupItem | null; open: boolean; onOpenChange: (open: boolean) => void }) {
  const { t } = useTranslation()
  return (
    <Dialog open={open && !!item} onOpenChange={onOpenChange}>
      {/* Scrolls on a small screen / in the Capacitor webview: capped to the dynamic viewport height, buttons stay reachable. */}
      <DialogContent className="max-h-[calc(100dvh-1.5rem)] max-w-lg gap-4 overflow-y-auto overscroll-contain">
        <div>
          <DialogTitle>{t("leads.postService.sheetTitle")}</DialogTitle>
          <DialogDescription>
            {item?.customer_name}
            {item?.mobile ? ` · ${item.mobile}` : ""}
            {item?.complaint ? ` · ${item.complaint}` : ""}
          </DialogDescription>
        </div>
        {item ? <Body key={item.followup_id} item={item} onClose={() => onOpenChange(false)} /> : null}
      </DialogContent>
    </Dialog>
  )
}

function YesNoChips({ value, onChange, name }: { value: AnswerValue; onChange: (v: AnswerValue) => void; name: string }) {
  const { t } = useTranslation()
  return (
    <div className="flex gap-2" role="group" aria-label={name}>
      {[true, false].map((v) => (
        <button key={String(v)} type="button" aria-pressed={value === v} onClick={() => onChange(value === v ? null : v)} className={cn(chipBase, "min-w-20", value === v ? chipOn : chipOff)}>
          {v ? t("common.yes") : t("common.no")}
        </button>
      ))}
    </div>
  )
}

function QuestionInput({ q, value, onChange, lang }: { q: FollowupQuestion; value: AnswerValue; onChange: (v: AnswerValue) => void; lang: string }) {
  const { t } = useTranslation()
  const text = pickText(q.text_en, q.text_ta, lang)
  if (q.answer_type === "yes_no") return <YesNoChips value={value} onChange={onChange} name={text} />
  if (q.answer_type === "rating") {
    return (
      <div className="flex gap-2" role="group" aria-label={text}>
        {RATING_VALUES.map((n) => (
          <button key={n} type="button" aria-pressed={value === n} onClick={() => onChange(value === n ? null : n)} className={cn(chipBase, "size-11 px-0", value === n ? chipOn : chipOff)}>
            {n}
          </button>
        ))}
      </div>
    )
  }
  if (q.answer_type === "choice") {
    return (
      <div className="flex flex-wrap gap-2" role="group" aria-label={text}>
        {parseChoices(q.choices).map((c) => (
          <button key={c.value} type="button" aria-pressed={value === c.value} onClick={() => onChange(value === c.value ? null : c.value)} className={cn(chipBase, value === c.value ? chipOn : chipOff)}>
            {choiceLabel(c, lang)}
          </button>
        ))}
      </div>
    )
  }
  return (
    <textarea
      rows={2}
      maxLength={2000}
      aria-label={text}
      value={typeof value === "string" ? value : ""}
      onChange={(e) => onChange(e.target.value)}
      placeholder={t("leads.postService.answerPlaceholder")}
      className="w-full rounded-xl border border-border bg-surface px-3 py-2 text-base text-text outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"
    />
  )
}

function Body({ item, onClose }: { item: PostServiceFollowupItem; onClose: () => void }) {
  const { t, i18n } = useTranslation()
  const lang = i18n.language
  const { toast } = useToast()
  const { data: profile } = useProfile()
  const outcomes = postServiceOutcomesHooks.useList(profile?.org_id)
  const questions = usePostServiceQuestions(item.followup_id)
  const schedule = useLeadSchedule(profile?.org_id).data ?? DEFAULT_LEAD_SCHEDULE
  const logCall = useLogPostServiceCall()

  const [outcomeId, setOutcomeId] = useState<string | null>(null)
  const [note, setNote] = useState("")
  const [answers, setAnswers] = useState<AnswerMap>({})
  const [followupNeeded, setFollowupNeeded] = useState<boolean | null>(null)
  const [next, setNext] = useState<NextFollowupValue>(() => {
    const n = defaultNextFor({ followup_mode: "offset", default_offset_days: 1 }, getIstNow(), schedule.lead_work_days, schedule.lead_work_end)
    return { date: n.date, time: n.time, exact: false }
  })
  const [keepNonWorking, setKeepNonWorking] = useState<string | null>(null)

  const active = useMemo(() => (outcomes.data ?? []).filter((o) => o.is_active), [outcomes.data])
  const selected = active.find((o) => o.id === outcomeId) ?? null
  const label = (o: PostServiceOutcomeRow) => (lang.startsWith("ta") && o.label_ta ? o.label_ta : o.label_en)

  const qs = questions.data ?? []
  const skipRequired = outcomeSkipsRequiredAnswers(selected)
  const missing = skipRequired ? [] : missingRequired(qs, answers)
  // A retry outcome always reschedules; for any other outcome the "follow-up needed" answer decides.
  const needsDate = !!selected && (selected.retry || followupNeeded === true)
  const canSave = !!selected && !questions.isLoading && !questions.isError && missing.length === 0 && (!needsDate || isNextFollowupValid(next))

  async function save() {
    if (!selected) return
    try {
      const res = await logCall.mutateAsync({
        followupId: item.followup_id,
        outcomeId: selected.id,
        note: note.trim() || null,
        nextDueAt: needsDate ? toIso(next.date!, next.time!) : null,
        answers: buildAnswersPayload(qs, answers),
        followupNeeded: selected.retry ? null : followupNeeded,
      })
      if (res.status === "open" && res.next_due_at) toast.success(t("leads.postService.savedRetry", { when: formatIstDateTime(res.next_due_at, lang) }))
      else toast.success(t(res.alerted ? "leads.postService.savedAlert" : "leads.postService.saved"))
      onClose()
    } catch (e) {
      toast.error(e instanceof Error && e.message ? e.message : t("common.actionFailed"))
    }
  }

  return (
    <div className="space-y-4">
      <section className="space-y-2">
        <Label>{t("leads.postService.whatHappened")}</Label>
        {outcomes.isLoading ? (
          <p className="text-xs text-text-muted">{t("common.loading")}</p>
        ) : (
          <div className="flex flex-wrap gap-1.5">
            {active.map((o) => (
              <button
                key={o.id}
                type="button"
                onClick={() => setOutcomeId(o.id)}
                aria-pressed={outcomeId === o.id}
                className={cn(chipBase, outcomeId === o.id ? chipOn : chipOff, o.alert && outcomeId !== o.id && "border-danger/30")}
              >
                {label(o)}
              </button>
            ))}
          </div>
        )}
      </section>

      {selected && qs.length > 0 ? (
        <section className="space-y-3" data-testid="post-service-questions">
          <div>
            <Label>{t("leads.postService.questionsTitle")}</Label>
            {skipRequired ? <p className="text-xs text-text-muted">{t("leads.postService.questionsOptional")}</p> : null}
          </div>
          {qs.map((q) => (
            <div key={q.id} className="space-y-1.5">
              <p className="text-sm font-medium text-text">
                {pickText(q.text_en, q.text_ta, lang)}
                {q.is_required && !skipRequired ? <span className="text-danger"> *</span> : null}
              </p>
              <QuestionInput q={q} value={answers[q.id] ?? null} onChange={(v) => setAnswers((cur) => ({ ...cur, [q.id]: v }))} lang={lang} />
            </div>
          ))}
          {missing.length > 0 ? <p className="text-xs text-danger">{t("leads.postService.requiredMissing", { count: missing.length })}</p> : null}
        </section>
      ) : null}
      {selected && questions.isError ? <p className="rounded-xl bg-danger/10 px-3 py-2 text-xs text-text">{t("leads.postService.questionsFailed")}</p> : null}

      {selected ? (
        <section className="space-y-2">
          <Label htmlFor="ps-note">{t("leads.postService.note")}</Label>
          <textarea
            id="ps-note"
            rows={4}
            maxLength={2000}
            value={note}
            onChange={(e) => setNote(e.target.value)}
            placeholder={t("leads.postService.notePlaceholder")}
            className="w-full rounded-xl border border-border bg-surface px-3 py-2 text-base text-text outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"
          />
          {selected.alert ? <p className="rounded-xl bg-danger/10 px-3 py-2 text-xs text-text">{t("leads.postService.alertHint")}</p> : null}
        </section>
      ) : null}

      {selected && !selected.retry ? (
        <section className="space-y-2">
          <Label>{t("leads.postService.followupNeeded")}</Label>
          <YesNoChips value={followupNeeded} onChange={(v) => setFollowupNeeded(v as boolean | null)} name={t("leads.postService.followupNeeded")} />
          <p className="text-xs text-text-muted">{t("leads.postService.followupNeededHint")}</p>
        </section>
      ) : null}

      {needsDate ? (
        <section className="space-y-2">
          <Label>{t("leads.postService.callAgain")}</Label>
          <NextFollowupPicker
            value={next}
            onChange={setNext}
            workDays={schedule.lead_work_days}
            workEnd={schedule.lead_work_end}
            keepNonWorking={keepNonWorking}
            onKeepNonWorking={setKeepNonWorking}
          />
        </section>
      ) : null}

      {/* Buttons stay visible at the bottom while the sheet scrolls (6 questions on a small screen). */}
      <div className="sticky bottom-0 -mx-1 flex justify-end gap-2 bg-surface px-1 pb-1 pt-2">
        <Button variant="ghost" className="h-11 px-4" onClick={onClose} disabled={logCall.isPending}>
          {t("common.cancel")}
        </Button>
        <Button variant="accent" className="h-11 px-5" onClick={save} disabled={!canSave || logCall.isPending}>
          {logCall.isPending ? <Loader2 className="size-4 animate-spin" /> : t("common.save")}
        </Button>
      </div>
    </div>
  )
}
