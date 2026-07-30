import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate, useParams } from "react-router-dom"
import { Briefcase, ChevronLeft, ChevronRight, Gift, History, Loader2, Pencil, Phone, Power, Trash2, X } from "lucide-react"
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
  useDeleteTechnicianAvailability,
  useTechnicianAttendanceForMonth,
  useTechnicianAvailability,
  useTechnicianCurrentJob,
  useTechnicianRewards,
  useTechnicianTicketHistory,
  useTechniciansList,
  useTechnicianVisitsForDate,
  useUpdateTechnician,
  useUpsertTechnicianAvailability,
} from "@/hooks/useTechniciansAdmin"
import { PriorityBadge, TicketTypeBadge } from "@/app/admin/service/TicketBadges"
import { pickHistoryVisit } from "@/services/techniciansAdmin"
import type { AttendanceRow, TechnicianCurrentJob, TechnicianHistoryTicket, TechnicianRewardItem, TechnicianVisitForDate } from "@/services/techniciansAdmin"
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
/** Requirement 2/11 — shared local formatter for History's visit duration and Attendance's worked-hours readout (e.g. "7h 32m"); not a shared util, both call sites live in this one file. */
function fmtDuration(startIso: string, endIso: string): string {
  const ms = Math.max(0, new Date(endIso).getTime() - new Date(startIso).getTime())
  const totalMinutes = Math.round(ms / 60_000)
  const h = Math.floor(totalMinutes / 60)
  const m = totalMinutes % 60
  return h > 0 ? `${h}h ${m}m` : `${m}m`
}

function initialsOf(name: string) {
  return name.split(" ").map((p) => p[0]).filter(Boolean).slice(0, 2).join("").toUpperCase()
}

function todayIso() {
  return new Date().toISOString().slice(0, 10)
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
  const history = useTechnicianTicketHistory(id)
  const rewards = useTechnicianRewards(id)

  const [editing, setEditing] = useState(false)
  const [editZone, setEditZone] = useState("")
  const [editSkills, setEditSkills] = useState<string[]>([])
  const [editCapacity, setEditCapacity] = useState("")
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
    setEditCapacity(String(technician!.daily_capacity_minutes ?? 480))
    setEditing(true)
  }
  function toggleSkill(skill: string) {
    setEditSkills((prev) => (prev.includes(skill) ? prev.filter((s) => s !== skill) : [...prev, skill]))
  }
  const capacityValid = /^\d+$/.test(editCapacity.trim()) && Number(editCapacity) > 0
  function saveEdit() {
    if (!capacityValid) return
    updateMut.mutate(
      { id: technician!.id, patch: { zone: editZone || null, skills: editSkills, daily_capacity_minutes: Number(editCapacity) } },
      { onSuccess: () => setEditing(false) }
    )
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
              <div className="space-y-1">
                <Label htmlFor="tech-daily-capacity">{t("technicians.list.dailyCapacity")}</Label>
                <Input
                  id="tech-daily-capacity"
                  type="number"
                  min={1}
                  step={1}
                  value={editCapacity}
                  onChange={(e) => setEditCapacity(e.target.value)}
                  aria-invalid={!capacityValid}
                />
              </div>
              <div className="space-y-1 sm:col-span-3">
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
              <Button size="sm" onClick={saveEdit} disabled={updateMut.isPending || !capacityValid}>
                {updateMut.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("common.save")}
              </Button>
            </div>
          </div>
        ) : null}

        <div className="grid grid-cols-2 gap-3 border-t border-border px-1 pt-4 sm:grid-cols-4">
          <StatCell label={t("technicians.list.kpiJobsToday")} value={technician.periodJobCount} />
          <StatCell label={t("technicians.list.kpiRevenueToday")} value={`₹${technician.periodRevenue.toLocaleString("en-IN")}`} />
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
          <TabsTrigger value="availability">{t("technicians.detail.tabs.availability")}</TabsTrigger>
        </TabsList>

        <TabsContent value="current" className="mt-3.5">
          <CurrentJobTab loading={currentJob.isLoading} job={currentJob.data ?? null} onOpenTicket={(ticketId) => navigate(`/admin/service/${ticketId}`)} />
        </TabsContent>

        <TabsContent value="history" className="mt-3.5">
          <HistoryTab loading={history.isLoading} rows={history.data ?? []} onOpenTicket={(ticketId) => navigate(`/admin/service/${ticketId}`)} />
        </TabsContent>

        <TabsContent value="attendance" className="mt-3.5">
          <AttendanceTab technicianId={id} />
        </TabsContent>

        <TabsContent value="rewards" className="mt-3.5">
          <RewardsTab loading={rewards.isLoading} rows={rewards.data ?? []} />
        </TabsContent>

        <TabsContent value="availability" className="mt-3.5">
          <AvailabilityTab technicianId={id} orgId={orgId} />
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
  rows: TechnicianHistoryTicket[]
  onOpenTicket: (ticketId: string) => void
}) {
  const { t } = useTranslation()
  if (loading) return <Skeleton className="h-48 w-full" />
  if (rows.length === 0) return <EmptyState label={t("technicians.detail.noHistory")} />
  return (
    <div className="space-y-2">
      {rows.map((r) => {
        // Requirement 2/11 — visit duration + customer rating, only shown
        // once the picked visit actually completed (timer_start AND
        // timer_end both set); a ticket with no visit yet, or one still
        // in progress, simply shows no third line.
        const visit = pickHistoryVisit(r.service_visits ?? [])
        const isCompleted = !!(visit?.timer_start && visit?.timer_end)
        const stars = visit?.ratings?.stars ?? null
        return (
          <button
            key={r.id}
            type="button"
            onClick={() => onOpenTicket(r.id)}
            className="flex w-full flex-wrap items-center justify-between gap-2 rounded-xl border border-border bg-surface px-4 py-3 text-left hover:bg-surface-alt"
          >
            <div>
              <p className="text-sm font-semibold text-text">{r.customers?.name ?? "—"}</p>
              <p className="text-xs text-text-muted">{r.name_of_complaint || r.products?.name || "—"} · {fmtDate(r.created_at)}</p>
              {isCompleted ? (
                <p className="text-xs text-text-muted">
                  {fmtDuration(visit!.timer_start!, visit!.timer_end!)}
                  {" · "}
                  {stars != null ? `★ ${stars}` : t("technicians.detail.history.notRated")}
                </p>
              ) : null}
            </div>
            <div className="flex items-center gap-2">
              <TicketTypeBadge type={r.type} />
              <PriorityBadge priority={r.priority} />
              <StatusDot tone={r.status === "completed" ? "success" : r.status === "cancelled" ? "danger" : "warning"} label={t(`service.status.${r.status}`)} />
            </div>
          </button>
        )
      })}
    </div>
  )
}

