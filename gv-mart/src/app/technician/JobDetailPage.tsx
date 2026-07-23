import { useTranslation } from "react-i18next"
import { useNavigate, useParams } from "react-router-dom"
import { CalendarClock, ChevronRight, CheckCircle2, MapPin, Navigation, Phone } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { JobTypeBadge, PriorityBadge } from "./components/JobBadges"
import { useCustomerHistory, useJobDetail, useLogCall, useMyTechnician } from "@/hooks/useTechnician"
import { isChargeableTicketType, isTicketClosed } from "@/services/technician"

function formatDateTime(iso: string | null) {
  if (!iso) return null
  return new Date(iso).toLocaleString("en-IN", { day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit" })
}

export function JobDetailPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { ticketId } = useParams<{ ticketId: string }>()
  const jobDetail = useJobDetail(ticketId)
  // Build Order A3: scoped to the current ticket's product too — see getCustomerHistory doc.
  const history = useCustomerHistory(jobDetail.data?.customer_id, jobDetail.data?.product_id, ticketId)
  const technician = useMyTechnician()
  const logCall = useLogCall()

  if (jobDetail.isLoading) return <FullPageLoader label={t("common.loading")} />
  if (jobDetail.isError || !jobDetail.data) {
    return <FullPageError message={t("technician.errors.loadFailed")} onRetry={() => jobDetail.refetch()} retryLabel={t("common.retry")} />
  }

  const ticket = jobDetail.data
  const appointment = ticket.appointments?.[0]
  const chargeable = isChargeableTicketType(ticket.type)

  return (
    <div className="space-y-4 pt-2">
      <div className="flex items-center justify-between">
        <h1 className="text-xl font-bold text-text">{t("technician.jobDetail.title")}</h1>
        <div className="flex items-center gap-1.5">
          <JobTypeBadge type={ticket.type} />
          <PriorityBadge priority={ticket.priority} />
        </div>
      </div>

      <Card className="gap-3">
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
                {/* D6: past notes + parts changed, not just the date — one block per visit (usually one). */}
                {h.service_visits.map((v) => (
                  <div key={v.id} className="mt-1.5 space-y-1">
                    {v.notes ? (
                      <p className="rounded-lg bg-surface-alt px-2.5 py-1.5 text-xs text-text">
                        <span className="font-medium text-text-muted">{t("technician.jobDetail.historyNotesLabel")}: </span>
                        {v.notes}
                      </p>
                    ) : null}
                    {v.service_spares_used.length > 0 ? (
                      <p className="text-xs text-text-muted">
                        <span className="font-medium">{t("technician.jobDetail.historySparesLabel")}: </span>
                        {v.service_spares_used.map((s) => `${s.spares?.name ?? "—"} × ${s.qty}`).join(", ")}
                      </p>
                    ) : null}
                    {/* Build Order A3: previous technician's voice note, if any, alongside the text note above. */}
                    {v.voice_note_url ? (
                      <div className="rounded-lg bg-surface-alt px-2.5 py-1.5">
                        <p className="mb-1 text-xs font-medium text-text-muted">{t("technician.jobDetail.historyVoiceNoteLabel")}</p>
                        <audio controls src={v.voice_note_url} className="w-full" />
                      </div>
                    ) : null}
                  </div>
                ))}
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
