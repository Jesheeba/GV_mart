import { useEffect, useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate, useParams } from "react-router-dom"
import { ArrowLeft, CalendarClock, ChevronRight, CheckCircle2, MapPin, Navigation, Phone, Route } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { JobTypeBadge, OverrunBadge, PriorityBadge } from "./components/JobBadges"
import { useCustomerHistory, useJobDetail, useLogCall, useMyTechnician, useTechnicianSettings } from "@/hooks/useTechnician"
import { useProfile } from "@/hooks/useProfile"
import { computeJobOverrun } from "@/lib/job-overrun"
import { cn } from "@/lib/utils"
import { computeTicketAllowedDuration, findOpenVisit, isChargeableTicketType, isTicketClosed } from "@/services/technician"

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
  const { data: profile } = useProfile()
  const jobDetail = useJobDetail(ticketId)
  const settings = useTechnicianSettings(profile?.org_id)
  // Build Order A3: scoped to the current ticket's product too — see getCustomerHistory doc.
  const history = useCustomerHistory(jobDetail.data?.customer_id, jobDetail.data?.product_id, ticketId)
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
  // GV.md 1.2: "the technician sees the estimated time for that service...
  // estimated time + review/enquiry allowance is shown as the total allowed
  // time." allowedDuration replaces the ticket's raw estimated_duration_minutes
  // as computeJobOverrun's input — see src/lib/job-allowance.ts.
  const allowedDuration = openVisit ? computeTicketAllowedDuration(ticket, openVisit, settings.data) : null
  const overrun = computeJobOverrun(
    { timerStart: openVisit?.timer_start, timerEnd: openVisit?.timer_end, estimatedDurationMinutes: allowedDuration },
    now
  )
  // Display-only version of the same figure, shown even before a visit
  // starts (GV.md 1.2: "on each job, the technician sees the estimated
  // time for that service") — falls back to the ticket's most recent visit
  // if none is currently open, so a job the technician hasn't started yet
  // still shows a number derived from the type default.
  const displayVisit = openVisit ?? ticket.service_visits[ticket.service_visits.length - 1] ?? null
  const displayAllowedDuration = computeTicketAllowedDuration(ticket, displayVisit, settings.data)
  // Meeting spec D5's "additional contact" is a second number to try, so a
  // member whose number just duplicates the already-shown primary contact
  // doesn't count — prefer the flagged primary member, falling back to the
  // first member, but skip either if it's the same number already on screen.
  // Task 5 (2026-07-30/31) — most recent admin-logged, phone-confirmed
  // availability (exception path on top of unchanged auto-assignment).
  const latestConfirmedCall = [...(appointment?.appointment_availability_calls ?? [])].sort(
    (a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime()
  )[0]
  const members = ticket.customers?.customer_members ?? []
  const preferredMember = members.find((m) => m.is_primary) ?? members[0]
  const additionalContact =
    preferredMember && preferredMember.mobile !== ticket.customers?.mobile
      ? preferredMember
      : members.find((m) => m.mobile !== ticket.customers?.mobile)

  return (
    <div className="space-y-4 pt-2">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <Button type="button" variant="ghost" size="icon-sm" onClick={() => navigate(-1)} aria-label={t("common.back")}>
            <ArrowLeft className="size-4" />
          </Button>
          <h1 className="text-xl font-bold text-text">{t("technician.jobDetail.title")}</h1>
        </div>
        <div className="flex items-center gap-1.5">
          <JobTypeBadge type={ticket.type} />
          <PriorityBadge priority={ticket.priority} />
        </div>
      </div>

      {displayAllowedDuration != null ? (
        <p className="px-1 text-xs text-text-muted">
          {t("technician.jobDetail.allowedTime", { minutes: displayAllowedDuration })}
        </p>
      ) : null}

      {overrun.isOverrun ? (
        <Card className="flex-row items-center gap-2 border-danger/40 bg-danger/5 px-4">
          <OverrunBadge overrunByMinutes={overrun.overrunByMinutes!} />
          <p className="text-xs text-danger">{t("technician.jobDetail.overrunNote")}</p>
        </Card>
      ) : null}

      <Card className={cn("gap-3", overrun.isOverrun && "border-danger/40 bg-danger/5")}>
        <div className="flex items-center justify-between px-1">
          {/* A5(a): the customer's name opens this specific journey's
              colour-coded route (green=on time, yellow=slow/late, red=idle)
              instead of just displaying plain text. */}
          <button
            type="button"
            onClick={() => navigate(`/technician/jobs/${ticketId}/route`)}
            className="flex items-center gap-1 text-left text-base font-semibold text-text underline decoration-dotted underline-offset-4"
          >
            {ticket.customers?.name ?? t("technician.home.unknownCustomer")}
            <Route className="size-3.5 text-text-muted" />
          </button>
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
        {additionalContact ? (
          // Meeting spec D5: "contact + additional contact" — a second
          // household member to try if the primary customer doesn't pick up.
          // Sourced from customer_members (up to 5 per customer, one flagged
          // primary) rather than a new job-specific field — that table
          // already models exactly this, it just wasn't surfaced here yet.
          <p className="flex items-center justify-between gap-2 px-1 text-sm text-text-muted">
            <span className="truncate">{t("technician.jobDetail.additionalContact", { name: additionalContact.name })}</span>
            <a href={`tel:${additionalContact.mobile}`} className="shrink-0">
              <Button type="button" variant="ghost" size="xs">
                <Phone className="size-3.5" />
                {additionalContact.mobile}
              </Button>
            </a>
          </p>
        ) : null}
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
        {latestConfirmedCall ? (
          <p className="mx-1 rounded-xl bg-accent-soft px-3 py-2 text-xs text-accent">
            {t("technician.jobDetail.confirmedAvailability", {
              date: new Date(latestConfirmedCall.confirmed_date).toLocaleDateString("en-IN", { day: "2-digit", month: "short" }),
              from: latestConfirmedCall.confirmed_from.slice(0, 5),
              to: latestConfirmedCall.confirmed_to.slice(0, 5),
            })}
            {latestConfirmedCall.note ? ` — ${latestConfirmedCall.note}` : ""}
          </p>
        ) : null}
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
          {/* Task 4 — arrival confirmation is mandatory. If no visit has been
              started yet (openVisit null), a service_visits row can only be
              created by MapPage's geofence-confirmed arrival flow, so both
              actions route there — collapsed into one CTA so its label
              doesn't promise a checklist screen it can't actually open yet.
              Once a visit exists (arrival already confirmed), split back
              into a plain "Navigate" (map) and "Start Visit" (checklist). */}
          {openVisit ? (
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
          ) : (
            <Button type="button" onClick={() => navigate(`/technician/map?ticketId=${ticketId}`)}>
              <Navigation className="size-4" />
              {t("technician.jobDetail.navigateConfirmArrival")}
            </Button>
          )}
        </>
      )}
    </div>
  )
}
