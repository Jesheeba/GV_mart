import { useEffect, useState } from "react"
import { useTranslation } from "react-i18next"
import type { TFunction } from "i18next"
import { useNavigate } from "react-router-dom"
import { CalendarCheck, ChevronRight, ClipboardList, MapPin, TriangleAlert, Wrench } from "lucide-react"
import { useProfile } from "@/hooks/useProfile"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { Card } from "@/components/ui/card"
import { Button } from "@/components/ui/button"
import { Skeleton } from "@/components/ui/skeleton"
import { JobTypeBadge, OverdueBadge, OverrunBadge, PriorityBadge } from "./components/JobBadges"
import { useMyTechnician, useTechnicianSettings, useTodayAttendance, useTodaysJobCounts, useTodaysJobs } from "@/hooks/useTechnician"
import { computeJobOverrun } from "@/lib/job-overrun"
import { computeTicketAllowedDuration, findOpenVisit, isOverdueJob, type JobCard } from "@/services/technician"
import type { Tables } from "@/types/database"
import { cn } from "@/lib/utils"

function formatTime(iso: string | null) {
  if (!iso) return null
  return new Date(iso).toLocaleTimeString("en-IN", { hour: "2-digit", minute: "2-digit" })
}

/** Build Order A4: ticks every 30s so an overrunning job's red styling appears
 *  on the home list without a manual refresh, mirroring JobDetailPage's own tick.
 *  Also drives the SLA-overdue duration display below, which previously only
 *  computed `now` once per render. */
function useNowTick(intervalMs = 30_000) {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), intervalMs)
    return () => clearInterval(id)
  }, [intervalMs])
  return now
}

function formatOverdueDuration(slaDueAt: string, now: number, t: TFunction) {
  const diffMs = Math.max(0, now - new Date(slaDueAt).getTime())
  const hours = Math.floor(diffMs / 3_600_000)
  const minutes = Math.floor((diffMs % 3_600_000) / 60_000)
  return t("technician.home.overdueBy", { hours, minutes })
}

/**
 * Bug 2/3 + UI Suggestion 1/2 — priority sort bucket. tech.md's "High/Medium/
 * Low" language has no matching enum: `priority_level` only has
 * very_urgent/urgent/normal (see JobBadges.tsx's PRIORITY_CLASS), so the
 * mapping used here is:
 *   bucket 0 = overdue (any priority — an SLA breach always outranks priority)
 *   bucket 1 = priority "very_urgent"
 *   bucket 2 = priority "urgent"
 *   bucket 3 = priority "normal" (or missing/unjoined ticket)
 * Within a bucket, jobs are secondary-sorted by scheduled_at ascending with
 * nulls first — the same ordering the underlying listTodaysJobs query already
 * uses server-side, just re-applied after the bucket sort takes priority.
 */
function priorityBucket(job: JobCard, now: number): 0 | 1 | 2 | 3 {
  const ticket = job.service_tickets
  if (ticket && isOverdueJob(ticket, now)) return 0
  switch (ticket?.priority) {
    case "very_urgent":
      return 1
    case "urgent":
      return 2
    default:
      return 3
  }
}

function compareScheduledAt(a: JobCard, b: JobCard) {
  if (a.scheduled_at === b.scheduled_at) return 0
  if (a.scheduled_at === null) return -1
  if (b.scheduled_at === null) return 1
  return a.scheduled_at.localeCompare(b.scheduled_at)
}

function sortJobsByPriority(jobs: JobCard[], now: number): JobCard[] {
  return [...jobs].sort((a, b) => {
    const bucketDiff = priorityBucket(a, now) - priorityBucket(b, now)
    return bucketDiff !== 0 ? bucketDiff : compareScheduledAt(a, b)
  })
}

function CountCell({ label, value, loading, danger, className }: { label: string; value: number; loading: boolean; danger?: boolean; className?: string }) {
  return (
    <Card size="sm" className={cn("items-center gap-0.5 py-3 text-center", className)}>
      {loading ? (
        <Skeleton className="h-6 w-8" />
      ) : (
        <p className={cn("text-lg font-bold", danger ? "text-danger" : "text-text")}>{value}</p>
      )}
      <p className="text-[11px] text-text-muted">{label}</p>
    </Card>
  )
}

