import { useMemo, useState, type ReactNode } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { CalendarCheck2, Inbox, Loader2, MapPin, PackageOpen, Plus, Star, TriangleAlert, UserPlus } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Skeleton } from "@/components/ui/skeleton"
import { useProfile } from "@/hooks/useProfile"
import { useCreateTechnician, useEligibleTechnicianProfiles, useTechniciansList } from "@/hooks/useTechniciansAdmin"
import type { TechnicianListItem } from "@/services/techniciansAdmin"
import { defaultPeriodValue, periodToRange, type PeriodValue } from "@/services/reports"
import { cn } from "@/lib/utils"
import { PeriodFilter } from "@/app/admin/reports/PeriodFilter"

// Matches the design's 6-column table grid (design-template-decoded.html
// line 1139): Technician / Phone / Status / Jobs / Revenue / Rating. The
// design's 7th "KPI" column (a fabricated composite score like "94") has no
// real backing field anywhere in this schema. The closest real per-technician
// metric is reports.ts's getPerformanceReport, but that's a date-ranged
// report gated to master-only (/admin/reports) — a different role scope than
// this ops-scoped list — so it isn't a clean drop-in here; the column is
// omitted rather than fabricated. `is_active` is folded into the Status cell
// instead (an inactive technician always shows "Inactive", regardless of
// duty state) so that real field isn't lost from the view.
const TABLE_GRID_COLS = "grid-cols-[1.6fr_1.2fr_1fr_0.9fr_1fr_0.8fr]"

/**
 * ADM-14. Rows navigate to a per-technician detail page
 * (TechnicianDetailPage.tsx) — zone/skills/active editing, history, current
 * job, attendance and rewards all live there now.
 *
 * "Add Technician" cannot provision a brand-new login from this browser-only
 * app (needs the service_role key — see services/techniciansAdmin.ts file
 * header), so it links an existing login that has no technicians row yet
 * instead (createTechnician / listEligibleTechnicianProfiles).
 */
