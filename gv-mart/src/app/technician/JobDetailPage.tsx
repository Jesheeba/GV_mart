import { useEffect, useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate, useParams } from "react-router-dom"
import { CalendarClock, ChevronRight, CheckCircle2, MapPin, Navigation, Phone } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { JobTypeBadge, OverrunBadge, PriorityBadge } from "./components/JobBadges"
import { useCustomerHistory, useJobDetail, useLogCall, useMyTechnician } from "@/hooks/useTechnician"
import { computeJobOverrun } from "@/lib/job-overrun"
import { cn } from "@/lib/utils"
import { findOpenVisit, isChargeableTicketType, isTicketClosed } from "@/services/technician"

function formatDateTime(iso: string | null) {
  if (!iso) return null
  return new Date(iso).toLocaleString("en-IN", { day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit" })
}

/** Re-renders every 30s so an in-progress visit's overrun state (Build Order A4)
 *  flips to red without the technician needing to leave and reopen the page —
 *  same "poll a tick, no websocket needed" shape as OnSiteVisitPage's own
 *  1s elapsed-time interval, just coarser since a badge doesn't need second precision. */
function useNowTick(enabled: boolean, intervalMs = 30_000) {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    if (!enabled) return
    const id = setInterval(() => setNow(Date.now()), intervalMs)
    return () => clearInterval(id)
  }, [enabled, intervalMs])
  return now
}

