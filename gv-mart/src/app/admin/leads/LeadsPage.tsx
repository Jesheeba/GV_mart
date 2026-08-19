import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { Inbox, LayoutGrid, Plus, Table2, Target, TrendingUp, TriangleAlert, Trophy } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Skeleton } from "@/components/ui/skeleton"
import { KpiCard } from "@/components/shared/KpiCard"
import { StatusDot } from "@/components/shared/StatusDot"
import { useProfile } from "@/hooks/useProfile"
import { useLeads } from "@/hooks/useAutomation"
import { LeadsKanban } from "./LeadsKanban"
import { LeadDetailPanel } from "./LeadDetailPanel"
import { NewLeadForm } from "./NewLeadForm"
import { SourceBadge } from "./LeadBadges"
import type { LeadListItem } from "@/services/automation"
import type { Enums } from "@/types/database"
import { cn } from "@/lib/utils"

const TABLE_GRID_COLS = "grid-cols-[1.4fr_1fr_1fr_0.8fr_1fr_0.9fr_1.2fr_1fr]"

const SOURCE_OPTIONS: Enums<"lead_source">[] = ["field", "customer_app", "whatsapp", "walk_in", "referral", "other"]
const TOPIC_OPTIONS: Enums<"enquiry_type">[] = ["online", "price", "quality", "customization", "water_premium", "budget"]
const KIND_OPTIONS: Enums<"lead_kind">[] = ["service", "spare", "product", "amc"]

export function LeadsPage() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const [view, setView] = useState<"table" | "kanban">("kanban")
  const [source, setSource] = useState<Enums<"lead_source"> | "">("")
  const [enquiryType, setEnquiryType] = useState<Enums<"enquiry_type"> | "">("")
  const [kind, setKind] = useState<Enums<"lead_kind"> | "">("")
  const leads = useLeads(orgId, { source: source || undefined, enquiryType: enquiryType || undefined, kind: kind || undefined })
  const [showNew, setShowNew] = useState(false)
  const [selected, setSelected] = useState<LeadListItem | null>(null)

  const stats = useMemo(() => {
    const rows = leads.data ?? []
    const won = rows.filter((r) => r.status === "won").length
    const lost = rows.filter((r) => r.status === "lost").length
    const closed = won + lost
    const conversionRate = closed > 0 ? Math.round((won / closed) * 100) : 0
    const bySource = new Map<string, number>()
    for (const r of rows) bySource.set(r.source, (bySource.get(r.source) ?? 0) + 1)
    const topSource = [...bySource.entries()].sort((a, b) => b[1] - a[1])[0]
    return { total: rows.length, won, conversionRate, topSource }
  }, [leads.data])

  return (
    <div className="space-y-4 pt-2">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold text-text">{t("nav.leads")}</h1>
          <p className="text-sm text-text-muted">{t("leads.subtitle")}</p>
        </div>
        <div className="flex items-center gap-2.5">
          <div className="flex gap-[3px] rounded-full border border-border bg-surface p-1">
            <button
              type="button"
              onClick={() => setView("table")}
              aria-pressed={view === "table"}
              title={t("leads.view.table")}
              className={cn(
                "flex items-center gap-1.5 rounded-full px-3.5 py-[7px] text-xs font-semibold transition-colors",
                view === "table" ? "bg-ink text-white" : "text-text-muted"
              )}
            >
              <Table2 className="size-3.5" /> {t("leads.view.table")}
            </button>
            <button
              type="button"
              onClick={() => setView("kanban")}
              aria-pressed={view === "kanban"}
              title={t("leads.view.kanban")}
              className={cn(
                "flex items-center gap-1.5 rounded-full px-3.5 py-[7px] text-xs font-semibold transition-colors",
                view === "kanban" ? "bg-ink text-white" : "text-text-muted"
              )}
            >
              <LayoutGrid className="size-3.5" /> {t("leads.view.kanban")}
            </button>
          </div>
          <Button variant="accent" onClick={() => setShowNew((v) => !v)}>
            <Plus className="size-4" />
            {t("leads.new.title")}
          </Button>
        </div>
      </div>

      <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
        <KpiCard label={t("leads.kpi.total")} value={stats.total} icon={<Target className="size-4" />} loading={leads.isLoading} />
        <KpiCard label={t("leads.kpi.won")} value={stats.won} icon={<Trophy className="size-4" />} loading={leads.isLoading} />
        <KpiCard
          label={t("leads.kpi.conversionRate")}
          value={`${stats.conversionRate}%`}
          icon={<TrendingUp className="size-4" />}
          loading={leads.isLoading}
        />
      </div>

      {showNew ? <NewLeadForm onClose={() => setShowNew(false)} onCreated={() => { setShowNew(false); leads.refetch() }} /> : null}

      <div className="flex flex-wrap items-center gap-2.5">
        <select
          value={source}
          onChange={(e) => setSource(e.target.value as Enums<"lead_source"> | "")}
          className="h-9 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"
        >
          <option value="">{t("leads.filters.allSources")}</option>
          {SOURCE_OPTIONS.map((s) => (
            <option key={s} value={s}>
              {t(`leads.source.${s}`)}
            </option>
          ))}
        </select>
        <select
          value={enquiryType}
          onChange={(e) => setEnquiryType(e.target.value as Enums<"enquiry_type"> | "")}
          className="h-9 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"
        >
          <option value="">{t("leads.filters.allTopics")}</option>
          {TOPIC_OPTIONS.map((et) => (
            <option key={et} value={et}>
              {t(`leads.enquiryType.${et}`)}
            </option>
          ))}
        </select>
        <select
          value={kind}
          onChange={(e) => setKind(e.target.value as Enums<"lead_kind"> | "")}
          className="h-9 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"
        >
          <option value="">{t("leads.filters.allKinds")}</option>
          {KIND_OPTIONS.map((k) => (
            <option key={k} value={k}>
              {t(`leads.kind.${k}`)}
            </option>
          ))}
        </select>
        {source || enquiryType || kind ? (
          <button
            type="button"
            onClick={() => {
              setSource("")
              setEnquiryType("")
              setKind("")
            }}
            className="text-xs font-semibold text-text-muted hover:text-text"
          >
            {t("leads.filters.clear")}
          </button>
        ) : null}
      </div>

      <div className="flex flex-col gap-4 lg:flex-row lg:items-start">
        {/* The board needs room for 5 status columns — a fixed-width detail
            sidebar (rather than a 2:1 grid fraction) keeps the columns from
            getting cramped while the panel stays a comfortable reading width
            instead of stretching to a third of the page when nothing (or a
            single lead) is shown there. */}
        <div className="min-w-0 lg:flex-1">
          {view === "table" ? (
            <LeadsTable
              rows={leads.data ?? []}
              loading={leads.isLoading}
              error={leads.isError ? t("leads.loadFailed") : null}
              onRetry={() => leads.refetch()}
              onRowClick={setSelected}
            />
          ) : (
            <LeadsKanban
              rows={leads.data ?? []}
              loading={leads.isLoading}
              error={leads.isError ? t("leads.loadFailed") : null}
              onRetry={() => leads.refetch()}
              onCardClick={setSelected}
            />
          )}
        </div>
        <div className="lg:w-80 lg:shrink-0">
          {selected ? (
            <LeadDetailPanel lead={selected} onClose={() => setSelected(null)} />
          ) : (
            <div className="rounded-subcard border border-dashed border-border p-6 text-center text-sm text-text-muted">
              {t("leads.detail.selectHint")}
            </div>
          )}
        </div>
      </div>
    </div>
  )
}

