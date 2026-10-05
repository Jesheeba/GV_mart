import { useEffect, useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useToast } from "@/components/ui/toast-context"
import { EntityCrudTable, type CrudFieldDef } from "@/components/shared/EntityCrudTable"
import { StatusDot } from "@/components/shared/StatusDot"
import { useProfile } from "@/hooks/useProfile"
import { useCreateLeadOutcome, useLeadOutcomes, useLeadSchedule, useUpdateLeadOutcome, useUpdateLeadSchedule } from "@/hooks/useLeadFollowups"
import { leadSourceKeyFromLabel } from "@/lib/lead-sources"
import { LOST_REASON_PRESETS } from "@/lib/lead-lost-reasons"
import type { LeadOutcomeRow } from "@/services/leadFollowups"
import { DEFAULT_LEAD_SCHEDULE } from "@/services/leadFollowups"
import type { Enums } from "@/types/database"

const MODES = ["offset", "ask_date", "exact_time", "none"] as const
const STAGES = ["", "contacted", "quoted", "won", "lost"] as const
const FOLLOWUP_TYPES: Enums<"lead_followup_type">[] = ["call", "whatsapp", "visit", "send_quote"]
const DAY_KEYS = [1, 2, 3, 4, 5, 6, 7] as const

/**
 * Masters > Lead Outcomes: the call outcomes staff pick in the Log Outcome
 * sheet (each with a default next follow-up rule and optional stage effect),
 * plus the working schedule (days/hours in IST) that drives working-day
 * suggestions, the daily digest and the "stuck" threshold. Outcomes are never
 * deleted — set Status to Inactive to retire one without breaking history.
 */
