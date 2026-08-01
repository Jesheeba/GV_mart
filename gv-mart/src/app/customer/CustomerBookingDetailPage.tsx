import { useTranslation } from "react-i18next"
import { useNavigate, useParams } from "react-router-dom"
import { ArrowLeft, FileText, ImageIcon, MapPin, Phone, Star } from "lucide-react"
import { Card } from "@/components/ui/card"
import { StatusDot, type StatusTone } from "@/components/shared/StatusDot"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { LiveTracking } from "@/app/customer/components/LiveTracking"
import { CompletionOtpCard } from "@/app/customer/components/CompletionOtpCard"
import { useTicketDetail } from "@/hooks/useCustomerApp"

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
  const { id } = useParams<{ id: string }>()
  const { data: ticket, isLoading, isError, refetch } = useTicketDetail(id)

  if (isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError || !ticket) {
    return <FullPageError message={t("customerApp.bookingDetail.loadError")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  const appt = ticket.appointments?.[0]
  const technician = appt?.technicians
  const visit = ticket.service_visits?.[0]
  const rating = visit?.ratings
  const invoice = ticket.invoices
  const isTrackable = (appt?.status === "scheduled" || appt?.status === "in_progress") && !!technician?.id

  return (
    <div className="space-y-4 pb-4 pt-2">
      <button type="button" onClick={() => navigate("/customer/bookings")} className="flex items-center gap-1.5 text-sm font-medium text-text-muted">
        <ArrowLeft className="size-4" />
        {t("customerApp.bookingDetail.back")}
      </button>

      <Card className="gap-2">
        <div className="flex items-start justify-between px-1">
          <div>
            <p className="text-base font-semibold text-text">
              {ticket.products?.name ?? ticket.name_of_complaint ?? t("customerApp.bookings.generalService")}
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
            {[ticket.addresses.door_no, ticket.addresses.area, ticket.addresses.pincode].filter(Boolean).join(", ")}
          </p>
        ) : null}
      </Card>

      {/* Task 5 (Customer Dashboard Booking Audit, 2026-07-31): show the
          actual appointment details the customer picked — a booking has a
          real date+slot from the moment it's created, so there's no reason
          to show a vague "finding a technician" placeholder once a real
          appointment exists. Slot name/times join live off appointment_slots
          (see getTicketDetail's select), so an admin retiming a slot updates
          this automatically. */}
      {appt?.scheduled_at ? (
        <Card className="gap-1.5">
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
            ) : null}
          </div>
        </Card>
      ) : null}

      {appt?.follow_up_flagged_at ? (
        <Card className="gap-1.5 border-warning/40 bg-warning/10">
          <p className="px-1 text-sm text-warning">{t("customerApp.bookingDetail.followUpNotice")}</p>
        </Card>
      ) : technician ? (
        <Card className="gap-2">
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
        <Card className="gap-2">
          <StatusDot tone="warning" label={t("customerApp.bookingDetail.awaitingAssignment")} />
        </Card>
      ) : null}

      {isTrackable && technician ? (
        <div>
          <h2 className="mb-2 px-1 text-sm font-semibold text-text">{t("customerApp.bookingDetail.liveTracking")}</h2>
          <LiveTracking technicianId={technician.id} technicianName={technician.profiles?.full_name} />
        </div>
      ) : null}

      {visit && !visit.timer_end ? <CompletionOtpCard visitId={visit.id} initialOtp={visit.service_visit_otps ?? null} /> : null}

      {visit && (visit.before_image_url || visit.after_image_url || visit.evidence_photo_urls.length > 0) ? (
        <Card className="gap-2">
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
                  <img src={url} alt="" className="aspect-square w-full rounded-xl object-cover" />
                </a>
              ))}
            </div>
          ) : null}
        </Card>
      ) : null}

      {rating ? (
        <Card className="gap-2">
          <h2 className="px-1 text-sm font-semibold text-text">{t("customerApp.bookingDetail.yourRating")}</h2>
          <div className="flex items-center gap-1 px-1">
            {Array.from({ length: 5 }).map((_, i) => (
              <Star key={i} className={`size-4 ${i < rating.stars ? "fill-warning text-warning" : "text-border"}`} />
            ))}
          </div>
          {rating.review ? <p className="px-1 text-sm text-text-muted">{rating.review}</p> : null}
        </Card>
      ) : null}

      {invoice ? (
        <Card className="gap-2">
          <div className="flex items-center gap-2 px-1">
            <FileText className="size-4 text-text-muted" />
            <h2 className="text-sm font-semibold text-text">{t("customerApp.bookingDetail.invoice")}</h2>
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
    </div>
  )
}