// Bespoke grid table (not the shared <DataTable>) — mirrors the pattern
// TicketsListPage.tsx uses for its Table/Kanban toggle.
function LeadsTable({
  rows,
  loading,
  error,
  onRetry,
  onRowClick,
}: {
  rows: LeadListItem[]
  loading: boolean
  error: string | null
  onRetry: () => void
  onRowClick: (row: LeadListItem) => void
}) {
  const { t } = useTranslation()

  const headers = [
    t("leads.table.name"),
    t("leads.table.mobile"),
    t("leads.table.source"),
    t("leads.table.kind"),
    t("leads.table.topic"),
    t("leads.table.status"),
    t("leads.table.technician"),
    t("leads.table.created"),
  ]

  return (
    <div className="overflow-hidden rounded-card border border-border bg-surface shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
      <div className={cn("grid items-center border-b border-border bg-surface-alt px-[22px] py-[11px]", TABLE_GRID_COLS)}>
        {headers.map((h) => (
          <span key={h} className="text-[11px] font-semibold uppercase tracking-wide text-text-muted">
            {h}
          </span>
        ))}
      </div>

      {error ? (
        <div className="flex flex-col items-center gap-3 py-12 text-center">
          <TriangleAlert className="size-6 text-danger" />
          <p className="text-sm text-text-muted">{error}</p>
          <Button variant="outline" size="sm" onClick={onRetry}>
            {t("common.retry")}
          </Button>
        </div>
      ) : loading ? (
        Array.from({ length: 6 }).map((_, i) => (
          <div key={i} className={cn("grid items-center border-b border-border px-[22px] py-[14px]", TABLE_GRID_COLS)}>
            {headers.map((h) => (
              <Skeleton key={h} className="h-4 w-3/4 max-w-32" />
            ))}
          </div>
        ))
      ) : rows.length === 0 ? (
        <div className="flex flex-col items-center gap-2 py-12 text-center">
          <Inbox className="size-6 text-text-muted" />
          <p className="text-sm text-text-muted">{t("leads.empty")}</p>
        </div>
      ) : (
        rows.map((r) => (
          <div
            key={r.id}
            role="button"
            tabIndex={0}
            onClick={() => onRowClick(r)}
            onKeyDown={(e) => {
              if (e.key === "Enter" || e.key === " ") onRowClick(r)
            }}
            className={cn("grid cursor-pointer items-center border-b border-border px-[22px] py-[14px] last:border-b-0 hover:bg-surface-alt", TABLE_GRID_COLS)}
          >
            <span className="truncate text-[13px] font-semibold text-text">{r.customers?.name ?? r.name}</span>
            <span className="text-[13px] font-medium text-text-muted">{r.mobile ?? r.customers?.mobile ?? "—"}</span>
            <SourceBadge source={r.source} />
            <span className="text-[13px] font-medium text-text">{r.kind ? t(`leads.kind.${r.kind}`) : "—"}</span>
            <span className="text-[13px] font-medium text-text">{r.enquiry_type ? t(`leads.enquiryType.${r.enquiry_type}`) : "—"}</span>
            <StatusDot
              tone={r.status === "won" ? "success" : r.status === "lost" ? "danger" : "warning"}
              label={t(`leads.status.${r.status}`)}
            />
            <span className="truncate text-[13px] font-medium text-text">{r.technicians?.profiles?.full_name ?? "—"}</span>
            <span className="text-xs font-medium text-text-muted">{new Date(r.created_at).toLocaleDateString()}</span>
          </div>
        ))
      )}
    </div>
  )
}