export function LeadOutcomesTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id
  const { data: rows, isLoading, isError, refetch } = useLeadOutcomes(orgId)
  const createMut = useCreateLeadOutcome()
  const updateMut = useUpdateLeadOutcome()
  const existing = rows ?? []

  const fields: CrudFieldDef[] = [
    { key: "label_en", label: t("masters.leadOutcomes.labelEn"), type: "text", required: true },
    { key: "label_ta", label: t("masters.leadOutcomes.labelTa"), type: "text", required: true },
    { key: "followup_mode", label: t("masters.leadOutcomes.mode"), type: "select", options: MODES.map((m) => ({ value: m, label: t(`masters.leadOutcomes.modes.${m}`) })) },
    { key: "default_offset_days", label: t("masters.leadOutcomes.offsetDays"), type: "number", min: 0, max: 365, step: "1", placeholder: "0 = today, 1 = tomorrow" },
    { key: "default_followup_type", label: t("masters.leadOutcomes.followupType"), type: "select", options: FOLLOWUP_TYPES.map((ty) => ({ value: ty, label: t(`leads.followup.type.${ty}`) })) },
    { key: "stage_effect", label: t("masters.leadOutcomes.stageEffect"), type: "select", options: STAGES.map((s) => ({ value: s, label: s ? t(`leads.status.${s}`) : t("masters.leadOutcomes.noStageEffect") })) },
    {
      key: "lost_reason_hint",
      label: t("masters.leadOutcomes.lostReasonHint"),
      type: "select",
      options: [{ value: "", label: "—" }, ...LOST_REASON_PRESETS.filter((r) => r !== "other").map((r) => ({ value: r, label: t(`leads.lostReason.${r}`) }))],
    },
    {
      key: "counts_as_postpone",
      label: t("masters.leadOutcomes.countsAsPostpone"),
      type: "select",
      options: [
        { value: "false", label: t("masters.leadOutcomes.progress") },
        { value: "true", label: t("masters.leadOutcomes.postpone") },
      ],
    },
    { key: "sort_order", label: t("masters.leadOutcomes.sortOrder"), type: "number", min: 0, step: "1", required: true },
    {
      key: "is_active",
      label: t("masters.leadOutcomes.status"),
      type: "select",
      options: [
        { value: "true", label: t("masters.leadSources.active") },
        { value: "false", label: t("masters.leadSources.inactive") },
      ],
    },
  ]

  function toPayload(v: Record<string, string>) {
    const stage = (v.stage_effect || null) as Enums<"lead_status"> | null
    const closing = stage === "won" || stage === "lost"
    if (closing && v.followup_mode !== "none") throw new Error(t("masters.leadOutcomes.closingNeedsNoFollowup"))
    if (!closing && v.followup_mode === "none") throw new Error(t("masters.leadOutcomes.noneNeedsClosing"))
    if (stage === "lost" && !v.lost_reason_hint) throw new Error(t("masters.leadOutcomes.lostNeedsHint"))
    return {
      label_en: v.label_en.trim(),
      label_ta: v.label_ta.trim(),
      followup_mode: v.followup_mode as LeadOutcomeRow["followup_mode"],
      default_offset_days: v.followup_mode === "offset" || v.followup_mode === "exact_time" ? Number(v.default_offset_days || 0) : null,
      default_followup_type: v.default_followup_type as Enums<"lead_followup_type">,
      requires_followup: v.followup_mode !== "none",
      stage_effect: stage,
      lost_reason_hint: stage === "lost" ? v.lost_reason_hint : null,
      counts_as_postpone: v.counts_as_postpone === "true",
      sort_order: Number(v.sort_order),
      is_active: v.is_active !== "false",
    }
  }

  return (
    <div className="space-y-4">
      <ScheduleCard orgId={orgId} />
      <p className="px-1 text-xs text-text-muted">{t("masters.leadOutcomes.hint")}</p>
      <EntityCrudTable<LeadOutcomeRow>
        fields={fields}
        rows={existing}
        getId={(r) => r.id}
        loading={isLoading}
        error={isError ? t("masters.loadFailed") : null}
        onRetry={() => refetch()}
        isMutating={createMut.isPending || updateMut.isPending}
        addLabel={t("masters.leadOutcomes.add")}
        emptyMessage={t("masters.leadOutcomes.empty")}
        toFormValues={(r) => ({
          label_en: r.label_en,
          label_ta: r.label_ta,
          followup_mode: r.followup_mode,
          default_offset_days: r.default_offset_days == null ? "" : String(r.default_offset_days),
          default_followup_type: r.default_followup_type,
          stage_effect: r.stage_effect ?? "",
          lost_reason_hint: r.lost_reason_hint ?? "",
          counts_as_postpone: String(r.counts_as_postpone),
          sort_order: String(r.sort_order),
          is_active: String(r.is_active),
        })}
        columns={[
          { key: "label", header: t("masters.leadOutcomes.labelEn"), render: (r) => <span className="font-medium text-text">{r.label_en}</span> },
          { key: "ta", header: t("masters.leadOutcomes.labelTa"), render: (r) => <span className="text-text-muted">{r.label_ta}</span> },
          {
            key: "next",
            header: t("masters.leadOutcomes.nextFollowup"),
            render: (r) =>
              r.followup_mode === "none"
                ? t("masters.leadOutcomes.modes.none")
                : r.followup_mode === "offset"
                  ? t("masters.leadOutcomes.offsetShort", { count: r.default_offset_days ?? 0 })
                  : t(`masters.leadOutcomes.modes.${r.followup_mode}`),
          },
          { key: "stage", header: t("masters.leadOutcomes.stageEffect"), render: (r) => (r.stage_effect ? t(`leads.status.${r.stage_effect}`) : "—") },
          { key: "kind", header: t("masters.leadOutcomes.countsAsPostpone"), render: (r) => (r.counts_as_postpone ? t("masters.leadOutcomes.postpone") : t("masters.leadOutcomes.progress")) },
          {
            key: "status",
            header: t("masters.leadOutcomes.status"),
            render: (r) => <StatusDot tone={r.is_active ? "success" : "neutral"} label={r.is_active ? t("masters.leadSources.active") : t("masters.leadSources.inactive")} />,
          },
        ]}
        onCreate={async (v) => {
          const code = leadSourceKeyFromLabel(v.label_en)
          if (!code) throw new Error(t("masters.leadSources.invalidLabel"))
          if (existing.some((r) => r.code === code)) throw new Error(t("masters.leadOutcomes.duplicate"))
          return createMut.mutateAsync({ org_id: orgId!, code, ...toPayload(v) })
        }}
        onUpdate={(id, v) => updateMut.mutateAsync({ id, patch: toPayload(v) })}
        onDelete={async () => {
          throw new Error(t("masters.leadOutcomes.cannotDelete"))
        }}
        checkCanDelete={async () => false}
        cannotDeleteMessage={t("masters.leadOutcomes.cannotDelete")}
      />
    </div>
  )
}

