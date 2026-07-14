import { useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate, useParams } from "react-router-dom"
import { Briefcase, ChevronLeft, Gift, History, Loader2, Pencil, Phone, Power } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Skeleton } from "@/components/ui/skeleton"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { StatusDot } from "@/components/shared/StatusDot"
import { useProfile } from "@/hooks/useProfile"
import {
  useTechnicianAttendanceHistory,
  useTechnicianCurrentJob,
  useTechnicianRewards,
  useTechniciansList,
  useUpdateTechnician,
} from "@/hooks/useTechniciansAdmin"
import { useTicketsList } from "@/hooks/useService"
import { PriorityBadge, TicketTypeBadge } from "@/app/admin/service/TicketBadges"
import type { AttendanceRow, TechnicianCurrentJob, TechnicianRewardItem } from "@/services/techniciansAdmin"
import type { TicketListItem } from "@/services/service"
import { cn } from "@/lib/utils"

const SKILL_OPTIONS = ["ro", "ac", "inverter", "battery"] as const

function fmtDate(iso: string | null | undefined) {
  if (!iso) return "—"
  return new Date(iso).toLocaleDateString("en-IN", { day: "2-digit", month: "short", year: "numeric" })
}
function fmtDateTime(iso: string | null | undefined) {
  if (!iso) return "—"
  return new Date(iso).toLocaleString("en-IN", { day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit" })
}

function initialsOf(name: string) {
  return name.split(" ").map((p) => p[0]).filter(Boolean).slice(0, 2).join("").toUpperCase()
}

export function TechnicianDetailPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { id } = useParams<{ id: string }>()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: technicians, isLoading, isError, refetch } = useTechniciansList(orgId)
  const updateMut = useUpdateTechnician()
  const technician = technicians?.find((tc) => tc.id === id)

  const currentJob = useTechnicianCurrentJob(id)
  const history = useTicketsList(orgId, { technicianId: id })
  const attendance = useTechnicianAttendanceHistory(id)
  const rewards = useTechnicianRewards(id)

  const [editing, setEditing] = useState(false)
  const [editZone, setEditZone] = useState("")
  const [editSkills, setEditSkills] = useState<string[]>([])
  const [confirmingDeactivate, setConfirmingDeactivate] = useState(false)

  if (isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError) {
    return <FullPageError message={t("technicians.list.loadFailed")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }
  if (!technician) {
    return <FullPageError message={t("technicians.detail.notFound")} onRetry={() => navigate("/admin/technicians")} retryLabel={t("technicians.detail.backToList")} />
  }

  const name = technician.profiles?.full_name ?? "—"

  function startEdit() {
    setEditZone(technician!.zone ?? "")
    setEditSkills(technician!.skills ?? [])
    setEditing(true)
  }
  function toggleSkill(skill: string) {
    setEditSkills((prev) => (prev.includes(skill) ? prev.filter((s) => s !== skill) : [...prev, skill]))
  }
  function saveEdit() {
    updateMut.mutate({ id: technician!.id, patch: { zone: editZone || null, skills: editSkills } }, { onSuccess: () => setEditing(false) })
  }
  function toggleActive() {
    updateMut.mutate(
      { id: technician!.id, patch: { is_active: !technician!.is_active } },
      { onSuccess: () => setConfirmingDeactivate(false) }
    )
  }

  return (
    <div className="space-y-4 pt-2">
      <div className="flex items-center gap-2 text-sm">
        <button
          type="button"
          onClick={() => navigate("/admin/technicians")}
          className="flex items-center gap-1 font-semibold text-text-muted hover:text-text"
        >
          <ChevronLeft className="size-4" />
          {t("technicians.detail.backToList")}
        </button>
        <span className="text-[#C9C4BA]">/</span>
        <span className="font-semibold text-text">{name}</span>
      </div>

      <Card className="gap-4">
        <div className="flex flex-wrap items-start justify-between gap-3 px-1">
          <div className="flex items-start gap-4.5">
            <span className="flex size-16 shrink-0 items-center justify-center rounded-[18px] bg-ink text-[20px] font-extrabold text-white">
              {initialsOf(name)}
            </span>
            <div>
              <h1 className="mb-1 text-[23px] font-extrabold tracking-tight text-text">{name}</h1>
              <p className="mb-2.5 text-sm font-medium text-text-muted">{technician.profiles?.phone ?? "—"}</p>
              <div className="flex flex-wrap items-center gap-2">
                <StatusDot
                  tone={!technician.is_active ? "danger" : technician.is_on_duty ? "success" : "neutral"}
                  label={!technician.is_active ? t("technicians.list.statusInactive") : technician.is_on_duty ? t("technicians.list.onDuty") : t("technicians.list.offDuty")}
                />
                {technician.zone ? (
                  <span className="rounded-full border border-border bg-surface-alt px-2.75 py-1 text-[11px] font-semibold text-text">{technician.zone}</span>
                ) : null}
                {(technician.skills ?? []).map((s) => (
                  <span key={s} className="rounded-full border border-border bg-surface-alt px-2.75 py-1 text-[11px] font-semibold text-text">
                    {t(`technicians.list.skillOptions.${s}`, s)}
                  </span>
                ))}
              </div>
            </div>
          </div>
          <div className="flex items-center gap-1.5">
            {technician.profiles?.phone ? (
              <Button variant="outline" size="icon" title={t("customers.detail.call")} nativeButton={false} render={<a href={`tel:${technician.profiles.phone}`} />}>
                <Phone className="size-4" />
              </Button>
            ) : null}
            <Button variant="outline" size="icon" title={t("technicians.detail.edit")} onClick={startEdit}>
              <Pencil className="size-4" />
            </Button>
            <Button
              variant="outline"
              size="icon"
              title={technician.is_active ? t("technicians.detail.deactivate") : t("technicians.detail.reactivate")}
              className={technician.is_active ? "text-danger" : "text-success"}
              onClick={() => setConfirmingDeactivate(true)}
            >
              <Power className="size-4" />
            </Button>
          </div>
        </div>

        {confirmingDeactivate ? (
          <div className="flex flex-wrap items-center gap-3 rounded-xl border border-border bg-surface-alt px-4 py-3">
            <p className="flex-1 text-sm text-text">
              {technician.is_active ? t("technicians.detail.confirmDeactivate", { name }) : t("technicians.detail.confirmReactivate", { name })}
            </p>
            <Button size="sm" variant="ghost" onClick={() => setConfirmingDeactivate(false)}>
              {t("common.cancel")}
            </Button>
            <Button size="sm" variant={technician.is_active ? "destructive" : "default"} disabled={updateMut.isPending} onClick={toggleActive}>
              {updateMut.isPending ? <Loader2 className="size-3.5 animate-spin" /> : technician.is_active ? t("technicians.detail.deactivate") : t("technicians.detail.reactivate")}
            </Button>
          </div>
        ) : null}

        {editing ? (
          <div className="rounded-xl border border-border bg-surface-alt p-4">
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
                    <Button key={skill} type="button" size="xs" variant={editSkills.includes(skill) ? "default" : "outline"} onClick={() => toggleSkill(skill)}>
                      {t(`technicians.list.skillOptions.${skill}`)}
                    </Button>
                  ))}
                </div>
              </div>
            </div>
            {updateMut.isError ? <p className="mt-3 rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{(updateMut.error as Error).message}</p> : null}
            <div className="mt-3 flex justify-end gap-2">
              <Button size="sm" variant="ghost" onClick={() => setEditing(false)}>
                {t("common.cancel")}
              </Button>
              <Button size="sm" onClick={saveEdit} disabled={updateMut.isPending}>
                {updateMut.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("common.save")}
              </Button>
            </div>
          </div>
        ) : null}

        <div className="grid grid-cols-2 gap-3 border-t border-border px-1 pt-4 sm:grid-cols-4">
          <StatCell label={t("technicians.list.kpiJobsToday")} value={technician.todaysJobCount} />
          <StatCell label={t("technicians.list.kpiRevenueToday")} value={`₹${technician.todaysRevenue.toLocaleString("en-IN")}`} />
          <StatCell label={t("technicians.list.avgRating")} value={technician.avgRating != null ? `${technician.avgRating} ★` : "—"} />
          <StatCell label={t("technicians.detail.totalJobs")} value={history.data?.length ?? "—"} />
        </div>
      </Card>

      <Tabs defaultValue="current">
        <TabsList className="border border-border bg-surface p-1.25">
          <TabsTrigger value="current">
            <Briefcase className="size-3.5" /> {t("technicians.detail.tabs.current")}
          </TabsTrigger>
          <TabsTrigger value="history">
            <History className="size-3.5" /> {t("technicians.detail.tabs.history")}
          </TabsTrigger>
          <TabsTrigger value="attendance">{t("technicians.detail.tabs.attendance")}</TabsTrigger>
          <TabsTrigger value="rewards">
            <Gift className="size-3.5" /> {t("technicians.detail.tabs.rewards")}
          </TabsTrigger>
        </TabsList>

        <TabsContent value="current" className="mt-3.5">
          <CurrentJobTab loading={currentJob.isLoading} job={currentJob.data ?? null} onOpenTicket={(ticketId) => navigate(`/admin/service/${ticketId}`)} />
        </TabsContent>

        <TabsContent value="history" className="mt-3.5">
          <HistoryTab loading={history.isLoading} rows={history.data ?? []} onOpenTicket={(ticketId) => navigate(`/admin/service/${ticketId}`)} />
        </TabsContent>

        <TabsContent value="attendance" className="mt-3.5">
          <AttendanceTab loading={attendance.isLoading} rows={attendance.data ?? []} />
        </TabsContent>

        <TabsContent value="rewards" className="mt-3.5">
          <RewardsTab loading={rewards.isLoading} rows={rewards.data ?? []} />
        </TabsContent>
      </Tabs>
    </div>
  )
}