export function TechniciansListPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  // Owner request 2026-07-29: the KPI row (jobs/revenue) used to always mean
  // "today" with no way to look at a past month/year — now driven by the
  // same PeriodFilter every dashboard/report uses. Defaults to the current
  // month, whose bounds include today, so first-load output is unchanged.
  const [period, setPeriod] = useState<PeriodValue>(defaultPeriodValue())
  const range = periodToRange(period)
  const { data: technicians, isLoading, isError, refetch } = useTechniciansList(orgId, range)

  const [search, setSearch] = useState("")
  const [dutyFilter, setDutyFilter] = useState<"all" | "on" | "off">("all")
  const [showAddPanel, setShowAddPanel] = useState(false)

  const allRows = useMemo(() => technicians ?? [], [technicians])

  // KPI row + header subtitle counts are summed straight from the real
  // per-technician rows already fetched above — nothing fabricated. The
  // design's "First-time Fix 87%" card is dropped: no field in this schema
  // (service_visits, ratings, appointments…) backs a first-time-fix rate.
  // Org-wide avg rating is the simple mean of each technician's own average
  // (listTechnicians doesn't return per-technician review counts, so it
  // can't be weighted by review volume).
  const kpis = useMemo(() => {
    const onDuty = allRows.filter((r) => r.is_on_duty).length
    const totalJobs = allRows.reduce((sum, r) => sum + r.periodJobCount, 0)
    const totalRevenue = allRows.reduce((sum, r) => sum + r.periodRevenue, 0)
    const rated = allRows.filter((r) => r.avgRating != null)
    const avgRating =
      rated.length > 0 ? Math.round((rated.reduce((sum, r) => sum + (r.avgRating ?? 0), 0) / rated.length) * 10) / 10 : null
    return { total: allRows.length, onDuty, totalJobs, totalRevenue, avgRating }
  }, [allRows])

  const filtered = useMemo(() => {
    let rows = allRows
    if (dutyFilter === "on") rows = rows.filter((r) => r.is_on_duty)
    if (dutyFilter === "off") rows = rows.filter((r) => !r.is_on_duty)
    const term = search.trim().toLowerCase()
    if (term) {
      rows = rows.filter(
        (r) => r.profiles?.full_name.toLowerCase().includes(term) || r.profiles?.phone?.toLowerCase().includes(term)
      )
    }
    return rows
  }, [allRows, dutyFilter, search])

  return (
    <div className="space-y-4 pt-2">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold text-text">{t("technicians.list.title")}</h1>
          <p className="text-sm font-medium text-text-muted">
            {isLoading
              ? t("technicians.list.subtitle")
              : t("technicians.list.stats", { total: kpis.total, onDuty: kpis.onDuty, jobs: kpis.totalJobs })}
          </p>
        </div>
        <div className="flex items-center gap-2">
          <button
            type="button"
            onClick={() => navigate("/admin/technicians/map")}
            className="flex items-center gap-2 rounded-full border border-[#DAD5CC] bg-surface px-4 py-2.5 text-sm font-bold text-text"
          >
            <MapPin className="size-4" />
            {t("technicians.list.viewMap")}
          </button>
          <button
            type="button"
            onClick={() => navigate("/admin/technicians/attendance")}
            className="flex items-center gap-2 rounded-full border border-[#DAD5CC] bg-surface px-4 py-2.5 text-sm font-bold text-text"
          >
            <CalendarCheck2 className="size-4" />
            {t("technicians.list.viewAttendance")}
          </button>
          <button
            type="button"
            onClick={() => navigate("/admin/technicians/spares")}
            className="flex items-center gap-2 rounded-full border border-[#DAD5CC] bg-surface px-4 py-2.5 text-sm font-bold text-text"
          >
            <PackageOpen className="size-4" />
            {t("technicians.list.viewSpares")}
          </button>
          <Button onClick={() => setShowAddPanel((v) => !v)}>
            <Plus className="size-3.5" />
            {t("technicians.list.addTechnician")}
          </Button>
        </div>
      </div>

      <div className="rounded-card border border-border bg-surface p-4 shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
        <PeriodFilter value={period} onChange={setPeriod} />
      </div>

      <div className="grid grid-cols-1 gap-4.5 sm:grid-cols-2 lg:grid-cols-4">
        <TechKpiCard
          label={t("technicians.list.kpiOnDuty")}
          value={
            isLoading ? (
              "—"
            ) : (
              <>
                {kpis.onDuty} <span className="text-sm font-semibold text-text-muted">/ {kpis.total}</span>
              </>
            )
          }
        />
        <TechKpiCard label={t("technicians.list.kpiJobsPeriod")} value={isLoading ? "—" : kpis.totalJobs} />
        <TechKpiCard
          label={t("technicians.list.kpiRevenuePeriod")}
          value={isLoading ? "—" : `₹${kpis.totalRevenue.toLocaleString("en-IN")}`}
        />
        <TechKpiCard
          label={t("technicians.list.avgRating")}
          value={
            isLoading ? (
              "—"
            ) : (
              <>
                {kpis.avgRating ?? "—"} {kpis.avgRating != null ? <span className="text-sm font-semibold text-accent">★</span> : null}
              </>
            )
          }
        />
      </div>

      <div className="flex flex-wrap items-center gap-3">
        <Input
          placeholder={t("technicians.list.searchPlaceholder")}
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          className="max-w-xs"
        />
        <div className="flex items-center gap-1.5">
          {(["all", "on", "off"] as const).map((f) => (
            <FilterChip key={f} active={dutyFilter === f} onClick={() => setDutyFilter(f)}>
              {t(`technicians.list.filter.${f}`)}
            </FilterChip>
          ))}
        </div>
      </div>

      {showAddPanel ? <AddTechnicianPanel orgId={orgId} onClose={() => setShowAddPanel(false)} /> : null}

      <TechniciansTable
        rows={filtered}
        loading={isLoading}
        error={isError ? t("technicians.list.loadFailed") : null}
        onRetry={() => refetch()}
        onRowClick={(row) => navigate(`/admin/technicians/${row.id}`)}
      />
    </div>
  )
}

/**
 * A brand-new login can't be provisioned from this browser-only app (needs
 * Supabase's service_role key), so "Add Technician" links an existing login
 * — one already created outside this app (e.g. via the Supabase dashboard)
 * with role="technician" but no technicians row yet — instead of creating one.
 */
function AddTechnicianPanel({ orgId, onClose }: { orgId: string | undefined; onClose: () => void }) {
  const { t } = useTranslation()
  const { data: eligible, isLoading } = useEligibleTechnicianProfiles(orgId)
  const createMut = useCreateTechnician()
  const [selectedProfileId, setSelectedProfileId] = useState("")

  function handleAdd() {
    if (!orgId || !selectedProfileId) return
    createMut.mutate({ orgId, profileId: selectedProfileId }, { onSuccess: () => onClose() })
  }

  return (
    <div className="rounded-subcard border border-border bg-surface p-4">
      <p className="mb-1 text-sm font-semibold text-text">{t("technicians.list.addTechnician")}</p>
      <p className="mb-3 text-xs text-text-muted">{t("technicians.list.addTechnicianHint")}</p>

      {isLoading ? (
        <Skeleton className="h-9 w-full" />
      ) : (eligible ?? []).length === 0 ? (
        <p className="rounded-xl border border-border bg-surface-alt px-3.5 py-2.5 text-xs text-text-muted">
          {t("technicians.list.noEligibleProfiles")}
        </p>
      ) : (
        <div className="flex flex-wrap items-center gap-2">
          <select
            value={selectedProfileId}
            onChange={(e) => setSelectedProfileId(e.target.value)}
            className="h-9 min-w-56 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
          >
            <option value="">{t("technicians.list.pickProfile")}</option>
            {(eligible ?? []).map((p) => (
              <option key={p.id} value={p.id}>
                {p.full_name} {p.phone ? `· ${p.phone}` : ""}
              </option>
            ))}
          </select>
          <Button size="sm" disabled={!selectedProfileId || createMut.isPending} onClick={handleAdd}>
            {createMut.isPending ? <Loader2 className="size-3.5 animate-spin" /> : <UserPlus className="size-3.5" />}
            {t("technicians.list.addTechnician")}
          </Button>
        </div>
      )}
      {createMut.isError ? (
        <p className="mt-3 rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{(createMut.error as Error).message}</p>
      ) : null}
      <div className="mt-3 flex justify-end">
        <Button size="sm" variant="ghost" onClick={onClose}>
          {t("common.cancel")}
        </Button>
      </div>
    </div>
  )
}