function JobListItem({
  job,
  now,
  settings,
  onOpen,
}: {
  job: JobCard
  now: number
  settings: Tables<"settings"> | undefined
  onOpen: () => void
}) {
  const { t } = useTranslation()
  const ticket = job.service_tickets
  // Defensive: an appointment whose ticket join comes back empty (RLS edge
  // case, stale offline cache) should never crash the list — skip it rather
  // than throw, matching every other list in this app's "state per row" rule.
  if (!ticket) return null
  const address = ticket.addresses
  const addressLine = [address?.door_no, address?.area].filter(Boolean).join(", ")
  const time = formatTime(job.scheduled_at)
  const openVisit = findOpenVisit(ticket.service_visits ?? [])
  // GV.md 1.2 — see JobDetailPage's identical comment; keeps the home list's
  // red state in agreement with the job-detail page's.
  const allowedDuration = openVisit ? computeTicketAllowedDuration(ticket, openVisit, settings) : null
  const overrun = computeJobOverrun(
    { timerStart: openVisit?.timer_start, timerEnd: openVisit?.timer_end, estimatedDurationMinutes: allowedDuration },
    now
  )
  const overdue = isOverdueJob(ticket, now)

  return (
    <button type="button" onClick={onOpen} className="block w-full text-left">
      <Card className={cn("gap-2.5 transition-colors hover:bg-surface-alt", (overdue || overrun.isOverrun) && "border-danger/40 bg-danger/5")}>
        <div className="flex items-start justify-between gap-2 px-1">
          <div className="min-w-0">
            <p className="flex items-center gap-1 truncate text-sm font-semibold text-text">
              {overdue ? <TriangleAlert className="size-3.5 shrink-0 text-danger" /> : null}
              <span className="truncate">{ticket.customers?.name ?? t("technician.home.unknownCustomer")}</span>
            </p>
            <p className="truncate text-xs text-text-muted">{ticket.products?.name ?? ticket.name_of_complaint ?? "—"}</p>
          </div>
          <ChevronRight className="size-4 shrink-0 text-text-muted" />
        </div>
        <div className="flex flex-wrap items-center gap-1.5 px-1">
          <JobTypeBadge type={ticket.type} />
          <PriorityBadge priority={ticket.priority} />
          {overdue ? <OverdueBadge /> : null}
          {job.status === "in_progress" ? (
            <span className="rounded-full bg-info/10 px-2.5 py-0.5 text-xs font-medium text-info">{t("technician.home.inProgress")}</span>
          ) : null}
          {overrun.isOverrun ? <OverrunBadge overrunByMinutes={overrun.overrunByMinutes!} /> : null}
        </div>
        <div className="flex flex-wrap items-center gap-3 px-1 text-xs text-text-muted">
          {time ? <span>{time}</span> : <span>{t("service.appointment.always")}</span>}
          {addressLine ? (
            <span className="flex min-w-0 items-center gap-1">
              <MapPin className="size-3 shrink-0" /> <span className="truncate">{addressLine}</span>
            </span>
          ) : null}
        </div>
        {overdue && ticket.sla_due_at ? (
          <p className="px-1 text-xs font-medium text-danger">{formatOverdueDuration(ticket.sla_due_at, now, t)}</p>
        ) : null}
      </Card>
    </button>
  )
}

