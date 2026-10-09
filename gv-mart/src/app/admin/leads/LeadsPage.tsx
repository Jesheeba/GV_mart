import { useMemo, useState } from "react"
import { useNavigate } from "react-router-dom"
import { useTranslation } from "react-i18next"
import { Inbox, LayoutGrid, Plus, Search, Table2, Target, TrendingUp, TriangleAlert, Trophy, XCircle } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Skeleton } from "@/components/ui/skeleton"
import { KpiCard } from "@/components/shared/KpiCard"
import { StatusDot } from "@/components/shared/StatusDot"
import { useProfile } from "@/hooks/useProfile"
import { WaitingLeadsBanner } from "./WaitingLeadsBanner"
import { useLeads } from "@/hooks/useAutomation"
import { LeadsKanban } from "./LeadsKanban"
import { NewLeadForm } from "./NewLeadForm"
import { useLeadSourceOptions } from "@/hooks/useLeadSources"
import { useLeadKindOptions } from "@/hooks/useLeadLists"
import { SourceBadge, TechnicianChip } from "./LeadBadges"
import { FollowupCell } from "./FollowupBadges"
import { useLeadAssignees, useLeadSchedule } from "@/hooks/useLeadFollowups"
import { AssignLeadDialog } from "./AssignLeadDialog"
import { SetFollowupDialog } from "./SetFollowupDialog"
import { canScheduleLead } from "@/lib/lead-assign"
import type { UserRole } from "@/lib/roles"
import { DEFAULT_LEAD_SCHEDULE } from "@/services/leadFollowups"
import { isOverdueNow } from "@/lib/lead-followups"
import type { LeadListItem } from "@/services/automation"
import type { Enums } from "@/types/database"
import { cn } from "@/lib/utils"

const TABLE_GRID_COLS =
  "grid-cols-[minmax(140px,1.3fr)_minmax(90px,1fr)_minmax(90px,1fr)_minmax(70px,0.7fr)_minmax(90px,0.9fr)_minmax(100px,0.8fr)_minmax(170px,1.4fr)_minmax(110px,1fr)_minmax(80px,0.8fr)]"

type QuickFilter = "" | "overdue" | "noFollowup" | "stuck"
const QUICK_FILTERS: Exclude<QuickFilter, "">[] = ["overdue", "noFollowup", "stuck"]

const TOPIC_OPTIONS: Enums<"enquiry_type">[] = ["online", "price", "quality", "customization", "water_premium", "budget"]

