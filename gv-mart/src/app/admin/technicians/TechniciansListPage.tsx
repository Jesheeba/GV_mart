import { useMemo, useState, type ReactNode } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { Camera, CalendarCheck2, ChevronDown, Inbox, Loader2, MapPin, PackageOpen, Plus, Star, TriangleAlert, UserPlus } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Skeleton } from "@/components/ui/skeleton"
import { useProfile } from "@/hooks/useProfile"
import {
  useCreateTechnician,
  useCreateTechnicianAccount,
  useEligibleTechnicianProfiles,
  useTechniciansList,
} from "@/hooks/useTechniciansAdmin"
import { TECHNICIAN_SKILL_OPTIONS } from "@/services/techniciansAdmin"
import type { TechnicianListItem } from "@/services/techniciansAdmin"
import { defaultPeriodValue, periodToRange, type PeriodValue } from "@/services/reports"
import { cn } from "@/lib/utils"
import { fileToDataUrl } from "@/lib/offline/capture"
import { PeriodFilter } from "@/app/admin/reports/PeriodFilter"
import { PasswordRevealDialog } from "@/app/admin/technicians/PasswordRevealDialog"

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
const TABLE_GRID_COLS =
  "grid-cols-[minmax(160px,1.6fr)_minmax(120px,1.2fr)_minmax(90px,1fr)_minmax(70px,0.9fr)_minmax(90px,1fr)_minmax(80px,0.8fr)]"

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
  const [revealed, setRevealed] = useState<{ password: string; phone: string } | null>(null)

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

      {showAddPanel ? (
        <AddTechnicianPanel orgId={orgId} onClose={() => setShowAddPanel(false)} onCreated={(r) => setRevealed(r)} />
      ) : null}

      <TechniciansTable
        rows={filtered}
        loading={isLoading}
        error={isError ? t("technicians.list.loadFailed") : null}
        onRetry={() => refetch()}
        onRowClick={(row) => navigate(`/admin/technicians/${row.id}`)}
        onAddClick={() => setShowAddPanel(true)}
      />

      <PasswordRevealDialog password={revealed?.password ?? null} phone={revealed?.phone} onClose={() => setRevealed(null)} />
    </div>
  )
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
// Indian mobile: 10 digits, starts 6-9 — same rule as lib/validation/technician.ts.
const MOBILE_REGEX = /^[6-9]\d{9}$/

/**
 * Primary path: a real, immediately-usable login created server-side by the
 * admin-create-technician Edge Function (holds the service_role key this
 * browser app never ships — see that function's file header). Secondary
 * path, collapsed by default: link a login that already exists outside this
 * app (e.g. created directly via the Supabase dashboard) but has no
 * technicians row yet — kept for that edge case rather than removed.
 */