type AttendanceCell = { key: string; day: number; inMonth: boolean; dateStr: string | null }

function buildMonthCells(year: number, month: number): AttendanceCell[] {
  const pad = (n: number) => String(n).padStart(2, "0")
  const startWeekday = new Date(year, month, 1).getDay() // 0 = Sunday
  const daysInMonth = new Date(year, month + 1, 0).getDate()
  const daysInPrevMonth = new Date(year, month, 0).getDate()
  const totalCells = Math.ceil((startWeekday + daysInMonth) / 7) * 7

  const cells: AttendanceCell[] = []
  for (let i = 0; i < totalCells; i++) {
    const offset = i - startWeekday
    if (offset < 0) {
      const day = daysInPrevMonth + offset + 1
      cells.push({ key: `prev-${day}`, day, inMonth: false, dateStr: null })
    } else if (offset >= daysInMonth) {
      const day = offset - daysInMonth + 1
      cells.push({ key: `next-${day}`, day, inMonth: false, dateStr: null })
    } else {
      const day = offset + 1
      cells.push({ key: `${year}-${pad(month + 1)}-${pad(day)}`, day, inMonth: true, dateStr: `${year}-${pad(month + 1)}-${pad(day)}` })
    }
  }
  return cells
}

/** Month calendar grid (replaces the earlier flat list) — client-specified
 * layout: month/year header with prev/next + Today, weekday row, day grid
 * with a status dot per day that has an attendance record. Built with this
 * app's own Card/Button/color-token system, not a copy of any reference
 * calendar's literal styling. */