function ScheduleCard({ orgId }: { orgId: string | undefined }) {
  const { t } = useTranslation()
  const { toast } = useToast()
  const { data } = useLeadSchedule(orgId)
  const update = useUpdateLeadSchedule(orgId)
  const s = data ?? DEFAULT_LEAD_SCHEDULE
  const [days, setDays] = useState<number[]>(s.lead_work_days)
  const [start, setStart] = useState(s.lead_work_start)
  const [end, setEnd] = useState(s.lead_work_end)
  const [stuck, setStuck] = useState(String(s.lead_stuck_postpones))
  const [reminder, setReminder] = useState(String(s.lead_reminder_minutes))

  useEffect(() => {
    if (!data) return
    setDays(data.lead_work_days)
    setStart(data.lead_work_start)
    setEnd(data.lead_work_end)
    setStuck(String(data.lead_stuck_postpones))
    setReminder(String(data.lead_reminder_minutes))
  }, [data])

  const valid = days.length > 0 && start < end && Number(stuck) >= 1 && Number(reminder) >= 1

  async function save() {
    try {
      await update.mutateAsync({
        lead_work_days: [...days].sort(),
        lead_work_start: start,
        lead_work_end: end,
        lead_stuck_postpones: Number(stuck),
        lead_reminder_minutes: Number(reminder),
      })
      toast.success(t("masters.leadOutcomes.schedule.saved"))
    } catch (e) {
      toast.error(e instanceof Error && e.message ? e.message : t("common.actionFailed"))
    }
  }

  return (
    <div className="space-y-3 rounded-xl border border-border p-4">
      <div>
        <h3 className="text-sm font-semibold text-text">{t("masters.leadOutcomes.schedule.title")}</h3>
        <p className="text-xs text-text-muted">{t("masters.leadOutcomes.schedule.hint")}</p>
      </div>
      <div className="flex flex-wrap gap-1.5" role="group" aria-label={t("masters.leadOutcomes.schedule.days")}>
        {DAY_KEYS.map((d) => (
          <button
            key={d}
            type="button"
            aria-pressed={days.includes(d)}
            onClick={() => setDays((cur) => (cur.includes(d) ? cur.filter((x) => x !== d) : [...cur, d]))}
            className={`rounded-full border px-3 py-1.5 text-xs font-semibold ${days.includes(d) ? "border-ink bg-ink text-white" : "border-border bg-surface text-text-muted"}`}
          >
            {t(`leads.followup.weekdayShort.${d}`)}
          </button>
        ))}
      </div>
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <div className="space-y-1.5">
          <Label htmlFor="lead-work-start">{t("masters.leadOutcomes.schedule.start")}</Label>
          <Input id="lead-work-start" type="time" value={start} onChange={(e) => setStart(e.target.value)} />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="lead-work-end">{t("masters.leadOutcomes.schedule.end")}</Label>
          <Input id="lead-work-end" type="time" value={end} onChange={(e) => setEnd(e.target.value)} />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="lead-stuck">{t("masters.leadOutcomes.schedule.stuck")}</Label>
          <Input id="lead-stuck" type="number" min={1} step={1} value={stuck} onChange={(e) => setStuck(e.target.value)} />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="lead-reminder">{t("masters.leadOutcomes.schedule.reminder")}</Label>
          <Input id="lead-reminder" type="number" min={1} step={1} value={reminder} onChange={(e) => setReminder(e.target.value)} />
        </div>
      </div>
      <div className="flex justify-end">
        <Button size="sm" onClick={save} disabled={!valid || update.isPending}>
          {update.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("common.save")}
        </Button>
      </div>
    </div>
  )
}