function AddTechnicianPanel({
  orgId,
  onClose,
  onCreated,
}: {
  orgId: string | undefined
  onClose: () => void
  onCreated: (result: { password: string; phone: string }) => void
}) {
  const { t } = useTranslation()
  const createAccountMut = useCreateTechnicianAccount()
  const [showLinkExisting, setShowLinkExisting] = useState(false)

  const [fullName, setFullName] = useState("")
  const [phone, setPhone] = useState("")
  const [email, setEmail] = useState("")
  const [address, setAddress] = useState("")
  const [city, setCity] = useState("")
  const [state, setState] = useState("")
  const [pincode, setPincode] = useState("")
  const [zone, setZone] = useState("")
  const [skills, setSkills] = useState<string[]>([])
  const [dailyCapacity, setDailyCapacity] = useState("480")
  const [photoUrl, setPhotoUrl] = useState<string | null>(null)
  const [photoBusy, setPhotoBusy] = useState(false)

  function toggleSkill(skill: string) {
    setSkills((prev) => (prev.includes(skill) ? prev.filter((s) => s !== skill) : [...prev, skill]))
  }

  async function handlePhotoChange(file: File | undefined) {
    if (!file) return
    setPhotoBusy(true)
    try {
      setPhotoUrl(await fileToDataUrl(file))
    } finally {
      setPhotoBusy(false)
    }
  }

  const capacityValid = /^\d+$/.test(dailyCapacity.trim()) && Number(dailyCapacity) > 0
  const phoneValid = MOBILE_REGEX.test(phone.trim())
  const formValid = fullName.trim().length > 0 && phoneValid && EMAIL_RE.test(email.trim()) && capacityValid

  function handleCreate() {
    if (!formValid) return
    createAccountMut.mutate(
      {
        fullName: fullName.trim(),
        phone: phone.trim(),
        email: email.trim(),
        address: address.trim() || null,
        city: city.trim() || null,
        state: state.trim() || null,
        pincode: pincode.trim() || null,
        skills,
        zone: zone.trim() || null,
        dailyCapacityMinutes: Number(dailyCapacity),
        photoUrl,
      },
      {
        onSuccess: (result) => {
          onCreated({ password: result.password, phone: phone.trim() })
          onClose()
        },
      }
    )
  }

  return (
    <div className="rounded-subcard border border-border bg-surface p-4">
      <p className="mb-1 text-sm font-semibold text-text">{t("technicians.list.addTechnician")}</p>
      <p className="mb-3 text-xs text-text-muted">{t("technicians.list.createHint")}</p>

      <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
        <div className="space-y-1">
          <Label htmlFor="new-tech-name">{t("technicians.list.fields.fullName")}</Label>
          <Input id="new-tech-name" value={fullName} onChange={(e) => setFullName(e.target.value)} />
        </div>
        <div className="space-y-1">
          <Label htmlFor="new-tech-phone">{t("technicians.detail.fields.phone")}</Label>
          <Input
            id="new-tech-phone"
            type="tel"
            value={phone}
            onChange={(e) => setPhone(e.target.value)}
            aria-invalid={!!phone && !phoneValid}
          />
          {phone && !phoneValid ? <p className="text-xs text-danger">{t("technician.errors.mobileInvalid")}</p> : null}
        </div>
        <div className="space-y-1">
          <Label htmlFor="new-tech-email">{t("technicians.list.fields.email")}</Label>
          <Input id="new-tech-email" type="email" value={email} onChange={(e) => setEmail(e.target.value)} aria-invalid={!!email && !EMAIL_RE.test(email)} />
        </div>
        <div className="space-y-1 sm:col-span-3">
          <Label htmlFor="new-tech-address">{t("technicians.detail.fields.address")}</Label>
          <Input id="new-tech-address" value={address} onChange={(e) => setAddress(e.target.value)} />
        </div>
        <div className="space-y-1">
          <Label htmlFor="new-tech-city">{t("technicians.detail.fields.city")}</Label>
          <Input id="new-tech-city" value={city} onChange={(e) => setCity(e.target.value)} />
        </div>
        <div className="space-y-1">
          <Label htmlFor="new-tech-state">{t("technicians.detail.fields.state")}</Label>
          <Input id="new-tech-state" value={state} onChange={(e) => setState(e.target.value)} />
        </div>
        <div className="space-y-1">
          <Label htmlFor="new-tech-pincode">{t("technicians.detail.fields.pincode")}</Label>
          <Input id="new-tech-pincode" value={pincode} onChange={(e) => setPincode(e.target.value)} />
        </div>
        <div className="space-y-1">
          <Label htmlFor="new-tech-zone">{t("technicians.list.zone")}</Label>
          <Input id="new-tech-zone" value={zone} onChange={(e) => setZone(e.target.value)} placeholder={t("technicians.list.zoneInformationalHint")} />
        </div>
        <div className="space-y-1">
          <Label htmlFor="new-tech-capacity">{t("technicians.list.dailyCapacity")}</Label>
          <Input
            id="new-tech-capacity"
            type="number"
            min={1}
            step={1}
            value={dailyCapacity}
            onChange={(e) => setDailyCapacity(e.target.value)}
            aria-invalid={!capacityValid}
          />
        </div>
        <div className="space-y-1">
          <Label>{t("technicians.list.fields.photo")}</Label>
          <label className="flex h-11 cursor-pointer items-center justify-center gap-2 rounded-xl border border-dashed border-border bg-surface-alt text-xs font-semibold text-text-muted hover:bg-surface">
            {photoBusy ? (
              <Loader2 className="size-3.5 animate-spin" />
            ) : photoUrl ? (
              <img src={photoUrl} alt="" className="size-8 rounded-full object-cover" />
            ) : (
              <Camera className="size-3.5" />
            )}
            {photoUrl ? t("technicians.list.fields.photoChange") : t("technicians.list.fields.photoUpload")}
            <input type="file" accept="image/*" className="hidden" onChange={(e) => handlePhotoChange(e.target.files?.[0])} />
          </label>
        </div>
        <div className="space-y-1 sm:col-span-3">
          <Label>{t("technicians.list.skills")}</Label>
          <div className="flex flex-wrap gap-1.5">
            {TECHNICIAN_SKILL_OPTIONS.map((skill) => (
              <Button key={skill} type="button" size="xs" variant={skills.includes(skill) ? "default" : "outline"} onClick={() => toggleSkill(skill)}>
                {t(`technicians.list.skillOptions.${skill}`)}
              </Button>
            ))}
          </div>
        </div>
      </div>

      {createAccountMut.isError ? (
        <p className="mt-3 rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{(createAccountMut.error as Error).message}</p>
      ) : null}

      <div className="mt-3 flex flex-wrap items-center justify-between gap-2">
        <Button type="button" variant="ghost" size="sm" onClick={() => setShowLinkExisting((v) => !v)}>
          <ChevronDown className={cn("size-3.5 transition-transform", showLinkExisting && "rotate-180")} />
          {t("technicians.list.linkExistingToggle")}
        </Button>
        <div className="flex gap-2">
          <Button size="sm" variant="ghost" onClick={onClose}>
            {t("common.cancel")}
          </Button>
          <Button size="sm" disabled={!formValid || createAccountMut.isPending} onClick={handleCreate}>
            {createAccountMut.isPending ? <Loader2 className="size-3.5 animate-spin" /> : <UserPlus className="size-3.5" />}
            {t("technicians.list.createTechnician")}
          </Button>
        </div>
      </div>

      {showLinkExisting ? <LinkExistingProfilePanel orgId={orgId} onClose={onClose} /> : null}
    </div>
  )
}