export function JobDetailPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { ticketId } = useParams<{ ticketId: string }>()
  const jobDetail = useJobDetail(ticketId)
  const history = useCustomerHistory(jobDetail.data?.customer_id, ticketId)
  const technician = useMyTechnician()
  const logCall = useLogCall()

  const openVisit = jobDetail.data ? findOpenVisit(jobDetail.data.service_visits) : null
  const now = useNowTick(!!openVisit)

  if (jobDetail.isLoading) return <FullPageLoader label={t("common.loading")} />
  if (jobDetail.isError || !jobDetail.data) {
    return <FullPageError message={t("technician.errors.loadFailed")} onRetry={() => jobDetail.refetch()} retryLabel={t("common.retry")} />
  }

  const ticket = jobDetail.data
  const appointment = ticket.appointments?.[0]
  const chargeable = isChargeableTicketType(ticket.type)
  const overrun = computeJobOverrun(
    { timerStart: openVisit?.timer_start, timerEnd: openVisit?.timer_end, estimatedDurationMinutes: ticket.estimated_duration_minutes },
    now
  )

  return (
    <div className="space-y-4 pt-2">
      <div className="flex items-center justify-between">
        <h1 className="text-xl font-bold text-text">{t("technician.jobDetail.title")}</h1>
        <div className="flex items-center gap-1.5">
          <JobTypeBadge type={ticket.type} />
          <PriorityBadge priority={ticket.priority} />
        </div>
      </div>

      {overrun.isOverrun ? (
        <Card className="flex-row items-center gap-2 border-danger/40 bg-danger/5 px-4">
          <OverrunBadge overrunByMinutes={overrun.overrunByMinutes!} />
          <p className="text-xs text-danger">{t("technician.jobDetail.overrunNote")}</p>
        </Card>
      ) : null}

      <Card className={cn("gap-3", overrun.isOverrun && "border-danger/40 bg-danger/5")}>
        <div className="flex items-center justify-between px-1">
          <p className="text-base font-semibold text-text">{ticket.customers?.name ?? t("technician.home.unknownCustomer")}</p>
          {ticket.customers?.mobile ? (
            <a
              href={`tel:${ticket.customers.mobile}`}
              onClick={() => logCall.mutate({ orgId: ticket.org_id, technicianId: technician.data?.id ?? null, customerId: ticket.customers!.id, ticketId: ticket.id })}
            >
              <Button type="button" variant="outline" size="xs">
                <Phone className="size-3.5" />
                {t("technician.search.call")}
              </Button>
            </a>
          ) : null}
        </div>
        <p className="flex items-start gap-1.5 px-1 text-sm text-text-muted">
          <MapPin className="mt-0.5 size-3.5 shrink-0" />
          <span>{[ticket.addresses?.door_no, ticket.addresses?.flat_no, ticket.addresses?.street_cross, ticket.addresses?.area, ticket.addresses?.pincode].filter(Boolean).join(", ") || "—"}</span>
        </p>
        <p className="flex items-center gap-1.5 px-1 text-sm text-text-muted">
          <CalendarClock className="size-3.5 shrink-0" />
          {appointment?.mode === "always"
            ? t("technician.jobDetail.availabilityAlways")
            : appointment?.scheduled_at
              ? t("technician.jobDetail.appointmentAt", { time: formatDateTime(appointment.scheduled_at) })
              : t("technician.jobDetail.noAppointment")}
        </p>
      </Card>

      <Card className="gap-2">
        <p className="px-1 text-sm font-semibold text-text">{t("technician.jobDetail.productTitle")}</p>
        <div className="grid grid-cols-2 gap-y-2 px-1 text-sm">
          <span className="text-text-muted">{t("technician.jobDetail.product")}</span>
          <span className="text-text">{ticket.products?.name ?? "—"}</span>
          <span className="text-text-muted">{t("technician.jobDetail.brand")}</span>
          <span className="text-text">{ticket.brands?.name ?? "—"}</span>
          <span className="text-text-muted">{t("technician.jobDetail.model")}</span>
          <span className="text-text">{ticket.models?.name ?? "—"}</span>
        </div>
      </Card>

      <Card className="gap-2">
        <p className="px-1 text-sm font-semibold text-text">{t("technician.jobDetail.complaintTitle")}</p>
        <p className="px-1 text-sm text-text">{ticket.name_of_complaint ?? "—"}</p>
        {ticket.nature_of_complaint ? <p className="px-1 text-xs text-text-muted">{ticket.nature_of_complaint}</p> : null}
      </Card>

      <Card className="gap-2">
        <p className="px-1 text-sm font-semibold text-text">{t("technician.jobDetail.costingRuleTitle")}</p>
        <p className="px-1 text-xs text-text-muted">
          {chargeable ? t("technician.jobDetail.costingRulePaid") : t("technician.jobDetail.costingRuleFree")}
        </p>
      </Card>

      <Card className="gap-2.5">
        <p className="px-1 text-sm font-semibold text-text">{t("technician.jobDetail.historyTitle")}</p>
        {history.isLoading ? (
          <p className="px-1 text-sm text-text-muted">{t("common.loading")}</p>
        ) : history.isError ? (
          <p className="px-1 text-sm text-danger">{t("technician.errors.loadFailed")}</p>
        ) : !history.data || history.data.length === 0 ? (
          <p className="px-1 text-sm text-text-muted">{t("technician.jobDetail.noHistory")}</p>
        ) : (
          <ol className="space-y-3 border-l border-border pl-3.5">
            {history.data.map((h) => (
              <li key={h.id} className="relative">
                <span className="absolute -left-[19px] top-1 size-2 rounded-full bg-accent" />
                <p className="text-sm font-medium text-text">{h.name_of_complaint ?? "—"}</p>
                <p className="text-xs text-text-muted">
                  {new Date(h.created_at).toLocaleDateString("en-IN", { day: "2-digit", month: "short", year: "numeric" })} · {t(`service.type.${h.type ?? "paid"}`)} · {t(`service.status.${h.status}`)}
                </p>
              </li>
            ))}
          </ol>
        )}
      </Card>

      {isTicketClosed(ticket.status) ? (
        <Card className="items-center gap-1.5 py-6 text-center">
          <CheckCircle2 className="size-7 text-success" />
          <p className="text-sm font-medium text-text">{t("technician.jobDetail.closedTitle")}</p>
          <p className="text-xs text-text-muted">{t(`service.status.${ticket.status}`)}</p>
        </Card>
      ) : (
        <>
          <Button type="button" variant="outline" onClick={() => navigate(`/technician/map?ticketId=${ticketId}`)}>
            <Navigation className="size-4" />
            {t("technician.jobDetail.navigate")}
          </Button>
          <Button type="button" onClick={() => navigate(`/technician/jobs/${ticketId}/visit`)}>
            {t("technician.jobDetail.startVisit")}
            <ChevronRight className="size-4" />
          </Button>
        </>
      )}
      <Button type="button" variant="outline" onClick={() => navigate(-1)}>
        {t("common.back")}
      </Button>
    </div>
  )
}
