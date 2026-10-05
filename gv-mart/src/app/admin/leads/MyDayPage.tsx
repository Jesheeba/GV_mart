import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { Inbox, TriangleAlert } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Skeleton } from "@/components/ui/skeleton"
import { useFollowups } from "@/hooks/useLeadFollowups"
import { useLeadSourceOptions } from "@/hooks/useLeadSources"
import { FollowupCard } from "./FollowupCard"
import { LogOutcomeSheet } from "./LogOutcomeSheet"
import { RescheduleDialog } from "./RescheduleDialog"
import { formatIstDate, getIstNow } from "@/lib/lead-followups"
import { cn } from "@/lib/utils"
import type { FollowupBucket, FollowupListItem } from "@/services/leadFollowups"
import type { Enums } from "@/types/database"

const TABS: FollowupBucket[] = ["overdue", "today", "upcoming"]
const STAGES: Enums<"lead_status">[] = ["new", "contacted", "quoted"]
const KINDS: Enums<"lead_kind">[] = ["service", "spare", "product", "amc"]

const selectClass =
  "h-9 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"

/** The shared follow-up list for master + sales_admin: what to call, in order, today. */
export function MyDayPage() {
  const { t, i18n } = useTranslation()
  const { sources, label: sourceLabel } = useLeadSourceOptions()
  const [chosenTab, setChosenTab] = useState<FollowupBucket | null>(null)
  const [stage, setStage] = useState<Enums<"lead_status"> | "">("")
  const [source, setSource] = useState("")
  const [kind, setKind] = useState<Enums<"lead_kind"> | "">("")
  const [stuckOnly, setStuckOnly] = useState(false)

  const [outcomeFor, setOutcomeFor] = useState<FollowupListItem | null>(null)
  const [rescheduleFor, setRescheduleFor] = useState<FollowupListItem | null>(null)

  const list = useFollowups({ bucket: "all", stage: stage || undefined, source: source || undefined, kind: kind || undefined, stuckOnly })

  const byBucket = useMemo(() => {
    const out: Record<FollowupBucket, FollowupListItem[]> = { overdue: [], today: [], upcoming: [] }
    for (const r of list.data ?? []) if (r.bucket in out) out[r.bucket as FollowupBucket].push(r)
    return out
  }, [list.data])

  const tab = chosenTab ?? (byBucket.overdue.length > 0 ? "overdue" : "today")
  const rows = byBucket[tab]
  const filtersActive = !!(stage || source || kind || stuckOnly)

  return (
    <div className="space-y-4 pt-2">
      <div>
        <h1 className="text-2xl font-bold text-text">{t("leads.myDay.title")}</h1>
        <p className="text-sm text-text-muted">{t("leads.myDay.subtitle", { date: formatIstDate(getIstNow().date, i18n.language) })}</p>
      </div>

      <div className="flex flex-wrap items-center gap-2.5">
        <div className="flex gap-[3px] rounded-full border border-border bg-surface p-1" role="tablist">
          {TABS.map((b) => (
            <button
              key={b}
              type="button"
              role="tab"
              aria-selected={tab === b}
              onClick={() => setChosenTab(b)}
              className={cn(
                "flex items-center gap-1.5 rounded-full px-3.5 py-[7px] text-xs font-semibold transition-colors",
                tab === b ? (b === "overdue" ? "bg-danger text-white" : "bg-ink text-white") : b === "overdue" && byBucket.overdue.length > 0 ? "text-danger" : "text-text-muted"
              )}
            >
              {t(`leads.myDay.tab.${b}`)}
              <span className={cn("rounded-full px-1.5 text-[10px] tabular-nums", tab === b ? "bg-white/20" : "bg-surface-alt")}>{list.isLoading ? "…" : byBucket[b].length}</span>
            </button>
          ))}
        </div>

        <select value={stage} onChange={(e) => setStage(e.target.value as Enums<"lead_status"> | "")} className={selectClass} aria-label={t("leads.myDay.filters.stage")}>
          <option value="">{t("leads.myDay.filters.allStages")}</option>
          {STAGES.map((s) => (
            <option key={s} value={s}>
              {t(`leads.status.${s}`)}
            </option>
          ))}
        </select>
        <select value={source} onChange={(e) => setSource(e.target.value)} className={selectClass} aria-label={t("leads.myDay.filters.source")}>
          <option value="">{t("leads.filters.allSources")}</option>
          {sources.map((s) => (
            <option key={s.key} value={s.key}>
              {sourceLabel(s.key)}
            </option>
          ))}
        </select>
        <select value={kind} onChange={(e) => setKind(e.target.value as Enums<"lead_kind"> | "")} className={selectClass} aria-label={t("leads.myDay.filters.kind")}>
          <option value="">{t("leads.filters.allKinds")}</option>
          {KINDS.map((k) => (
            <option key={k} value={k}>
              {t(`leads.kind.${k}`)}
            </option>
          ))}
        </select>
        <button
          type="button"
          aria-pressed={stuckOnly}
          onClick={() => setStuckOnly((v) => !v)}
          className={cn("rounded-full border px-3.5 py-2 text-xs font-semibold", stuckOnly ? "border-danger bg-danger text-white" : "border-border bg-surface text-text-muted")}
        >
          {t("leads.myDay.filters.stuckOnly")}
        </button>
        {filtersActive ? (
          <button
            type="button"
            onClick={() => {
              setStage("")
              setSource("")
              setKind("")
              setStuckOnly(false)
            }}
            className="text-xs font-semibold text-text-muted hover:text-text"
          >
            {t("leads.filters.clear")}
          </button>
        ) : null}
      </div>

      {list.isError ? (
        <div className="flex flex-col items-center gap-3 rounded-card border border-border bg-surface py-12 text-center">
          <TriangleAlert className="size-6 text-danger" />
          <p className="text-sm text-text-muted">{t("leads.myDay.loadFailed")}</p>
          <Button variant="outline" size="sm" onClick={() => list.refetch()}>
            {t("common.retry")}
          </Button>
        </div>
      ) : list.isLoading ? (
        <div className="space-y-3">
          {Array.from({ length: 3 }).map((_, i) => (
            <Skeleton key={i} className="h-28 w-full rounded-subcard" />
          ))}
        </div>
      ) : rows.length === 0 ? (
        <div className="flex flex-col items-center gap-2 rounded-card border border-dashed border-border py-14 text-center">
          <Inbox className="size-6 text-text-muted" />
          <p className="text-sm text-text-muted">{t(`leads.myDay.empty.${tab}`)}</p>
        </div>
      ) : (
        <div className="grid grid-cols-1 gap-3 xl:grid-cols-2" data-testid="followup-list">
          {rows.map((r) => (
            <FollowupCard key={r.followup_id} item={r} onLogOutcome={setOutcomeFor} onReschedule={setRescheduleFor} />
          ))}
        </div>
      )}

      <LogOutcomeSheet
        lead={outcomeFor ? { id: outcomeFor.lead_id, name: outcomeFor.lead_name, mobile: outcomeFor.mobile, status: outcomeFor.lead_status } : null}
        open={!!outcomeFor}
        onOpenChange={(o) => !o && setOutcomeFor(null)}
      />
      <RescheduleDialog lead={rescheduleFor ? { id: rescheduleFor.lead_id, name: rescheduleFor.lead_name } : null} open={!!rescheduleFor} onOpenChange={(o) => !o && setRescheduleFor(null)} />
    </div>
  )
}
