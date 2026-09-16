import { useMemo, useState, type ReactNode } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { CalendarClock, Inbox, LayoutGrid, Plus, Repeat, Table2, TriangleAlert } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Skeleton } from "@/components/ui/skeleton"
import { useProfile } from "@/hooks/useProfile"
import { useRepeatComplaintCustomers, useTicketsList } from "@/hooks/useService"
import { isUnassignedRow, type TicketFiltersInput, type TicketListItem } from "@/services/service"
import { isTicketOverdue } from "@/lib/ticketOverdue"
import { cn } from "@/lib/utils"
import { SlaCountdown } from "./SlaCountdown"
import { ChannelBadge, PriorityText, TicketTypeBadge } from "./TicketBadges"
import { TicketsKanban } from "./TicketsKanban"

// Matches the design's 8-column table grid (design-template-decoded.html line 964):
// Ticket / Customer / Complaint / Type / Prio / Technician / Appointment / SLA.
const TABLE_GRID_COLS =
  "grid-cols-[minmax(90px,0.95fr)_minmax(150px,1.5fr)_minmax(140px,1.5fr)_minmax(70px,0.8fr)_minmax(70px,0.6fr)_minmax(110px,1.1fr)_minmax(120px,1.1fr)_minmax(100px,1fr)]"

function isMissingProductRow(r: TicketListItem) {
  return !r.product_id && !r.unlisted_product_name
}

// Everything this page fetches gets partitioned into Open/Overdue/Completed/
// Cancelled client-side (see visibleRows below), so the server-side status
// filter is never used here — that keeps the chip counts accurate no matter
// which tab is active, instead of only being accurate for whichever status
// the last request happened to narrow to.
const NO_SERVER_FILTERS: TicketFiltersInput = {}

type PrimaryFilter = "open" | "overdue" | "completed" | "cancelled"

export function TicketsListPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const [view, setView] = useState<"table" | "kanban">("table")
  const [primaryFilter, setPrimaryFilter] = useState<PrimaryFilter>("open")
  // Independent toggles — AND with the primary filter instead of being
  // mutually exclusive with it, so "overdue tickets with no technician" is
  // still expressible.
  const [unassignedOnly, setUnassignedOnly] = useState(false)
  const [missingProductOnly, setMissingProductOnly] = useState(false)

  const { data: rows, isLoading, isError, refetch } = useTicketsList(orgId, NO_SERVER_FILTERS)
  const { data: repeatCustomers } = useRepeatComplaintCustomers(orgId)

  const allRows = useMemo(() => rows ?? [], [rows])
  const now = Date.now()

  const openCount = allRows.filter((r) => r.status !== "completed" && r.status !== "cancelled").length
  const overdueCount = allRows.filter((r) => isTicketOverdue(r, now)).length
  const completedCount = allRows.filter((r) => r.status === "completed").length
  const cancelledCount = allRows.filter((r) => r.status === "cancelled").length
  const unassignedCount = allRows.filter(isUnassignedRow).length
  const missingProductCount = allRows.filter(isMissingProductRow).length

  const visibleRows = useMemo(() => {
    let out = allRows
    if (primaryFilter === "open" || primaryFilter === "overdue") {
      out = out.filter((r) => r.status !== "completed" && r.status !== "cancelled")
      if (primaryFilter === "overdue") out = out.filter((r) => isTicketOverdue(r, now))
    } else {
      out = out.filter((r) => r.status === primaryFilter)
    }
    if (unassignedOnly) out = out.filter(isUnassignedRow)
    if (missingProductOnly) out = out.filter(isMissingProductRow)
    return out
  }, [allRows, primaryFilter, unassignedOnly, missingProductOnly, now])

  const hasActiveFilters = primaryFilter !== "open" || unassignedOnly || missingProductOnly
  function clearAllFilters() {
    setPrimaryFilter("open")
    setUnassignedOnly(false)
    setMissingProductOnly(false)
  }

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

      <div className="flex flex-wrap items-center gap-2.5">
        <QuickFilterChip active={primaryFilter === "open"} onClick={() => setPrimaryFilter("open")}>
          {t("service.quickFilters.allOpen")} · {openCount}
        </QuickFilterChip>
        <button
          type="button"
          onClick={() => setPrimaryFilter("overdue")}
          className={cn(
            "inline-flex items-center gap-1.5 rounded-full bg-[#FCEAEA] px-[15px] py-2 text-xs font-semibold text-danger",
            primaryFilter === "overdue" ? "outline outline-2 outline-danger" : ""
          )}
        >
          <span className="size-1.5 rounded-full bg-danger" />
          {t("service.quickFilters.overdue")} · {overdueCount}
        </button>
        <QuickFilterChip active={primaryFilter === "completed"} onClick={() => setPrimaryFilter("completed")}>
          {t("service.status.completed")} · {completedCount}
        </QuickFilterChip>
        <QuickFilterChip active={primaryFilter === "cancelled"} onClick={() => setPrimaryFilter("cancelled")}>
          {t("service.status.cancelled")} · {cancelledCount}
        </QuickFilterChip>

        <span className="mx-0.5 h-5 w-px bg-border" aria-hidden="true" />

        <QuickFilterChip active={unassignedOnly} onClick={() => setUnassignedOnly((v) => !v)}>
          {t("service.quickFilters.unassigned")} · {unassignedCount}
        </QuickFilterChip>
        <QuickFilterChip active={missingProductOnly} onClick={() => setMissingProductOnly((v) => !v)}>
          {t("service.quickFilters.missingProduct")} · {missingProductCount}
        </QuickFilterChip>

        {hasActiveFilters ? (
          <Button size="sm" variant="ghost" onClick={clearAllFilters}>
            {t("service.filters.clear")}
          </Button>
        ) : null}
      </div>

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
                {[r.addresses?.area, r.products?.name ?? r.unlisted_product_name].filter(Boolean).join(" · ") || "—"}
              </div>
            </div>
            <span className="truncate text-[13px] font-medium text-text">{r.name_of_complaint || "—"}</span>
            <span className="flex flex-wrap items-center gap-1">
              <TicketTypeBadge type={r.type} />
              <ChannelBadge channel={r.channel} />
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
