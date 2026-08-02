import { useMemo, useState, type ReactNode } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { CalendarClock, Inbox, LayoutGrid, Plus, Repeat, Table2, TriangleAlert } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { DatePicker } from "@/components/ui/date-picker"
import { Skeleton } from "@/components/ui/skeleton"
import { useProfile } from "@/hooks/useProfile"
import { useRepeatComplaintCustomers, useTechnicians, useTicketsList } from "@/hooks/useService"
import type { TicketListItem } from "@/services/service"
import { cn } from "@/lib/utils"
import { SlaCountdown } from "./SlaCountdown"
import { PriorityText, TicketTypeBadge } from "./TicketBadges"
import { TicketsKanban } from "./TicketsKanban"

const STATUS_OPTIONS = ["open", "assigned", "in_progress", "completed", "cancelled"] as const
const PRIORITY_OPTIONS = ["very_urgent", "urgent", "normal"] as const
const TYPE_OPTIONS = ["paid", "warranty", "amc", "installation"] as const

// Matches the design's 8-column table grid (design-template-decoded.html line 964):
// Ticket / Customer / Complaint / Type / Prio / Technician / Appointment / SLA.
const TABLE_GRID_COLS = "grid-cols-[0.95fr_1.5fr_1.5fr_0.8fr_0.6fr_1.1fr_1.1fr_1fr]"

type QuickFilter = "all" | "overdue" | "amc" | "warranty" | "unassigned"

function isOverdueRow(r: TicketListItem, now: number) {
  return !!r.sla_due_at && r.status !== "completed" && r.status !== "cancelled" && new Date(r.sla_due_at).getTime() <= now
}
function isUnassignedRow(r: TicketListItem) {
  return r.appointments.length === 0 || r.appointments.every((a) => !a.technician_id)
}