/** Secondary path — see AddTechnicianPanel's doc comment. */
function LinkExistingProfilePanel({ orgId, onClose }: { orgId: string | undefined; onClose: () => void }) {
  const { t } = useTranslation()
  const { data: eligible, isLoading } = useEligibleTechnicianProfiles(orgId)
  const createMut = useCreateTechnician()
  const [selectedProfileId, setSelectedProfileId] = useState("")

  function handleAdd() {
    if (!orgId || !selectedProfileId) return
    createMut.mutate({ orgId, profileId: selectedProfileId }, { onSuccess: () => onClose() })
  }

  return (
    <div className="mt-3 rounded-xl border border-border bg-surface-alt p-3.5">
      <p className="mb-1 text-xs font-semibold text-text">{t("technicians.list.linkExistingTitle")}</p>
      <p className="mb-3 text-xs text-text-muted">{t("technicians.list.addTechnicianHint")}</p>

      {isLoading ? (
        <Skeleton className="h-9 w-full" />
      ) : (eligible ?? []).length === 0 ? (
        <p className="rounded-xl border border-border bg-surface px-3.5 py-2.5 text-xs text-text-muted">
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
  onAddClick,
}: {
  rows: TechnicianListItem[]
  loading: boolean
  error: string | null
  onRetry: () => void
  onRowClick: (row: TechnicianListItem) => void
  onAddClick: () => void
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
          <div key={i} className={cn("grid items-center border-b border-[#F1EDE6] px-[22px] py-[14px]", TABLE_GRID_COLS)}>
            {headers.map((h) => (
              <Skeleton key={h} className="h-4 w-3/4 max-w-32" />
            ))}
          </div>
        ))
      ) : rows.length === 0 ? (
        <div className="flex flex-col items-center gap-3 py-12 text-center">
          <Inbox className="size-6 text-text-muted" />
          <div>
            <p className="text-sm font-semibold text-text">{t("technicians.list.empty")}</p>
            <p className="mt-1 text-xs text-text-muted">{t("technicians.list.emptyHint")}</p>
          </div>
          <Button size="sm" onClick={onAddClick}>
            <Plus className="size-3.5" />
            {t("technicians.list.addTechnician")}
          </Button>
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
              role="button"
              tabIndex={0}
              onClick={() => onRowClick(r)}
              onKeyDown={(e) => {
                if (e.key === "Enter" || e.key === " ") onRowClick(r)
              }}
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
