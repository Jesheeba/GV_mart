import { useCallback, useEffect, useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate, useParams } from "react-router-dom"
import { ArrowLeft, FileText, ImageIcon, Loader2, MapPin, Phone, Printer, Star } from "lucide-react"
import { Card } from "@/components/ui/card"
import { Button } from "@/components/ui/button"
import { StatusDot, type StatusTone } from "@/components/shared/StatusDot"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { useToast } from "@/components/ui/toast-context"
import { CompletionOtpCard } from "@/app/customer/components/CompletionOtpCard"
import { PaymentStatusCard } from "@/app/customer/components/PaymentStatusCard"
import { TrackingMap } from "@/app/customer/components/tracking/TrackingMap"
import { RouteInfoCard } from "@/app/customer/components/tracking/RouteInfoCard"
import { TrackingSheet } from "@/app/customer/components/tracking/TrackingSheet"
import { ArrivalCelebration } from "@/app/customer/components/tracking/ArrivalCelebration"
import { CompletionScreen } from "@/app/customer/components/tracking/CompletionScreen"
import { BookingConfirmedStrip } from "@/app/customer/components/tracking/BookingConfirmedStrip"
import { useTicketDetail, useSubmitCustomerRating, useTechnicianPublicStats, useCustomerAppSettings } from "@/hooks/useCustomerApp"
import { useLiveTracking } from "@/hooks/useLiveTracking"
import type { RouteInfo } from "@/app/customer/components/tracking/TrackingMap"

const STATUS_TONE: Record<string, StatusTone> = {
  open: "warning",
  assigned: "info",
  in_progress: "warning",
  completed: "success",
  cancelled: "neutral",
}

const PAYMENT_STATUS_TONE: Record<string, StatusTone> = { paid: "success", partial: "warning", due: "danger" }

function formatCurrency(amount: number) {
  return new Intl.NumberFormat("en-IN", { style: "currency", currency: "INR", maximumFractionDigits: 0 }).format(amount)
}