export function TicketsListPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const [view, setView] = useState<"table" | "kanban">("table")
  const [quickFilter, setQuickFilter] = useState<QuickFilter>("all")
  const [status, setStatus] = useState("")
  const [priority, setPriority] = useState("")
  const [type, setType] = useState("")
  const [technicianId, setTechnicianId] = useState("")
  const [date, setDate] = useState("")
  const [area, setArea] = useState("")

  const filters = useMemo(
    () => ({ status, priority, type, technicianId, date, area }),
    [status, priority, type, technicianId, date, area]
  )

  const { data: rows, isLoading, isError, refetch } = useTicketsList(orgId, filters)
  const { data: technicians } = useTechnicians(orgId)
  const { data: repeatCustomers } = useRepeatComplaintCustomers(orgId)

  const areaOptions = useMemo(() => [...new Set((rows ?? []).map((r) => r.addresses?.area).filter((a): a is string => !!a))], [rows]);

  // Quick-filter chips (design line 955-961): "All open / Overdue / AMC /
  // Warranty / Unassigned" operate client-side on whatever the advanced
  // filters above already fetched — same pattern service.ts already uses for
  // area/date/technician (fields that can't be expressed as a single
  // PostgREST .eq()). Counts are real, derived from the fetched rows; no
  // "avg resolution" style stat is shown because there's no completed-at
  // field to compute it from.
  const allRows = useMemo(() => rows ?? [], [rows])
  const now = Date.now()
  const openCount = allRows.filter((r) => r.status !== "completed" && r.status !== "cancelled").length
  const overdueCount = allRows.filter((r) => isOverdueRow(r, now)).length

  const visibleRows = useMemo(() => {
    switch (quickFilter) {
      case "all":
        // The default "hide finished/cancelled noise" view — but an explicit
        // Status filter (e.g. "Completed") is the admin deliberately asking
        // to see exactly that status, so it must not be silently re-excluded
        // by this same-named "all" quick filter still being selected.
        return status ? allRows : allRows.filter((r) => r.status !== "completed" && r.status !== "cancelled")
      case "overdue":
        return allRows.filter((r) => isOverdueRow(r, now))
      case "amc":
        return allRows.filter((r) => r.type === "amc")
      case "warranty":
        return allRows.filter((r) => r.type === "warranty")
      case "unassigned":
        return allRows.filter((r) => isUnassignedRow(r))
      default:
        return allRows
    }
  }, [allRows, quickFilter, now, status])

  const hasAdvancedFilters = status || priority || type || technicianId || date || area

  return (
    <div className="space-y-4 pt-2">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold text-text">{t("nav.service")}</h1>
          <p className="text-sm font-medium text-text-muted">
            {isLoading ? t("service.subtitle") : t("service.stats", { open: openCount, overdue: overdueCount })}
          </p>
        </div>
        <div className="flex items-center gap-2.5">
          <div className="flex gap-[3px] rounded-full border border-border bg-surface p-1">
            <button
              type="button"
              onClick={() => setView("table")}
              aria-pressed={view === "table"}
              title={t("service.view.table")}
              className={cn(
                "flex items-center gap-1.5 rounded-full px-3.5 py-[7px] text-xs font-semibold transition-colors",
                view === "table" ? "bg-ink text-white" : "text-text-muted"
              )}
            >
              <Table2 className="size-3.5" /> {t("service.view.table")}
            </button>
            <button
              type="button"
              onClick={() => setView("kanban")}
              aria-pressed={view === "kanban"}
              title={t("service.view.kanban")}
              className={cn(
                "flex items-center gap-1.5 rounded-full px-3.5 py-[7px] text-xs font-semibold transition-colors",
                view === "kanban" ? "bg-ink text-white" : "text-text-muted"
              )}
            >
              <LayoutGrid className="size-3.5" /> {t("service.view.kanban")}
            </button>
          </div>
          <button
            type="button"
            onClick={() => navigate("/admin/service/appointments")}
            className="flex items-center gap-2 rounded-full border border-border bg-surface px-4 py-2.5 text-sm font-bold text-text"
          >
            <CalendarClock className="size-4" />
            {t("service.appointments.title")}
          </button>
          <Button onClick={() => navigate("/admin/service/new")}>
            <Plus className="size-3.5" />
            {t("service.newComplaint.title")}
          </Button>
        </div>
      </div>

      <div className="flex flex-wrap gap-2.5">
        <QuickFilterChip active={quickFilter === "all"} onClick={() => setQuickFilter("all")}>
          {t("service.quickFilters.allOpen")} · {openCount}
        </QuickFilterChip>
        <button
          type="button"
          onClick={() => setQuickFilter(quickFilter === "overdue" ? "all" : "overdue")}
          className={cn(
            "inline-flex items-center gap-1.5 rounded-full bg-[#FCEAEA] px-[15px] py-2 text-xs font-semibold text-danger",
            quickFilter === "overdue" ? "outline outline-2 outline-danger" : ""
          )}
        >
          <span className="size-1.5 rounded-full bg-danger" />
          {t("service.quickFilters.overdue")} · {overdueCount}
        </button>
        <QuickFilterChip active={quickFilter === "amc"} onClick={() => setQuickFilter(quickFilter === "amc" ? "all" : "amc")}>
          {t("service.quickFilters.amc")}
        </QuickFilterChip>
        <QuickFilterChip active={quickFilter === "warranty"} onClick={() => setQuickFilter(quickFilter === "warranty" ? "all" : "warranty")}>
          {t("service.quickFilters.warranty")}
        </QuickFilterChip>
        <QuickFilterChip active={quickFilter === "unassigned"} onClick={() => setQuickFilter(quickFilter === "unassigned" ? "all" : "unassigned")}>
          {t("service.quickFilters.unassigned")}
        </QuickFilterChip>
      </div>

      <Card size="sm" className="flex-row flex-wrap items-center gap-2">
        <FilterSelect label={t("service.filters.status")} value={status} onChange={setStatus} options={STATUS_OPTIONS.map((s) => ({ value: s, label: t(`service.status.${s}`) }))} />
        <FilterSelect label={t("service.filters.priority")} value={priority} onChange={setPriority} options={PRIORITY_OPTIONS.map((p) => ({ value: p, label: t(`service.priority.${p}`) }))} />
        <FilterSelect label={t("service.filters.type")} value={type} onChange={setType} options={TYPE_OPTIONS.map((tp) => ({ value: tp, label: t(`service.type.${tp}`) }))} />
        <FilterSelect
          label={t("service.filters.technician")}
          value={technicianId}
          onChange={setTechnicianId}
          options={(technicians ?? []).map((tc) => ({ value: tc.id, label: tc.full_name }))}
        />
        <FilterSelect label={t("service.filters.area")} value={area} onChange={setArea} options={areaOptions.map((a) => ({ value: a, label: a }))} />
        <div className="space-y-1">
          <label className="block text-xs font-medium text-text-muted">{t("service.filters.date")}</label>
          <DatePicker value={date} onChange={setDate} className="h-9 w-36" />
        </div>
        {hasAdvancedFilters ? (
          <Button
            size="sm"
            variant="ghost"
            onClick={() => {
              setStatus(""); setPriority(""); setType(""); setTechnicianId(""); setDate(""); setArea("")
            }}
          >
            {t("service.filters.clear")}
          </Button>
        ) : null}
      </Card>

      {view === "table" ? (
        <TicketsTable
          rows={visibleRows}
          loading={isLoading}
          error={isError ? t("service.loadFailed") : null}
          onRetry={() => refetch()}
          onRowClick={(r) => navigate(`/admin/service/${r.id}`)}
          repeatCustomers={repeatCustomers}
        />
      ) : (
        <TicketsKanban
          rows={visibleRows}
          loading={isLoading}
          error={isError ? t("service.loadFailed") : null}
          onRetry={() => refetch()}
          onCardClick={(r) => navigate(`/admin/service/${r.id}`)}
          repeatCustomers={repeatCustomers}
        />
      )}
    </div>
  )
}

