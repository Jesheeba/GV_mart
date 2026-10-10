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
import { postServiceOutcomesHooks } from "@/hooks/useMasters"
import { NextFollowupPicker } from "./NextFollowupPicker"
import { DEFAULT_LEAD_SCHEDULE } from "@/services/leadFollowups"
import type { PostServiceFollowupItem } from "@/services/postServiceFollowups"
import type { PostServiceOutcomeRow } from "@/services/masters"
import { defaultNextFor, formatIstDateTime, getIstNow, isNextFollowupValid, toIso, type NextFollowupValue } from "@/lib/lead-followups"
import { cn } from "@/lib/utils"

const chipBase = "rounded-full border px-3 py-1.5 text-xs font-semibold transition-colors"
const chipOn = "border-ink bg-ink text-white"
const chipOff = "border-border bg-surface text-text hover:bg-surface-alt"

/** Log the result of a post-service call: pick an outcome, write what was said; a "call later" outcome asks for the next date. */
export function PostServiceCallSheet({ item, open, onOpenChange }: { item: PostServiceFollowupItem | null; open: boolean; onOpenChange: (open: boolean) => void }) {
  const { t } = useTranslation()
  return (
    <Dialog open={open && !!item} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-lg gap-4">
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

function Body({ item, onClose }: { item: PostServiceFollowupItem; onClose: () => void }) {
  const { t, i18n } = useTranslation()
  const lang = i18n.language
  const { toast } = useToast()
  const { data: profile } = useProfile()
  const outcomes = postServiceOutcomesHooks.useList(profile?.org_id)
  const schedule = useLeadSchedule(profile?.org_id).data ?? DEFAULT_LEAD_SCHEDULE
  const logCall = useLogPostServiceCall()

  const [outcomeId, setOutcomeId] = useState<string | null>(null)
  const [note, setNote] = useState("")
  const [next, setNext] = useState<NextFollowupValue>(() => {
    const n = defaultNextFor({ followup_mode: "offset", default_offset_days: 1 }, getIstNow(), schedule.lead_work_days, schedule.lead_work_end)
    return { date: n.date, time: n.time, exact: false }
  })
  const [keepNonWorking, setKeepNonWorking] = useState<string | null>(null)

  const active = useMemo(() => (outcomes.data ?? []).filter((o) => o.is_active), [outcomes.data])
  const selected = active.find((o) => o.id === outcomeId) ?? null
  const label = (o: PostServiceOutcomeRow) => (lang.startsWith("ta") && o.label_ta ? o.label_ta : o.label_en)
  const canSave = !!selected && (!selected.retry || isNextFollowupValid(next))

  async function save() {
    if (!selected) return
    try {
      const res = await logCall.mutateAsync({
        followupId: item.followup_id,
        outcomeId: selected.id,
        note: note.trim() || null,
        nextDueAt: selected.retry ? toIso(next.date!, next.time!) : null,
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
            className="w-full rounded-xl border border-border bg-surface px-3 py-2 text-sm text-text outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"
          />
          {selected.alert ? <p className="rounded-xl bg-danger/10 px-3 py-2 text-xs text-text">{t("leads.postService.alertHint")}</p> : null}
        </section>
      ) : null}

      {selected?.retry ? (
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

      <div className="flex justify-end gap-2 pt-1">
        <Button variant="ghost" onClick={onClose} disabled={logCall.isPending}>
          {t("common.cancel")}
        </Button>
        <Button variant="accent" onClick={save} disabled={!canSave || logCall.isPending}>
          {logCall.isPending ? <Loader2 className="size-4 animate-spin" /> : t("common.save")}
        </Button>
      </div>
    </div>
  )
}
