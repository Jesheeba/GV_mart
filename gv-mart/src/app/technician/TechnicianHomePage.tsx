import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { ChevronRight, ClipboardList, MapPin, Wrench } from "lucide-react"
import { useProfile } from "@/hooks/useProfile"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { Card } from "@/components/ui/card"
import { Button } from "@/components/ui/button"
import { JobTypeBadge, PriorityBadge } from "./components/JobBadges"
import { useMyTechnician, useTodaysJobs } from "@/hooks/useTechnician"
import type { JobCard } from "@/services/technician"

function formatTime(iso: string | null) {
  if (!iso) return null
  return new Date(iso).toLocaleTimeString("en-IN", { hour: "2-digit", minute: "2-digit" })
}

function JobListItem({ job, onOpen }: { job: JobCard; onOpen: () => void }) {
  const { t } = useTranslation()
  const ticket = job.service_tickets
  // Defensive: an appointment whose ticket join comes back empty (RLS edge
  // case, stale offline cache) should never crash the list — skip it rather
  // than throw, matching every other list in this app's "state per row" rule.
  if (!ticket) return null
  const address = ticket.addresses
  const addressLine = [address?.door_no, address?.area].filter(Boolean).join(", ")
  const time = formatTime(job.scheduled_at)

  return (
    <button type="button" onClick={onOpen} className="block w-full text-left">
      <Card className="gap-2.5 transition-colors hover:bg-surface-alt">
        <div className="flex items-start justify-between gap-2 px-1">
          <div className="min-w-0">
            <p className="truncate text-sm font-semibold text-text">{ticket.customers?.name ?? t("technician.home.unknownCustomer")}</p>
            <p className="truncate text-xs text-text-muted">{ticket.products?.name ?? ticket.name_of_complaint ?? "—"}</p>
          </div>
          <ChevronRight className="size-4 shrink-0 text-text-muted" />
        </div>
        <div className="flex flex-wrap items-center gap-1.5 px-1">
          <JobTypeBadge type={ticket.type} />
          <PriorityBadge priority={ticket.priority} />
          {job.status === "in_progress" ? (
            <span className="rounded-full bg-info/10 px-2.5 py-0.5 text-xs font-medium text-info">{t("technician.home.inProgress")}</span>
          ) : null}
        </div>
        <div className="flex flex-wrap items-center gap-3 px-1 text-xs text-text-muted">
          {time ? <span>{time}</span> : <span>{t("service.appointment.always")}</span>}
          {addressLine ? (
            <span className="flex min-w-0 items-center gap-1">
              <MapPin className="size-3 shrink-0" /> <span className="truncate">{addressLine}</span>
            </span>
          ) : null}
        </div>
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

  if (isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError || !profile) {
    return <FullPageError message={t("auth.profileLoadError")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

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
            {jobs.data.map((job) => (
              <JobListItem key={job.id} job={job} onOpen={() => navigate(`/technician/jobs/${job.ticket_id}`)} />
            ))}
          </div>
        )}
      </div>
    </div>
  )
}