function QuickFilterChip({ active, onClick, children }: { active: boolean; onClick: () => void; children: ReactNode }) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={cn(
        "rounded-full border border-border px-[15px] py-2 text-xs font-bold transition-colors",
        active ? "bg-ink text-white" : "bg-surface text-ink"
      )}
    >
      {children}
    </button>
  )
}

// Bespoke grid table (not the shared <DataTable>) — the design's column
// widths are fractional CSS-grid tracks (design line 964), which a real
// <table> element can't express; this mirrors the grid-div pattern already
// used for OwnerDashboard's "Recent Tickets" panel.
function TicketsTable({
  rows,
  loading,
  error,
  onRetry,
  onRowClick,
  repeatCustomers,
}: {
  rows: TicketListItem[]
  loading: boolean
  error: string | null
  onRetry: () => void
  onRowClick: (row: TicketListItem) => void
  repeatCustomers?: Set<string>
}) {
  const { t } = useTranslation()

  const headers = [
    t("service.table.ticket"),
    t("service.table.customer"),
    t("service.table.complaint"),
    t("service.table.type"),
    t("service.table.priority"),
    t("service.table.technician"),
    t("service.table.appointment"),
    t("service.table.sla"),
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
          <p className="text-sm text-text-muted">{t("service.empty")}</p>
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
            <div className="flex items-center gap-1.5">
              <span className="text-xs font-bold text-ink">#{r.id.slice(0, 8)}</span>
              {repeatCustomers?.has(r.customer_id) ? (
                <Repeat className="size-3.5 text-warning" aria-label={t("service.table.repeatComplaint")} />
              ) : null}
            </div>
            <div className="leading-tight">
              <div className="text-[13px] font-semibold text-text">{r.customers?.name ?? "—"}</div>
              <div className="text-[11px] font-medium text-text-muted">
                {[r.addresses?.area, r.products?.name].filter(Boolean).join(" · ") || "—"}
              </div>
            </div>
            <span className="truncate text-[13px] font-medium text-text">{r.name_of_complaint || "—"}</span>
            <span>
              <TicketTypeBadge type={r.type} />
            </span>
            <PriorityText priority={r.priority} />
            <span className="text-[13px] font-medium text-text">
              {r.appointments[0]?.technicians?.profiles?.full_name ?? t("service.table.unassigned")}
            </span>
            <span className="text-xs font-medium text-text">
              {r.appointments[0]?.mode === "always"
                ? t("service.appointment.always")
                : r.appointments[0]?.scheduled_at
                  ? new Date(r.appointments[0].scheduled_at).toLocaleString()
                  : "—"}
            </span>
            <SlaCountdown slaDueAt={r.sla_due_at} status={r.status} />
          </div>
        ))
      )}
    </div>
  )
}

function FilterSelect({
  label,
  value,
  onChange,
  options,
}: {
  label: string
  value: string
  onChange: (v: string) => void
  options: { value: string; label: string }[]
}) {
  const { t } = useTranslation()
  return (
    <div className="space-y-1">
      <label className="block text-xs font-medium text-text-muted">{label}</label>
      <select
        value={value}
        onChange={(e) => onChange(e.target.value)}
        className="h-9 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
      >
        <option value="">{t("service.filters.all")}</option>
        {options.map((o) => (
          <option key={o.value} value={o.value}>
            {o.label}
          </option>
        ))}
      </select>
    </div>
  )
}