export function CustomerBookingDetailPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { toast } = useToast()
  const { id } = useParams<{ id: string }>()
  const { data: ticket, isLoading, isError, refetch } = useTicketDetail(id)

  const appt = ticket?.appointments?.[0]
  const technician = appt?.technicians
  const visit = ticket?.service_visits?.[0]
  const rating = visit?.ratings
  const invoice = ticket?.invoices
  const isTrackable = (appt?.status === "scheduled" || appt?.status === "in_progress") && !!technician?.id

  const settings = useCustomerAppSettings(ticket?.org_id)
  // v2.2 Design Deltas #3 / settings.review_link_min_stars, same threshold
  // the technician's in-person RatingPage uses — admin-set in Masters &
  // Settings, not hardcoded.
  const reviewLinkMinStars = settings.data?.review_link_min_stars ?? 5
  const reviewUrl = settings.data?.google_review_url || null
  const showReviewLink = !!rating && rating.stars >= reviewLinkMinStars

  const destination = useMemo(
    () => (ticket?.addresses?.lat != null && ticket?.addresses?.lng != null ? { lat: ticket.addresses.lat, lng: ticket.addresses.lng } : null),
    [ticket?.addresses?.lat, ticket?.addresses?.lng]
  )

  const stats = useTechnicianPublicStats(isTrackable ? technician?.id : undefined)
  const tracking = useLiveTracking({
    technicianId: isTrackable ? technician?.id : undefined,
    destination,
    stageInput: {
      ticketStatus: (ticket?.status ?? "open") as "open" | "assigned" | "in_progress" | "completed" | "cancelled",
      hasTechnician: !!technician?.id,
      visitStarted: !!visit?.timer_start,
      visitEnded: !!visit?.timer_end,
    },
  })

  // Source of truth for ETA/distance is now the map's own DirectionsService
  // call (see TrackingMap's onRouteInfo) — "Display ETA and Distance from
  // the Directions response instead of calculating them manually." Falls
  // back to the haversine distanceKm useLiveTracking already computes for
  // the "nearby" threshold, only until the first real route response lands.
  const [routeInfo, setRouteInfo] = useState<RouteInfo>({ distanceKm: null, durationMinutes: null, routeError: null })
  const handleRouteInfo = useCallback((info: RouteInfo) => setRouteInfo(info), [])
  const distanceKm = routeInfo.distanceKm ?? tracking.distanceKm
  // True whenever what's on screen is the haversine straight-line fallback
  // rather than a real Directions API response — most persistently once
  // routeError is set (e.g. REQUEST_DENIED), which never recovers on its
  // own, so a wrong-looking-real number should never be shown as if it were
  // a routed distance.
  const isApproximateDistance = distanceKm != null && routeInfo.distanceKm == null
  // DirectionsService legitimately can (and does) return ZERO_RESULTS when
  // origin/destination are only a few dozen meters apart — there's no
  // meaningful multi-step route to compute at that range. Rather than leave
  // the ETA blank forever in exactly the moment a customer cares most ("is
  // he here yet?"), floor it to "under a minute" once we're this close,
  // regardless of whether Directions could resolve a route.
  const etaMinutes = routeInfo.durationMinutes ?? (routeInfo.routeError && distanceKm != null && distanceKm <= 0.15 ? 1 : null)

  const etaWindowLabel = useMemo(() => {
    if (etaMinutes == null) return null
    const now = Date.now()
    const fmt = (d: Date) => d.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })
    return `${fmt(new Date(now + etaMinutes * 60_000))} - ${fmt(new Date(now + etaMinutes * 60_000 * 1.15))}`
  }, [etaMinutes])

  const [celebrationVisible, setCelebrationVisible] = useState(false)
  useEffect(() => {
    if (tracking.arrivalSignal > 0) setCelebrationVisible(true)
  }, [tracking.arrivalSignal])

  const [ratingStars, setRatingStars] = useState(0)
  const [ratingReview, setRatingReview] = useState("")
  const submitRating = useSubmitCustomerRating()

  if (isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError || !ticket) {
    return <FullPageError message={t("customerApp.bookingDetail.loadError")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  function handleCall() {
    if (technician?.profiles?.phone) window.location.href = `tel:${technician.profiles.phone}`
  }
  async function handleShare() {
    const url = window.location.href
    if (navigator.share) {
      try {
        await navigator.share({ title: t("customerApp.tracking.shareTitle"), url })
      } catch {
        // user cancelled the native share sheet — nothing to do
      }
      return
    }
    await navigator.clipboard.writeText(url)
    toast.success(t("customerApp.tracking.linkCopied"))
  }
  function handleSubmitRating() {
    if (!ticket || !visit || ratingStars < 1) return
    submitRating.mutate({ orgId: ticket.org_id, visitId: visit.id, stars: ratingStars, review: ratingReview.trim() || null })
  }

  const addressLabel = ticket.addresses
    ? [ticket.addresses.door_no, ticket.addresses.area, ticket.addresses.pincode].filter(Boolean).join(", ")
    : "—"

  return (
    <div className="space-y-4 pb-4 pt-2">
      <button type="button" onClick={() => navigate("/customer/bookings")} className="flex items-center gap-1.5 text-sm font-medium text-text-muted">
        <ArrowLeft className="size-4" />
        {t("customerApp.bookingDetail.back")}
      </button>

      {ticket.status === "completed" ? (
        <CompletionScreen technicianName={technician?.profiles?.full_name ?? null} onBookAgain={() => navigate("/customer/book-service")} />
      ) : null}

      <Card className="gap-2 lg:px-5 print:hidden">
        <div className="flex items-start justify-between px-1">
          <div>
            <p className="text-base font-semibold text-text">
              {ticket.products?.name ?? ticket.unlisted_product_name ?? ticket.name_of_complaint ?? t("customerApp.bookings.generalService")}
            </p>
            <p className="text-xs text-text-muted">{[ticket.brands?.name, ticket.models?.name].filter(Boolean).join(" · ")}</p>
          </div>
          <StatusDot tone={STATUS_TONE[ticket.status] ?? "neutral"} label={t(`customerApp.bookings.status.${ticket.status}`)} />
        </div>
        {ticket.name_of_complaint ? (
          <p className="px-1 text-sm text-text">
            <span className="text-text-muted">{t("customerApp.bookingDetail.complaint")}: </span>
            {ticket.name_of_complaint}
          </p>
        ) : null}
        {ticket.addresses ? (
          <p className="flex items-start gap-1.5 px-1 text-xs text-text-muted">
            <MapPin className="mt-0.5 size-3.5 shrink-0" />
            {addressLabel}
          </p>
        ) : null}
      </Card>

      {!invoice && ticket.status !== "cancelled" ? (
        <Card className="gap-1.5 bg-surface-alt lg:px-5 print:hidden">
          <div className="flex items-center gap-2 px-1">
            <FileText className="size-4 text-text-muted" />
            <h2 className="text-sm font-semibold text-text">{t("customerApp.bookingDetail.pricingInfoTitle")}</h2>
          </div>
          <p className="px-1 text-xs text-text-muted">{t("customerApp.bookingDetail.pricingInfoBody")}</p>
        </Card>
      ) : null}

      {appt?.scheduled_at ? (
        <Card className="gap-1.5 lg:px-5 print:hidden">
          <h2 className="px-1 text-sm font-semibold text-text">{t("customerApp.bookingDetail.appointmentTitle")}</h2>
          <div className="grid grid-cols-2 gap-y-1 px-1 text-sm">
            <span className="text-text-muted">{t("customerApp.bookingDetail.appointmentDate")}</span>
            <span className="text-text">{new Date(appt.scheduled_at).toLocaleDateString(undefined, { dateStyle: "medium" })}</span>
            {appt.appointment_slots ? (
              <>
                <span className="text-text-muted">{t("customerApp.bookingDetail.appointmentSlot")}</span>
                <span className="text-text">{appt.appointment_slots.name}</span>
                <span className="text-text-muted">{t("customerApp.bookingDetail.estimatedVisitTime")}</span>
                <span className="text-text">
                  {appt.appointment_slots.start_time.slice(0, 5)}–{appt.appointment_slots.end_time.slice(0, 5)}
                </span>
              </>
            ) : appt.available_from ? (
              <>
                <span className="text-text-muted">{t("customerApp.bookingDetail.estimatedVisitTime")}</span>
                <span className="text-text">
                  {appt.available_from.slice(0, 5)}–{(appt.available_to ?? "").slice(0, 5)}
                </span>
              </>
            ) : null}
          </div>
          {appt.is_narrow_window || appt.next_day_priority ? (
            <div className="flex flex-wrap gap-1.5 px-1 pt-1">
              {appt.is_narrow_window ? (
                <span className="rounded-full bg-warning/15 px-2.5 py-1 text-xs font-medium text-warning">{t("service.detail.narrowWindowBadge")}</span>
              ) : null}
              {appt.next_day_priority ? (
                <span className="rounded-full bg-warning/15 px-2.5 py-1 text-xs font-medium text-warning">{t("service.detail.nextDayPriorityBadge")}</span>
              ) : null}
            </div>
          ) : null}
        </Card>
      ) : null}

      {appt?.follow_up_flagged_at ? (
        <Card className="gap-1.5 border-warning/40 bg-warning/10 lg:px-5 print:hidden">
          <p className="px-1 text-sm text-warning">{t("customerApp.bookingDetail.followUpNotice")}</p>
        </Card>
      ) : technician && isTrackable ? (
        <div className="space-y-3 print:hidden">
          <RouteInfoCard
            stage={tracking.stage}
            etaMinutes={etaMinutes}
            distanceKm={distanceKm}
            isApproximateDistance={isApproximateDistance}
            statusLabel={t(`customerApp.tracking.stage.${tracking.stage}`)}
            routeError={routeInfo.routeError}
          />
          <TrackingMap
            technicianPosition={tracking.position}
            rawTechnicianPosition={tracking.rawPosition}
            bearingDeg={tracking.bearingDeg}
            destination={destination}
            stage={tracking.stage}
            onRouteInfo={handleRouteInfo}
            className="h-[42vh] rounded-3xl border border-border"
          />
          <TrackingSheet
            technicianName={technician.profiles?.full_name ?? t("customerApp.bookingDetail.assignedTechnician")}
            technicianPhone={technician.profiles?.phone ?? null}
            technicianSkills={technician.skills ?? []}
            avgRating={stats.data?.avg_rating ?? null}
            completedCount={stats.data?.completed_count ?? null}
            stage={tracking.stage}
            statusLabel={t(`customerApp.tracking.stage.${tracking.stage}`)}
            etaMinutes={etaMinutes}
            etaWindowLabel={etaWindowLabel}
            distanceKm={distanceKm}
            connectionState={tracking.connectionState}
            addressLabel={addressLabel}
            onCall={handleCall}
            onShare={handleShare}
          />
        </div>
      ) : technician ? (
        <Card className="gap-2 lg:px-5 print:hidden">
          <h2 className="px-1 text-sm font-semibold text-text">{t("customerApp.bookingDetail.technician")}</h2>
          <div className="flex items-center justify-between px-1">
            <p className="text-sm text-text">{technician.profiles?.full_name ?? t("customerApp.bookingDetail.assignedTechnician")}</p>
            {technician.profiles?.phone ? (
              <a href={`tel:${technician.profiles.phone}`} className="flex items-center gap-1 text-xs font-medium text-accent">
                <Phone className="size-3.5" />
                {technician.profiles.phone}
              </a>
            ) : null}
          </div>
        </Card>
      ) : appt && ticket.status !== "completed" && ticket.status !== "cancelled" ? (
        <div className="space-y-2 print:hidden">
          <BookingConfirmedStrip />
          <Card className="gap-2 lg:px-5">
            <StatusDot tone="warning" label={t("customerApp.bookingDetail.awaitingAssignment")} />
          </Card>
        </div>
      ) : null}

      {visit && !visit.timer_end && invoice && invoice.payment_method === "upi" && invoice.payment_status !== "paid" ? (
        <PaymentStatusCard orgId={ticket.org_id} invoiceId={invoice.id} invoiceTotal={invoice.total} initialPaymentStatus={invoice.payment_status} />
      ) : null}

      {visit && !visit.timer_end ? <CompletionOtpCard visitId={visit.id} initialOtp={visit.service_visit_otps ?? null} /> : null}

      {visit && (visit.before_image_url || visit.after_image_url || visit.evidence_photo_urls.length > 0) ? (
        <Card className="gap-2 lg:px-5">
          <h2 className="px-1 text-sm font-semibold text-text">{t("customerApp.bookingDetail.serviceImages")}</h2>
          <div className="grid grid-cols-2 gap-2 px-1">
            {visit.before_image_url ? (
              <a href={visit.before_image_url} target="_blank" rel="noreferrer" className="space-y-1">
                <img src={visit.before_image_url} alt={t("customerApp.bookingDetail.before")} className="aspect-square w-full rounded-xl object-cover" />
                <p className="text-center text-xs text-text-muted">{t("customerApp.bookingDetail.before")}</p>
              </a>
            ) : (
              <div className="flex aspect-square flex-col items-center justify-center gap-1 rounded-xl border border-dashed border-border text-text-muted">
                <ImageIcon className="size-5" />
                <p className="text-xs">{t("customerApp.bookingDetail.before")}</p>
              </div>
            )}
            {visit.after_image_url ? (
              <a href={visit.after_image_url} target="_blank" rel="noreferrer" className="space-y-1">
                <img src={visit.after_image_url} alt={t("customerApp.bookingDetail.after")} className="aspect-square w-full rounded-xl object-cover" />
                <p className="text-center text-xs text-text-muted">{t("customerApp.bookingDetail.after")}</p>
              </a>
            ) : (
              <div className="flex aspect-square flex-col items-center justify-center gap-1 rounded-xl border border-dashed border-border text-text-muted">
                <ImageIcon className="size-5" />
                <p className="text-xs">{t("customerApp.bookingDetail.after")}</p>
              </div>
            )}
          </div>
          {visit.evidence_photo_urls.length > 0 ? (
            <div className="grid grid-cols-3 gap-2 px-1">
              {visit.evidence_photo_urls.map((url, i) => (
                <a key={i} href={url} target="_blank" rel="noreferrer">
                  <img
                    src={url}
                    alt={t("customerApp.bookingDetail.evidencePhoto", { index: i + 1 })}
                    className="aspect-square w-full rounded-xl object-cover"
                  />
                </a>
              ))}
            </div>
          ) : null}
        </Card>
      ) : null}

      {rating ? (
        <Card className="gap-2 lg:px-5 print:hidden">
          <h2 className="px-1 text-sm font-semibold text-text">{t("customerApp.bookingDetail.yourRating")}</h2>
          <div className="flex items-center gap-1 px-1">
            {Array.from({ length: 5 }).map((_, i) => (
              <Star key={i} className={`size-4 ${i < rating.stars ? "fill-warning text-warning" : "text-border"}`} />
            ))}
          </div>
          {rating.review ? <p className="px-1 text-sm text-text-muted">{rating.review}</p> : null}
          {showReviewLink ? (
            reviewUrl ? (
              <a href={reviewUrl} target="_blank" rel="noreferrer" className="mx-1 mt-1 w-fit">
                <Button type="button" size="sm">{t("customerApp.bookingDetail.googleReviewButton")}</Button>
              </a>
            ) : (
              <p className="px-1 text-xs text-text-muted">{t("customerApp.bookingDetail.googleReviewLinkMissing")}</p>
            )
          ) : null}
        </Card>
      ) : ticket.status === "completed" && visit ? (
        <Card className="gap-2.5 lg:px-5 print:hidden">
          <h2 className="px-1 text-sm font-semibold text-text">{t("customerApp.bookingDetail.yourRating")}</h2>
          <div className="flex items-center gap-1.5 px-1">
            {Array.from({ length: 5 }).map((_, i) => (
              <button key={i} type="button" onClick={() => setRatingStars(i + 1)} aria-label={t("customerApp.tracking.rateStars", { count: i + 1 })}>
                <Star className={`size-7 transition-colors ${i < ratingStars ? "fill-warning text-warning" : "text-border"}`} />
              </button>
            ))}
          </div>
          <textarea
            value={ratingReview}
            onChange={(e) => setRatingReview(e.target.value)}
            placeholder={t("customerApp.tracking.reviewPlaceholder")}
            rows={3}
            className="mx-1 rounded-xl border border-border bg-surface px-3.5 py-2.5 text-sm text-text outline-none placeholder:text-text-muted focus-visible:border-ring"
          />
          {submitRating.isError ? <p className="px-1 text-xs text-danger">{t("customerApp.tracking.ratingFailed")}</p> : null}
          <Button type="button" className="mx-1 w-fit" disabled={ratingStars < 1 || submitRating.isPending} onClick={handleSubmitRating}>
            {submitRating.isPending ? <Loader2 className="size-4 animate-spin" /> : t("customerApp.tracking.submitRating")}
          </Button>
        </Card>
      ) : null}

      {invoice ? (
        <Card className="gap-2 lg:px-5 print:shadow-none">
          <div className="flex items-center justify-between px-1">
            <div className="flex items-center gap-2">
              <FileText className="size-4 text-text-muted" />
              <h2 className="text-sm font-semibold text-text">{t("customerApp.bookingDetail.invoice")}</h2>
            </div>
            <Button type="button" variant="outline" size="sm" className="print:hidden" onClick={() => window.print()}>
              <Printer className="size-3.5" />
              {t("customerApp.tracking.printInvoice")}
            </Button>
          </div>
          <div className="space-y-1 px-1 text-sm">
            <div className="flex justify-between text-text-muted">
              <span>{t("customerApp.bookingDetail.invoiceSubtotal")}</span>
              <span>{formatCurrency(invoice.subtotal)}</span>
            </div>
            {invoice.discount > 0 ? (
              <div className="flex justify-between text-danger">
                <span>{t("customerApp.bookingDetail.invoiceDiscount")}</span>
                <span>−{formatCurrency(invoice.discount)}</span>
              </div>
            ) : null}
            <div className="flex justify-between text-text-muted">
              <span>{t("customerApp.bookingDetail.invoiceGst")}</span>
              <span>{formatCurrency(invoice.gst)}</span>
            </div>
            <div className="flex justify-between border-t border-border pt-1 font-semibold text-text">
              <span>{t("customerApp.bookingDetail.invoiceTotal")}</span>
              <span>{formatCurrency(invoice.total)}</span>
            </div>
          </div>
          <div className="flex items-center justify-between px-1">
            <StatusDot tone={PAYMENT_STATUS_TONE[invoice.payment_status] ?? "neutral"} label={t(`customerApp.bookingDetail.paymentStatus.${invoice.payment_status}`)} />
            {invoice.txn_id ? <span className="text-xs text-text-muted">{t("customerApp.bookingDetail.txnId", { id: invoice.txn_id })}</span> : null}
          </div>
        </Card>
      ) : null}

      <ArrivalCelebration
        visible={celebrationVisible}
        onClose={() => setCelebrationVisible(false)}
        technicianName={technician?.profiles?.full_name}
      />
    </div>
  )
}