function StatCell({ label, value }: { label: string; value: string | number }) {
  return (
    <div>
      <div className="text-xs text-text-muted">{label}</div>
      <div className="text-[17px] font-bold tabular-nums text-text">{value}</div>
    </div>
  )
}

function EmptyState({ label }: { label: string }) {
  return (
    <Card className="items-center gap-2 py-10 text-center">
      <p className="text-sm text-text-muted">{label}</p>
    </Card>
  )
}

function CurrentJobTab({
  loading,
  job,
  onOpenTicket,
}: {
  loading: boolean
  job: TechnicianCurrentJob | null
  onOpenTicket: (ticketId: string) => void
}) {
  const { t } = useTranslation()
  if (loading) return <Skeleton className="h-32 w-full" />
  if (!job) return <EmptyState label={t("technicians.detail.noCurrentJob")} />
  return (
    <Card className="gap-3 px-5">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="text-sm font-semibold text-text">{job.customerName ?? "—"}</p>
        <StatusDot tone={job.status === "in_progress" ? "warning" : "info"} label={t(`technicians.detail.jobStatus.${job.status}`)} />
      </div>
      <div className="grid grid-cols-2 gap-3 text-sm sm:grid-cols-3">
        <Field label={t("service.table.product")} value={job.productName ?? "—"} />
        <Field label={t("service.newComplaint.nameOfComplaint")} value={job.complaintName ?? "—"} />
        <Field label={t("service.table.area")} value={job.area ?? "—"} />
        <Field label={t("service.table.appointment")} value={job.mode === "always" ? t("service.appointment.always") : fmtDateTime(job.scheduledAt)} />
        <Field label={t("customers.detail.call")} value={job.customerMobile ?? "—"} />
      </div>
      <Button size="sm" variant="outline" className="w-fit" onClick={() => onOpenTicket(job.ticketId)}>
        {t("technicians.detail.viewTicket")}
      </Button>
    </Card>
  )
}

