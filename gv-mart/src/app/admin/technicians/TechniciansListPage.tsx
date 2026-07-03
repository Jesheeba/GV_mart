import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { Link } from "react-router-dom"
import { Loader2, MapPin, Star, UserCog } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { KpiCard } from "@/components/shared/KpiCard"
import { StatusDot } from "@/components/shared/StatusDot"
import { useProfile } from "@/hooks/useProfile"
import { useTechniciansList, useUpdateTechnician } from "@/hooks/useTechniciansAdmin"
import type { TechnicianListItem } from "@/services/techniciansAdmin"

const SKILL_OPTIONS = ["ro", "ac", "inverter", "battery"] as const

/**
 * ADM-14. "Add Technician" here only ever edits zone/skills/active-status on
 * an *existing* seeded technician/profile row — see file-level note in
 * services/techniciansAdmin.ts and the build report's "known limitation":
 * provisioning a brand-new technician needs a Supabase Auth user + profiles
 * row, which requires the service_role key. This app ships only the anon
 * key to the browser, so that flow is intentionally out of scope here.
 */
export function TechniciansListPage() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: technicians, isLoading, isError, refetch } = useTechniciansList(orgId)
  const updateMut = useUpdateTechnician()

  const [search, setSearch] = useState("")
  const [dutyFilter, setDutyFilter] = useState<"all" | "on" | "off">("all")
  const [editingId, setEditingId] = useState<string | null>(null)
  const [editZone, setEditZone] = useState("")
  const [editSkills, setEditSkills] = useState<string[]>([])
  const [editActive, setEditActive] = useState(true)

  const filtered = useMemo(() => {
    let rows = technicians ?? []
    if (dutyFilter === "on") rows = rows.filter((r) => r.is_on_duty)
    if (dutyFilter === "off") rows = rows.filter((r) => !r.is_on_duty)
    const term = search.trim().toLowerCase()
    if (term) {
      rows = rows.filter(
        (r) => r.profiles?.full_name.toLowerCase().includes(term) || r.profiles?.phone?.toLowerCase().includes(term)
      )
    }
    return rows
  }, [technicians, dutyFilter, search])

  const kpis = useMemo(() => {
    const rows = technicians ?? []
    const onDuty = rows.filter((r) => r.is_on_duty).length
    const totalJobs = rows.reduce((sum, r) => sum + r.todaysJobCount, 0)
    const totalRevenue = rows.reduce((sum, r) => sum + r.todaysRevenue, 0)
    return { total: rows.length, onDuty, totalJobs, totalRevenue }
  }, [technicians])

  function openEdit(row: TechnicianListItem) {
    setEditingId(row.id)
    setEditZone(row.zone ?? "")
    setEditSkills(row.skills ?? [])
    setEditActive(row.is_active)
  }

  function closeEdit() {
    setEditingId(null)
  }

  function toggleSkill(skill: string) {
    setEditSkills((prev) => (prev.includes(skill) ? prev.filter((s) => s !== skill) : [...prev, skill]))
  }

  function saveEdit() {
    if (!editingId) return
    updateMut.mutate(
      { id: editingId, patch: { zone: editZone || null, skills: editSkills, is_active: editActive } },
      { onSuccess: () => closeEdit() }
    )
  }

  const columns: DataTableColumn<TechnicianListItem>[] = [
    {
      key: "name",
      header: t("technicians.list.name"),
      render: (r) => (
        <div>
          <div className="font-medium text-text">{r.profiles?.full_name ?? "—"}</div>
          <div className="text-xs text-text-muted">{r.profiles?.phone ?? "—"}</div>
        </div>
      ),
    },
    { key: "zone", header: t("technicians.list.zone"), render: (r) => r.zone ?? "—" },
    {
      key: "status",
      header: t("technicians.list.status"),
      render: (r) => (
        <StatusDot
          tone={r.is_on_duty ? "success" : "neutral"}
          label={r.is_on_duty ? t("technicians.list.onDuty") : t("technicians.list.offDuty")}
        />
      ),
    },
    { key: "jobs", header: t("technicians.list.todaysJobs"), render: (r) => r.todaysJobCount },
    { key: "revenue", header: t("technicians.list.todaysRevenue"), render: (r) => `₹${r.todaysRevenue.toLocaleString("en-IN")}` },
    {
      key: "rating",
      header: t("technicians.list.avgRating"),
      render: (r) =>
        r.avgRating != null ? (
          <span className="inline-flex items-center gap-1">
            <Star className="size-3.5 fill-warning text-warning" />
            {r.avgRating}
          </span>
        ) : (
          "—"
        ),
    },
    {
      key: "active",
      header: t("technicians.list.active"),
      render: (r) => <StatusDot tone={r.is_active ? "success" : "danger"} label={r.is_active ? t("common.yes") : t("common.no")} />,
    },
    {
      key: "__actions",
      header: "",
      className: "text-right",
      render: (r) => (
        <Button size="xs" variant="outline" onClick={() => openEdit(r)}>
          {t("technicians.list.edit")}
        </Button>
      ),
    },
  ]

  return (
    <div className="space-y-4 pt-2">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold text-text">{t("technicians.list.title")}</h1>
          <p className="text-sm text-text-muted">{t("technicians.list.subtitle")}</p>
        </div>
        <Link to="/admin/technicians/map">
          <Button variant="outline">
            <MapPin className="size-4" />
            {t("technicians.list.viewMap")}
          </Button>
        </Link>
      </div>

      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <KpiCard label={t("technicians.list.kpiTotal")} value={kpis.total} icon={<UserCog className="size-4" />} loading={isLoading} />
        <KpiCard label={t("technicians.list.kpiOnDuty")} value={kpis.onDuty} loading={isLoading} />
        <KpiCard label={t("technicians.list.kpiJobsToday")} value={kpis.totalJobs} loading={isLoading} />
        <KpiCard label={t("technicians.list.kpiRevenueToday")} value={`₹${kpis.totalRevenue.toLocaleString("en-IN")}`} loading={isLoading} />
      </div>

      <Card size="default" className="gap-3">
        <div className="flex flex-wrap items-center gap-3">
          <Input
            placeholder={t("technicians.list.searchPlaceholder")}
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="max-w-xs"
          />
          <div className="flex items-center gap-1.5">
            {(["all", "on", "off"] as const).map((f) => (
              <Button key={f} size="xs" variant={dutyFilter === f ? "default" : "outline"} onClick={() => setDutyFilter(f)}>
                {t(`technicians.list.filter.${f}`)}
              </Button>
            ))}
          </div>
        </div>

        {editingId ? (
          <div className="rounded-xl border border-border p-3.5">
            <p className="mb-3 text-sm font-semibold text-text">{t("technicians.list.editTitle")}</p>
            <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
              <div className="space-y-1">
                <Label htmlFor="tech-zone">{t("technicians.list.zone")}</Label>
                <Input id="tech-zone" value={editZone} onChange={(e) => setEditZone(e.target.value)} />
              </div>
              <div className="space-y-1 sm:col-span-2">
                <Label>{t("technicians.list.skills")}</Label>
                <div className="flex flex-wrap gap-1.5">
                  {SKILL_OPTIONS.map((skill) => (
                    <Button
                      key={skill}
                      type="button"
                      size="xs"
                      variant={editSkills.includes(skill) ? "default" : "outline"}
                      onClick={() => toggleSkill(skill)}
                    >
                      {t(`technicians.list.skillOptions.${skill}`)}
                    </Button>
                  ))}
                </div>
              </div>
              <div className="flex items-center gap-2">
                <input
                  id="tech-active"
                  type="checkbox"
                  checked={editActive}
                  onChange={(e) => setEditActive(e.target.checked)}
                  className="size-4"
                />
                <Label htmlFor="tech-active">{t("technicians.list.active")}</Label>
              </div>
            </div>
            <div className="mt-3 flex justify-end gap-2">
              <Button size="sm" variant="ghost" onClick={closeEdit}>
                {t("common.cancel")}
              </Button>
              <Button size="sm" onClick={saveEdit} disabled={updateMut.isPending}>
                {updateMut.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("common.save")}
              </Button>
            </div>
          </div>
        ) : null}

        <DataTable
          columns={columns}
          rows={filtered}
          rowKey={(r) => r.id}
          loading={isLoading}
          error={isError ? t("technicians.list.loadFailed") : null}
          onRetry={() => refetch()}
          emptyMessage={t("technicians.list.empty")}
        />
      </Card>
    </div>
  )
}