function TechKpiCard({ label, value }: { label: string; value: ReactNode }) {
  return (
    <div className="flex flex-col gap-3 rounded-card border border-border bg-surface px-5.5 py-5 shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
      <span className="text-[13px] font-semibold text-text-muted">{label}</span>
      <div className="text-[28px] font-extrabold tabular-nums leading-none tracking-[-0.02em] text-text">{value}</div>
    </div>
  )
}

function FilterChip({ active, onClick, children }: { active: boolean; onClick: () => void; children: ReactNode }) {
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

function initialsOf(name: string) {
  return name
    .split(" ")
    .map((p) => p[0])
    .filter(Boolean)
    .slice(0, 2)
    .join("")
    .toUpperCase()
}

const STATUS_TEXT_CLASS = {
  success: "text-success",
  danger: "text-danger",
  neutral: "text-text-muted",
} as const
const STATUS_DOT_CLASS = {
  success: "bg-success",
  danger: "bg-danger",
  neutral: "bg-text-muted",
} as const

// Bespoke grid table (not the shared <DataTable>) — the design's column
// widths are fractional CSS-grid tracks (design line 1139), which a real
// <table> element can't express; mirrors the grid-div pattern already used
// by TicketsListPage/SalesListPage.
function TechniciansTable({
  rows,
  loading,
  error,
  onRetry,
  onRowClick,
}: {
  rows: TechnicianListItem[]
  loading: boolean
  error: string | null
  onRetry: () => void
  onRowClick: (row: TechnicianListItem) => void
}) {
  const { t } = useTranslation()

  const headers = [
    t("technicians.list.table.technician"),
    t("technicians.list.table.phone"),
    t("technicians.list.status"),
    t("technicians.list.table.jobs"),
    t("technicians.list.table.revenue"),
    t("technicians.list.table.rating"),
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
          <div key={i} className={cn("grid items-center border-b border-[#F1EDE6] px-[22px] py-[14px]", TABLE_GRID_COLS)}>
            {headers.map((h) => (
              <Skeleton key={h} className="h-4 w-3/4 max-w-32" />
            ))}
          </div>
        ))
      ) : rows.length === 0 ? (
        <div className="flex flex-col items-center gap-2 py-12 text-center">
          <Inbox className="size-6 text-text-muted" />
          <p className="text-sm text-text-muted">{t("technicians.list.empty")}</p>
        </div>
      ) : (
        rows.map((r) => {
          const tone = !r.is_active ? "danger" : r.is_on_duty ? "success" : "neutral"
          const statusLabel = !r.is_active
            ? t("technicians.list.statusInactive")
            : r.is_on_duty
              ? t("technicians.list.onDuty")
              : t("technicians.list.offDuty")
          const name = r.profiles?.full_name ?? "—"

          return (
            <div
              key={r.id}
              onClick={() => onRowClick(r)}
              className={cn("grid cursor-pointer items-center border-b border-[#F1EDE6] px-[22px] py-[14px] last:border-b-0 hover:bg-[#FAF8F4]", TABLE_GRID_COLS)}
            >
              <div className="flex items-center gap-2.75">
                <span className="flex size-9 shrink-0 items-center justify-center rounded-[11px] bg-ink text-xs font-bold text-white">
                  {initialsOf(name)}
                </span>
                <span className="text-[13px] font-semibold text-text">{name}</span>
              </div>
              <span className="text-xs font-medium tabular-nums text-text-muted">{r.profiles?.phone ?? "—"}</span>
              <span className={cn("inline-flex items-center gap-1.5 text-xs font-semibold", STATUS_TEXT_CLASS[tone])}>
                <span className={cn("size-1.75 shrink-0 rounded-full", STATUS_DOT_CLASS[tone])} />
                {statusLabel}
              </span>
              <span className="text-[13px] font-semibold tabular-nums text-text">{r.periodJobCount}</span>
              <span className="text-[13px] font-bold tabular-nums text-text">₹{r.periodRevenue.toLocaleString("en-IN")}</span>
              <span className="inline-flex items-center gap-1 text-[13px] font-semibold text-text">
                {r.avgRating != null ? (
                  <>
                    {r.avgRating} <Star className="size-3 fill-accent text-accent" />
                  </>
                ) : (
                  "—"
                )}
              </span>
            </div>
          )
        })
      )}
    </div>
  )
}