export function TechnicianHomePage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { data: profile, isLoading, isError, refetch } = useProfile()
  const technician = useMyTechnician()
  const jobs = useTodaysJobs(technician.data?.id)
  const now = useNowTick()
  const counts = useTodaysJobCounts(profile?.org_id, technician.data?.id)
  const settings = useTechnicianSettings(profile?.org_id)
  const attendance = useTodayAttendance(technician.data?.id)

  if (isLoading || technician.isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError || !profile) {
    return <FullPageError message={t("auth.profileLoadError")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }
  if (technician.isError) {
    return <FullPageError message={t("technician.errors.loadFailed")} onRetry={() => technician.refetch()} retryLabel={t("common.retry")} />
  }

  // Task 1 — a technician who hasn't checked in today (or has already checked
  // out) must not see today's assigned jobs. `attendance.isLoading` guards
  // against a flash of the gate before the first fetch resolves.
  const checkedInToday = !!attendance.data?.check_in_at && !attendance.data?.check_out_at
  const showJobsGate = !attendance.isLoading && !checkedInToday

  const sortedJobs = jobs.data ? sortJobsByPriority(jobs.data, now) : []

  return (
    <div className="space-y-4 pt-2">
      <h1 className="text-xl font-bold text-text">{t("dashboard.welcomeBack", { name: profile.full_name.split(" ")[0] })}</h1>

      <div className="grid grid-cols-2 gap-3">
        <Button type="button" variant="outline" className="h-auto flex-col gap-1.5 py-3" onClick={() => navigate("/technician/spares")}>
          <Wrench className="size-4" />
          {t("technician.home.spareReceipt")}
        </Button>
        <Button type="button" variant="outline" className="h-auto flex-col gap-1.5 py-3" onClick={() => navigate("/technician/search")}>
          <ClipboardList className="size-4" />
          {t("technician.home.searchCustomers")}
        </Button>
      </div>

      {showJobsGate ? (
        <Card className="items-center gap-2 py-8 text-center">
          <CalendarCheck className="size-6 text-text-muted" />
          <p className="text-sm font-medium text-text">{t("technician.home.attendanceRequiredTitle")}</p>
          <p className="text-xs text-text-muted">{t("technician.home.attendanceRequiredBody")}</p>
          <Button type="button" className="mt-2" onClick={() => navigate("/technician/attendance")}>
            {t("technician.home.attendanceRequiredButton")}
          </Button>
        </Card>
      ) : (
        <>
          {/* Requirement 6 — Today's Jobs / Pending / Completed / Cancelled / Overdue counts row. 2-2-1 wrap: first four cells pair up, Overdue spans the full width as the standout danger-tone cell. */}
          <div className="grid grid-cols-2 gap-2">
            <CountCell label={t("technician.home.counts.total")} value={counts.data?.total ?? 0} loading={counts.isLoading} />
            <CountCell label={t("technician.home.counts.pending")} value={counts.data?.pending ?? 0} loading={counts.isLoading} />
            <CountCell label={t("technician.home.counts.completed")} value={counts.data?.completed ?? 0} loading={counts.isLoading} />
            <CountCell label={t("technician.home.counts.cancelled")} value={counts.data?.cancelled ?? 0} loading={counts.isLoading} />
            <CountCell
              label={t("technician.home.counts.overdue")}
              value={counts.data?.overdue ?? 0}
              loading={counts.isLoading}
              danger
              className="col-span-2"
            />
          </div>

          <div className="space-y-2.5">
            <div className="flex items-center justify-between px-1">
              <p className="text-sm font-semibold text-text">{t("technician.home.todaysJobs")}</p>
              {jobs.data && jobs.data.length > 0 ? (
                <span className="text-xs text-text-muted">{t("technician.home.jobCount", { count: jobs.data.length })}</span>
              ) : null}
            </div>

            {jobs.isLoading ? (
              <Card className="items-center py-6 text-center">
                <p className="text-sm text-text-muted">{t("common.loading")}</p>
              </Card>
            ) : jobs.isError ? (
              <FullPageError message={t("technician.errors.loadFailed")} onRetry={() => jobs.refetch()} retryLabel={t("common.retry")} />
            ) : !jobs.data || jobs.data.length === 0 ? (
              <Card className="items-center gap-1 py-6 text-center">
                <p className="text-sm font-medium text-text">{t("technician.home.noJobsTitle")}</p>
                <p className="text-xs text-text-muted">{t("technician.home.noJobsBody")}</p>
              </Card>
            ) : (
              <div className="space-y-2.5">
                {sortedJobs.map((job) => (
                  <JobListItem key={job.id} job={job} now={now} settings={settings.data} onOpen={() => navigate(`/technician/jobs/${job.ticket_id}`)} />
                ))}
              </div>
            )}
          </div>
        </>
      )}
    </div>
  )
}