export function LeadsPage() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id
  const { sources, label } = useLeadSourceOptions()
  const { activeKinds, label: kindLabel } = useLeadKindOptions()

  const [view, setView] = useState<"table" | "kanban">("kanban")
  const [source, setSource] = useState<string>("")
  const [enquiryType, setEnquiryType] = useState<Enums<"enquiry_type"> | "">("")
  const [kind, setKind] = useState<string>("")
  const [search, setSearch] = useState("")
  const leads = useLeads(orgId, { source: source || undefined, enquiryType: enquiryType || undefined, kind: kind || undefined })
  const [showNew, setShowNew] = useState(false)
  const navigate = useNavigate()
  const schedule = useLeadSchedule(orgId).data ?? DEFAULT_LEAD_SCHEDULE
  const [quick, setQuick] = useState<QuickFilter>("")
  const role = profile?.role as UserRole | undefined
  const isMaster = role === "master"
  const assignees = useLeadAssignees(orgId, role).data ?? []
  // "": master = everyone; sales_admin = own + unassigned. Also "mine", "unassigned", or a person id (master).
  const [assignedFilter, setAssignedFilter] = useState<string>("")
  const [selectMode, setSelectMode] = useState(false)
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const [assignOpen, setAssignOpen] = useState(false)
  const [scheduleFor, setScheduleFor] = useState<LeadListItem | null>(null)
  const canSchedule = (l: LeadListItem) => canScheduleLead(role, profile?.id, l.assigned_to, assignees)
  const activeAssignee = (l: LeadListItem) => (l.assigned_to && assignees.some((a) => a.id === l.assigned_to) ? l.assigned_to : null)
  const assigneeName = (l: LeadListItem) => assignees.find((a) => a.id === activeAssignee(l))?.full_name ?? null
  const openLead = (l: LeadListItem) => navigate("/admin/leads/" + l.id)

  const stats = useMemo(() => {
    const rows = leads.data ?? []
    const won = rows.filter((r) => r.status === "won").length
    const lost = rows.filter((r) => r.status === "lost").length
    const closed = won + lost
    // Item 5 (2026-09-16): Won%/Lost% both read "of closed leads" — same
    // denominator conversionRate already used, so a lead still New/Contacted/
    // Quoted doesn't dilute either percentage.
    const wonPct = closed > 0 ? Math.round((won / closed) * 100) : 0
    const lostPct = closed > 0 ? Math.round((lost / closed) * 100) : 0
    return { total: rows.length, won, wonPct, lost, lostPct, conversionRate: wonPct }
  }, [leads.data])

  const searchTerm = search.trim().toLowerCase()
  const stuckAt = schedule.lead_stuck_postpones
  const filteredLeads = useMemo(
    () =>
      (leads.data ?? []).filter((l) => {
        if (searchTerm && !((l.customers?.name ?? l.name ?? "").toLowerCase().includes(searchTerm) || (l.mobile ?? l.customers?.mobile ?? "").includes(searchTerm))) return false
        const who = activeAssignee(l)
        if (assignedFilter === "mine" && who !== profile?.id) return false
        if (assignedFilter === "unassigned" && who !== null) return false
        if (assignedFilter === "" && !isMaster && who !== null && who !== profile?.id) return false
        if (assignedFilter && assignedFilter !== "mine" && assignedFilter !== "unassigned" && who !== assignedFilter) return false
        const open = l.status !== "won" && l.status !== "lost"
        if (quick === "overdue") return open && !!l.next_followup_at && isOverdueNow(l.next_followup_at)
        if (quick === "noFollowup") return open && !l.next_followup_at
        if (quick === "stuck") return open && l.postpone_count >= stuckAt
        return true
      }),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [leads.data, searchTerm, quick, stuckAt, assignedFilter, assignees, profile?.id, isMaster]
  )
  const selectedOpen = filteredLeads.filter((l) => selected.has(l.id) && l.status !== "won" && l.status !== "lost")

  return (
    <div className="space-y-4 pt-2">
      <WaitingLeadsBanner />
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

      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <KpiCard label={t("leads.kpi.total")} value={stats.total} icon={<Target className="size-4" />} loading={leads.isLoading} />
        <KpiCard
          label={t("leads.kpi.won")}
          value={
            <>
              {stats.won} <span className="text-base font-medium text-text-muted">({stats.wonPct}%)</span>
            </>
          }
          icon={<Trophy className="size-4" />}
          loading={leads.isLoading}
        />
        <KpiCard
          label={t("leads.kpi.lost")}
          value={
            <>
              {stats.lost} <span className="text-base font-medium text-text-muted">({stats.lostPct}%)</span>
            </>
          }
          icon={<XCircle className="size-4" />}
          loading={leads.isLoading}
        />
        <KpiCard
          label={t("leads.kpi.conversionRate")}
          value={`${stats.conversionRate}%`}
          icon={<TrendingUp className="size-4" />}
          loading={leads.isLoading}
        />
      </div>

      {showNew ? <NewLeadForm onClose={() => setShowNew(false)} onCreated={() => { setShowNew(false); leads.refetch() }} /> : null}

      <div className="flex flex-wrap items-center gap-2.5">
        <div className="flex w-56 items-center gap-2.25 rounded-full border border-border bg-surface-alt px-3.5 py-2">
          <Search className="size-3.75 shrink-0 text-text-muted" />
          <input
            type="text"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder={t("leads.filters.search")}
            className="w-full bg-transparent text-xs font-medium text-text outline-none placeholder:text-text-muted"
          />
        </div>
        <select
          value={source}
          onChange={(e) => setSource(e.target.value)}
          className="h-9 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"
        >
          <option value="">{t("leads.filters.allSources")}</option>
          {sources.map((s) => (
            <option key={s.key} value={s.key}>
              {label(s.key)}
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
          onChange={(e) => setKind(e.target.value)}
          className="h-9 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"
        >
          <option value="">{t("leads.filters.allKinds")}</option>
          {activeKinds.map((k) => (
            <option key={k.key} value={k.key}>
              {kindLabel(k.key)}
            </option>
          ))}
        </select>
        <select
          value={assignedFilter}
          onChange={(e) => setAssignedFilter(e.target.value)}
          aria-label={t("leads.assign.filterLabel")}
          data-testid="assigned-filter"
          className="h-9 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"
        >
          <option value="">{t(isMaster ? "leads.assign.scope.all" : "leads.assign.scope.mineUnassigned")}</option>
          <option value="mine">{t("leads.assign.scope.mine")}</option>
          <option value="unassigned">{t("leads.assign.scope.unassigned")}</option>
          {isMaster
            ? assignees
                .filter((a) => a.id !== profile?.id)
                .map((a) => (
                  <option key={a.id} value={a.id}>
                    {a.full_name}
                  </option>
                ))
            : null}
        </select>
        {isMaster && view === "table" ? (
          <>
            <button
              type="button"
              aria-pressed={selectMode}
              onClick={() => {
                setSelectMode((v) => !v)
                setSelected(new Set())
              }}
              className={cn("rounded-full border px-3.5 py-2 text-xs font-semibold", selectMode ? "border-ink bg-ink text-white" : "border-border bg-surface text-text-muted")}
            >
              {t(selectMode ? "leads.assign.selectDone" : "leads.assign.select")}
            </button>
            {selectMode && selectedOpen.length > 0 ? (
              <Button size="sm" variant="accent" onClick={() => setAssignOpen(true)}>
                {t("leads.assign.assignSelected", { count: selectedOpen.length })}
              </Button>
            ) : null}
          </>
        ) : null}
        <div className="flex gap-1.5" role="group" aria-label={t("leads.quick.label")}>
          {QUICK_FILTERS.map((q) => (
            <button
              key={q}
              type="button"
              aria-pressed={quick === q}
              onClick={() => setQuick((cur) => (cur === q ? "" : q))}
              className={cn(
                "rounded-full border px-3.5 py-2 text-xs font-semibold",
                quick === q ? (q === "noFollowup" ? "border-ink bg-ink text-white" : "border-danger bg-danger text-white") : "border-border bg-surface text-text-muted"
              )}
            >
              {t("leads.quick." + q)}
            </button>
          ))}
        </div>
        {source || enquiryType || kind || search || quick || assignedFilter ? (
          <button
            type="button"
            onClick={() => {
              setSource("")
              setEnquiryType("")
              setKind("")
              setSearch("")
              setQuick("")
              setAssignedFilter("")
            }}
            className="text-xs font-semibold text-text-muted hover:text-text"
          >
            {t("leads.filters.clear")}
          </button>
        ) : null}
      </div>

      <div className="min-w-0">
        {view === "table" ? (
          <LeadsTable
            rows={filteredLeads}
            loading={leads.isLoading}
            error={leads.isError ? t("leads.loadFailed") : null}
            onRetry={() => leads.refetch()}
            onRowClick={openLead}
            stuckAt={stuckAt}
            assigneeName={assigneeName}
            canSchedule={canSchedule}
            onSetFollowup={setScheduleFor}
            selectMode={selectMode}
            selected={selected}
            onToggle={(id) => setSelected((cur) => { const n = new Set(cur); if (n.has(id)) n.delete(id); else n.add(id); return n })}
          />
        ) : (
          <LeadsKanban
            rows={filteredLeads}
            loading={leads.isLoading}
            error={leads.isError ? t("leads.loadFailed") : null}
            onRetry={() => leads.refetch()}
            onCardClick={openLead}
            stuckAt={stuckAt}
          />
        )}
      </div>

      <SetFollowupDialog lead={scheduleFor ? { id: scheduleFor.id, name: scheduleFor.customers?.name ?? scheduleFor.name } : null} open={!!scheduleFor} onOpenChange={(o) => !o && setScheduleFor(null)} />
      <AssignLeadDialog
        leads={selectedOpen.map((l) => ({ id: l.id, name: l.customers?.name ?? l.name, assignedTo: l.assigned_to }))}
        open={assignOpen}
        onOpenChange={setAssignOpen}
        onDone={() => {
          setSelected(new Set())
          setSelectMode(false)
        }}
      />
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
  stuckAt,
  assigneeName,
  canSchedule,
  onSetFollowup,
  selectMode,
  selected,
  onToggle,
}: {
  rows: LeadListItem[]
  loading: boolean
  error: string | null
  onRetry: () => void
  onRowClick: (row: LeadListItem) => void
  stuckAt: number
  assigneeName: (row: LeadListItem) => string | null
  canSchedule: (row: LeadListItem) => boolean
  onSetFollowup: (row: LeadListItem) => void
  selectMode: boolean
  selected: Set<string>
  onToggle: (id: string) => void
}) {
  const { t } = useTranslation()
  const { label: kindLabel } = useLeadKindOptions()

  const headers = [
    t("leads.table.name"),
    t("leads.table.mobile"),
    t("leads.table.source"),
    t("leads.table.kind"),
    t("leads.table.topic"),
    t("leads.table.status"),
    t("leads.table.nextFollowup"),
    t("leads.table.technician"),
    t("leads.table.created"),
  ]

  return (
    <div className="overflow-x-auto rounded-card border border-border bg-surface shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
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
            <span className="flex min-w-0 items-start gap-2">
              {selectMode && r.status !== "won" && r.status !== "lost" ? (
                <input
                  type="checkbox"
                  checked={selected.has(r.id)}
                  onChange={() => onToggle(r.id)}
                  onClick={(e) => e.stopPropagation()}
                  aria-label={r.customers?.name ?? r.name}
                  className="mt-0.5 size-4 shrink-0 accent-accent"
                />
              ) : null}
              <span className="min-w-0">
                <span className="block truncate text-[13px] font-semibold text-text">{r.customers?.name ?? r.name}</span>
                <span className="block truncate text-[11px] text-text-muted" data-testid="row-assignee">
                  {assigneeName(r) ?? t("leads.assign.unassigned")}
                </span>
              </span>
            </span>
            <span className="text-[13px] font-medium text-text-muted">{r.mobile ?? r.customers?.mobile ?? "—"}</span>
            <SourceBadge source={r.source} />
            <span className="text-[13px] font-medium text-text">{r.kind_key ?? r.kind ? kindLabel((r.kind_key ?? r.kind)!) : "—"}</span>
            <span className="text-[13px] font-medium text-text">{r.enquiry_type ? t(`leads.enquiryType.${r.enquiry_type}`) : "—"}</span>
            <StatusDot
              tone={r.status === "won" ? "success" : r.status === "lost" ? "danger" : "warning"}
              label={t(`leads.status.${r.status}`)}
            />
            <span className="flex flex-wrap items-center gap-1.5">
              <FollowupCell lead={r} stuckAt={stuckAt} />
              {r.status !== "won" && r.status !== "lost" && !r.next_followup_at && canSchedule(r) ? (
                <button
                  type="button"
                  data-testid="row-set-followup"
                  onClick={(e) => {
                    e.stopPropagation()
                    onSetFollowup(r)
                  }}
                  className="rounded-full border border-border px-2.5 py-0.5 text-[11px] font-semibold text-text hover:bg-surface-alt"
                >
                  {t("leads.followup.setButton")}
                </button>
              ) : null}
            </span>
            <TechnicianChip source={r.source} name={r.technicians?.profiles?.full_name ?? null} />
            <span className="text-xs font-medium text-text-muted">{new Date(r.created_at).toLocaleDateString()}</span>
          </div>
        ))
      )}
    </div>
  )
}