function Field({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <div className="text-xs text-text-muted">{label}</div>
      <div className="text-text">{value}</div>
    </div>
  )
}

function HistoryTab({
  loading,
  rows,
  onOpenTicket,
}: {
  loading: boolean
  rows: TicketListItem[]
  onOpenTicket: (ticketId: string) => void
}) {
  const { t } = useTranslation()
  if (loading) return <Skeleton className="h-48 w-full" />
  if (rows.length === 0) return <EmptyState label={t("technicians.detail.noHistory")} />
  return (
    <div className="space-y-2">
      {rows.map((r) => (
        <button
          key={r.id}
          type="button"
          onClick={() => onOpenTicket(r.id)}
          className="flex w-full flex-wrap items-center justify-between gap-2 rounded-xl border border-border bg-surface px-4 py-3 text-left hover:bg-surface-alt"
        >
          <div>
            <p className="text-sm font-semibold text-text">{r.customers?.name ?? "—"}</p>
            <p className="text-xs text-text-muted">{r.name_of_complaint || r.products?.name || "—"} · {fmtDate(r.created_at)}</p>
          </div>
          <div className="flex items-center gap-2">
            <TicketTypeBadge type={r.type} />
            <PriorityBadge priority={r.priority} />
            <StatusDot tone={r.status === "completed" ? "success" : r.status === "cancelled" ? "danger" : "warning"} label={t(`service.status.${r.status}`)} />
          </div>
        </button>
      ))}
    </div>
  )
}