function AttendanceTab({ technicianId }: { technicianId: string | undefined }) {
  const { t, i18n } = useTranslation()
  const now = new Date()
  const [viewYear, setViewYear] = useState(now.getFullYear())
  const [viewMonth, setViewMonth] = useState(now.getMonth())
  const [selectedDate, setSelectedDate] = useState<string | null>(null)

  const { data: rows, isLoading } = useTechnicianAttendanceForMonth(technicianId, viewYear, viewMonth)
  const { data: dayVisits, isLoading: dayVisitsLoading } = useTechnicianVisitsForDate(technicianId, selectedDate)

  const byDate = useMemo(() => {
    const map = new Map<string, AttendanceRow>()
    for (const r of rows ?? []) map.set(r.date, r)
    return map
  }, [rows])

  const cells = useMemo(() => buildMonthCells(viewYear, viewMonth), [viewYear, viewMonth])

  const locale = i18n.language === "ta" ? "ta-IN" : "en-IN"
  const monthLabel = new Date(viewYear, viewMonth, 1).toLocaleDateString(locale, { month: "long" })
  const weekdayLabels = useMemo(() => {
    const sunday = new Date(2026, 5, 7) // a known Sunday, locale-formatted below
    return Array.from({ length: 7 }, (_, i) => {
      const d = new Date(sunday)
      d.setDate(sunday.getDate() + i)
      return d.toLocaleDateString(locale, { weekday: "short" })
    })
  }, [locale])

  const todayStr = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-${String(now.getDate()).padStart(2, "0")}`

  function goPrevMonth() {
    setSelectedDate(null)
    if (viewMonth === 0) {
      setViewMonth(11)
      setViewYear((y) => y - 1)
    } else {
      setViewMonth((m) => m - 1)
    }
  }
  function goNextMonth() {
    setSelectedDate(null)
    if (viewMonth === 11) {
      setViewMonth(0)
      setViewYear((y) => y + 1)
    } else {
      setViewMonth((m) => m + 1)
    }
  }
  function goToday() {
    setSelectedDate(null)
    setViewYear(now.getFullYear())
    setViewMonth(now.getMonth())
  }

  return (
    <Card className="gap-3.5">
      <div className="flex items-center justify-between px-1">
        <div className="flex items-center gap-1.5">
          <Button type="button" size="icon-sm" variant="outline" onClick={goPrevMonth} aria-label={t("technicians.detail.attendance.prevMonth")}>
            <ChevronLeft className="size-3.5" />
          </Button>
          <p className="w-32 text-center text-sm font-semibold text-text">
            {monthLabel} {viewYear}
          </p>
          <Button type="button" size="icon-sm" variant="outline" onClick={goNextMonth} aria-label={t("technicians.detail.attendance.nextMonth")}>
            <ChevronRight className="size-3.5" />
          </Button>
        </div>
        <Button type="button" size="sm" variant="outline" onClick={goToday}>
          {t("technicians.detail.attendance.today")}
        </Button>
      </div>

      {isLoading ? (
        <Skeleton className="h-72 w-full" />
      ) : (
        <>
          <div className="grid grid-cols-7 gap-1 px-1">
            {weekdayLabels.map((w, i) => (
              <p key={i} className="text-center text-[11px] font-semibold tracking-wide text-text-muted uppercase">
                {w}
              </p>
            ))}
          </div>
          <div className="grid grid-cols-7 gap-1 px-1 pb-1">
            {cells.map((c) => {
              const record = c.dateStr ? byDate.get(c.dateStr) : undefined
              const isToday = c.dateStr === todayStr
              const isSelected = !!c.dateStr && c.dateStr === selectedDate
              const title = record
                ? [
                    record.check_in_at ? t("technicians.detail.attendance.checkedInAt", { time: fmtDateTime(record.check_in_at) }) : null,
                    t("technicians.detail.attendance.checkedOutAt", { time: record.check_out_at ? fmtDateTime(record.check_out_at) : "—" }),
                    !record.inside_geofence ? t("technicians.detail.outsideGeofence") : null,
                  ]
                    .filter(Boolean)
                    .join(" · ")
                : undefined
              return (
                <button
                  key={c.key}
                  type="button"
                  title={title}
                  disabled={!c.inMonth}
                  onClick={() => c.dateStr && setSelectedDate((d) => (d === c.dateStr ? null : c.dateStr))}
                  className={cn(
                    "flex aspect-square flex-col items-center justify-center gap-1 rounded-xl border text-xs transition-colors",
                    c.inMonth ? "border-border bg-surface hover:bg-surface-alt" : "cursor-default border-transparent bg-transparent",
                    isToday && "border-accent ring-1 ring-accent",
                    isSelected && "border-ink bg-accent-soft"
                  )}
                >
                  <span className={cn("font-semibold", c.inMonth ? "text-text" : "text-text-muted/50")}>{c.day}</span>
                  {record ? <span className={cn("size-1.5 rounded-full", record.is_late ? "bg-danger" : "bg-success")} aria-hidden="true" /> : null}
                </button>
              )
            })}
          </div>

          <div className="flex flex-wrap items-center gap-4 border-t border-border px-1 pt-3">
            <span className="flex items-center gap-1.5 text-xs text-text-muted">
              <span className="size-1.5 rounded-full bg-success" aria-hidden="true" /> {t("technician.attendance.onTimeBadge")}
            </span>
            <span className="flex items-center gap-1.5 text-xs text-text-muted">
              <span className="size-1.5 rounded-full bg-danger" aria-hidden="true" /> {t("technician.attendance.lateBadge")}
            </span>
          </div>

          {selectedDate ? (
            <DayDetailPanel
              dateStr={selectedDate}
              record={byDate.get(selectedDate) ?? null}
              visits={dayVisits ?? []}
              loading={dayVisitsLoading}
              onClose={() => setSelectedDate(null)}
            />
          ) : null}
        </>
      )}
    </Card>
  )
}

function DayDetailPanel({
  dateStr,
  record,
  visits,
  loading,
  onClose,
}: {
  dateStr: string
  record: AttendanceRow | null
  visits: TechnicianVisitForDate[]
  loading: boolean
  onClose: () => void
}) {
  const { t } = useTranslation()
  return (
    <div className="space-y-3.5 rounded-xl border border-border bg-surface-alt/60 p-4">
      <div className="flex items-center justify-between">
        <p className="text-sm font-semibold text-text">{fmtDate(dateStr)}</p>
        <Button type="button" size="icon-xs" variant="ghost" onClick={onClose} aria-label={t("common.cancel")}>
          <X className="size-3.5" />
        </Button>
      </div>

      <div className="space-y-1.5">
        <p className="text-xs font-semibold text-text-muted uppercase">{t("technicians.detail.attendance.timeLogTitle")}</p>
        {record ? (
          <div className="space-y-1 rounded-lg bg-surface px-3 py-2.5">
            <p className="text-sm text-text">{t("technicians.detail.attendance.checkedInAt", { time: record.check_in_at ? fmtDateTime(record.check_in_at) : "—" })}</p>
            <p className="text-sm text-text">
              {t("technicians.detail.attendance.checkedOutAt", { time: record.check_out_at ? fmtDateTime(record.check_out_at) : "—" })}
            </p>
            {record.check_in_at && record.check_out_at ? (
              <p className="text-sm text-text-muted">{t("technicians.detail.attendance.workedHours", { duration: fmtDuration(record.check_in_at, record.check_out_at) })}</p>
            ) : null}
            <div className="flex items-center gap-2 pt-0.5">
              {!record.inside_geofence ? (
                <span className="rounded-full bg-danger/10 px-2 py-0.5 text-[11px] font-semibold text-danger">{t("technicians.detail.outsideGeofence")}</span>
              ) : null}
              <StatusDot tone={record.is_late ? "danger" : "success"} label={record.is_late ? t("technician.attendance.lateBadge") : t("technician.attendance.onTimeBadge")} />
            </div>
          </div>
        ) : (
          <p className="rounded-lg bg-surface px-3 py-2.5 text-sm text-text-muted">{t("technicians.detail.noAttendance")}</p>
        )}
      </div>

      <div className="space-y-1.5">
        <p className="text-xs font-semibold text-text-muted uppercase">{t("technicians.detail.attendance.ratingsTitle")}</p>
        {loading ? (
          <Skeleton className="h-16 w-full" />
        ) : visits.length === 0 ? (
          <p className="rounded-lg bg-surface px-3 py-2.5 text-sm text-text-muted">{t("technicians.detail.attendance.noVisitsThisDay")}</p>
        ) : (
          <div className="space-y-1.5">
            {visits.map((v) => (
              <div key={v.id} className="flex items-center justify-between gap-2 rounded-lg bg-surface px-3 py-2.5">
                <p className="truncate text-sm text-text">{v.service_tickets?.name_of_complaint || "—"}</p>
                <p className="shrink-0 text-sm font-semibold text-text">{v.ratings ? `★ ${v.ratings.stars}` : t("technicians.detail.history.notRated")}</p>
              </div>
            ))}
          </div>
        )}
      </div>
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

const AVAILABILITY_STATUS_OPTIONS = ["working", "leave"] as const

/**
 * Phase 1 assignment-engine data (GV_Mart_Technician_Assignment_Logic_Change.md)
 * — minimal admin surface to keep technician_availability populated: an
 * upcoming-only list plus a small inline add form. Deliberately not a
 * calendar UI; that's out of scope for this pass.
 */
function AvailabilityTab({ technicianId, orgId }: { technicianId: string | undefined; orgId: string | undefined }) {
  const { t } = useTranslation()
  const { data: rows, isLoading, isError } = useTechnicianAvailability(technicianId)
  const upsertMut = useUpsertTechnicianAvailability()
  const deleteMut = useDeleteTechnicianAvailability()

  const [date, setDate] = useState(todayIso())
  const [status, setStatus] = useState<(typeof AVAILABILITY_STATUS_OPTIONS)[number]>("leave")
  const [shiftStart, setShiftStart] = useState("")
  const [shiftEnd, setShiftEnd] = useState("")

  function submit() {
    if (!technicianId || !orgId || !date) return
    upsertMut.mutate(
      {
        org_id: orgId,
        technician_id: technicianId,
        date,
        status,
        shift_start: shiftStart || null,
        shift_end: shiftEnd || null,
      },
      {
        onSuccess: () => {
          setDate(todayIso())
          setStatus("leave")
          setShiftStart("")
          setShiftEnd("")
        },
      }
    )
  }

  function remove(rowId: string) {
    if (!technicianId) return
    deleteMut.mutate({ id: rowId, technicianId })
  }

  return (
    <Card className="gap-3.5">
      <p className="px-1 text-sm font-semibold text-text">{t("technicians.detail.availability.addTitle")}</p>
      <div className="grid grid-cols-2 gap-3 px-1 sm:grid-cols-5">
        <div className="space-y-1">
          <Label htmlFor="avail-date">{t("technicians.detail.availability.date")}</Label>
          <Input id="avail-date" type="date" value={date} onChange={(e) => setDate(e.target.value)} />
        </div>
        <div className="space-y-1">
          <Label htmlFor="avail-status">{t("technicians.detail.availability.status")}</Label>
          <select
            id="avail-status"
            value={status}
            onChange={(e) => setStatus(e.target.value as (typeof AVAILABILITY_STATUS_OPTIONS)[number])}
            className="h-11 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
          >
            {AVAILABILITY_STATUS_OPTIONS.map((s) => (
              <option key={s} value={s}>
                {t(`technicians.detail.availability.statusOptions.${s}`)}
              </option>
            ))}
          </select>
        </div>
        <div className="space-y-1">
          <Label htmlFor="avail-shift-start">{t("technicians.detail.availability.shiftStart")}</Label>
          <Input id="avail-shift-start" type="time" value={shiftStart} onChange={(e) => setShiftStart(e.target.value)} />
        </div>
        <div className="space-y-1">
          <Label htmlFor="avail-shift-end">{t("technicians.detail.availability.shiftEnd")}</Label>
          <Input id="avail-shift-end" type="time" value={shiftEnd} onChange={(e) => setShiftEnd(e.target.value)} />
        </div>
        <div className="flex items-end">
          <Button size="sm" className="w-full" onClick={submit} disabled={!date || upsertMut.isPending}>
            {upsertMut.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("common.save")}
          </Button>
        </div>
      </div>
      {upsertMut.isError ? <p className="px-1 text-sm text-danger">{(upsertMut.error as Error).message}</p> : null}

      <div className="space-y-2 border-t border-border px-1 pt-3.5">
        {isLoading ? (
          <Skeleton className="h-24 w-full" />
        ) : isError ? (
          <p className="text-sm text-danger">{t("technicians.detail.availability.loadFailed")}</p>
        ) : (rows ?? []).length === 0 ? (
          <p className="text-sm text-text-muted">{t("technicians.detail.availability.empty")}</p>
        ) : (
          (rows ?? []).map((r) => (
            <div key={r.id} className="flex flex-wrap items-center justify-between gap-2 rounded-xl border border-border bg-surface px-4 py-3">
              <div>
                <p className="text-sm font-semibold text-text">{fmtDate(r.date)}</p>
                <p className="text-xs text-text-muted">
                  {t(`technicians.detail.availability.statusOptions.${r.status}`)}
                  {r.shift_start && r.shift_end ? ` · ${r.shift_start.slice(0, 5)}–${r.shift_end.slice(0, 5)}` : ""}
                </p>
              </div>
              <Button size="icon-xs" variant="ghost" onClick={() => remove(r.id)} disabled={deleteMut.isPending}>
                <Trash2 className="size-3.5 text-danger" />
              </Button>
            </div>
          ))
        )}
      </div>
    </Card>
  )
}
