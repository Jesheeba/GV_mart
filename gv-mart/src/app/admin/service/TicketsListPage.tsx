import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { LayoutGrid, Plus, Repeat, Table2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { useProfile } from "@/hooks/useProfile"
import { useRepeatComplaintCustomers, useTechnicians, useTicketsList } from "@/hooks/useService"
import type { TicketListItem } from "@/services/service"
import { SlaCountdown } from "./SlaCountdown"
import { PriorityBadge, TicketTypeBadge } from "./TicketBadges"
import { TicketsKanban } from "./TicketsKanban"

const STATUS_OPTIONS = ["open", "assigned", "in_progress", "completed", "cancelled"] as const
const PRIORITY_OPTIONS = ["very_urgent", "urgent", "normal"] as const
const TYPE_OPTIONS = ["paid", "warranty", "amc", "installation"] as const

export function TicketsListPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const [view, setView] = useState<"table" | "kanban">("table")
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

  const columns: DataTableColumn<TicketListItem>[] = [
    {
      key: "ticket",
      header: t("service.table.ticket"),
      render: (r) => (
        <div className="flex items-center gap-1.5">
          <span className="font-medium text-text">#{r.id.slice(0, 8)}</span>
          {repeatCustomers?.has(r.customer_id) ? (
            <Repeat className="size-3.5 text-warning" aria-label={t("service.table.repeatComplaint")} />
          ) : null}
        </div>
      ),
    },
    {
      key: "customer",
      header: t("service.table.customer"),
      render: (r) => (
        <div>
          <div className="text-text">{r.customers?.name ?? "—"}</div>
          <div className="text-xs text-text-muted">{r.customers?.mobile}</div>
        </div>
      ),
    },
    {
      key: "product",
      header: t("service.table.product"),
      render: (r) => (
        <div className="text-xs text-text-muted">
          {[r.products?.name, r.brands?.name, r.models?.name].filter(Boolean).join(" · ") || "—"}
        </div>
      ),
    },
    { key: "complaint", header: t("service.table.complaint"), render: (r) => r.name_of_complaint || "—" },
    { key: "type", header: t("service.table.type"), render: (r) => <TicketTypeBadge type={r.type} /> },
    { key: "priority", header: t("service.table.priority"), render: (r) => <PriorityBadge priority={r.priority} /> },
    {
      key: "technician",
      header: t("service.table.technician"),
      render: (r) => r.appointments[0]?.technicians?.profiles?.full_name ?? t("service.table.unassigned"),
    },
    {
      key: "appointment",
      header: t("service.table.appointment"),
      render: (r) =>
        r.appointments[0]?.mode === "always"
          ? t("service.appointment.always")
          : r.appointments[0]?.scheduled_at
            ? new Date(r.appointments[0].scheduled_at).toLocaleString()
            : "—",
    },
    { key: "sla", header: t("service.table.sla"), render: (r) => <SlaCountdown slaDueAt={r.sla_due_at} status={r.status} /> },
  ]

  return (
    <div className="space-y-4 pt-2">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold text-text">{t("nav.service")}</h1>
          <p className="text-sm text-text-muted">{t("service.subtitle")}</p>
        </div>
        <div className="flex items-center gap-2">
          <div className="flex gap-1 rounded-full bg-surface-alt p-1">
            <button
              type="button"
              onClick={() => setView("table")}
              aria-pressed={view === "table"}
              title={t("service.view.table")}
              className={`flex items-center gap-1.5 rounded-full px-3 py-1.5 text-sm font-medium transition-colors ${
                view === "table" ? "bg-ink text-white" : "text-text-muted"
              }`}
            >
              <Table2 className="size-3.5" /> {t("service.view.table")}
            </button>
            <button
              type="button"
              onClick={() => setView("kanban")}
              aria-pressed={view === "kanban"}
              title={t("service.view.kanban")}
              className={`flex items-center gap-1.5 rounded-full px-3 py-1.5 text-sm font-medium transition-colors ${
                view === "kanban" ? "bg-ink text-white" : "text-text-muted"
              }`}
            >
              <LayoutGrid className="size-3.5" /> {t("service.view.kanban")}
            </button>
          </div>
          <Button onClick={() => navigate("/admin/service/new")}>
            <Plus className="size-3.5" />
            {t("service.newComplaint.title")}
          </Button>
        </div>
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
          <input
            type="date"
            value={date}
            onChange={(e) => setDate(e.target.value)}
            className="h-9 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
          />
        </div>
        {status || priority || type || technicianId || date || area ? (
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
        <DataTable
          columns={columns}
          rows={rows ?? []}
          rowKey={(r) => r.id}
          loading={isLoading}
          error={isError ? t("service.loadFailed") : null}
          onRetry={() => refetch()}
          emptyMessage={t("service.empty")}
          onRowClick={(r) => navigate(`/admin/service/${r.id}`)}
        />
      ) : (
        <TicketsKanban
          rows={rows ?? []}
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