function AttendanceTab({ loading, rows }: { loading: boolean; rows: AttendanceRow[] }) {
  const { t } = useTranslation()
  if (loading) return <Skeleton className="h-48 w-full" />
  if (rows.length === 0) return <EmptyState label={t("technicians.detail.noAttendance")} />
  return (
    <div className="space-y-2">
      {rows.map((r) => (
        <div key={r.id} className="flex flex-wrap items-center justify-between gap-2 rounded-xl border border-border bg-surface px-4 py-3">
          <div>
            <p className="text-sm font-semibold text-text">{fmtDate(r.date)}</p>
            <p className="text-xs text-text-muted">{r.check_in_at ? fmtDateTime(r.check_in_at) : "—"}</p>
          </div>
          <div className="flex items-center gap-2">
            {!r.inside_geofence ? (
              <span className={cn("rounded-full px-2 py-0.5 text-[11px] font-semibold", "bg-danger/10 text-danger")}>{t("technicians.detail.outsideGeofence")}</span>
            ) : null}
            <StatusDot tone={r.is_late ? "danger" : "success"} label={r.is_late ? t("technician.attendance.lateBadge") : t("technician.attendance.onTimeBadge")} />
          </div>
        </div>
      ))}
    </div>
  )
}

function RewardsTab({ loading, rows }: { loading: boolean; rows: TechnicianRewardItem[] }) {
  const { t } = useTranslation()
  if (loading) return <Skeleton className="h-32 w-full" />
  if (rows.length === 0) return <EmptyState label={t("technicians.detail.noRewards")} />
  return (
    <div className="space-y-2">
      {rows.map((r) => (
        <div key={r.id} className="flex flex-wrap items-center justify-between gap-2 rounded-xl border border-border bg-surface px-4 py-3">
          <div>
            <p className="text-sm font-semibold text-text">{t(`hr.rewards.categories.${r.category}`)}</p>
            <p className="text-xs text-text-muted">{r.period} · {fmtDate(r.given_at)}</p>
            {r.note ? <p className="mt-1 text-xs text-text-muted">{r.note}</p> : null}
          </div>
          <Gift className="size-4 shrink-0 text-accent" />
        </div>
      ))}
    </div>
  )
}
