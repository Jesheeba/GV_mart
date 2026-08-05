import { useTranslation } from "react-i18next"
import { Check, Clock } from "lucide-react"

/** Minimal top-of-page mini-timeline for the pre-assignment state (spec's
 * Stage 1) — the rest of that view is deliberately unchanged, this is just
 * the "Booking Confirmed → Waiting for Technician" strip. */
export function BookingConfirmedStrip() {
  const { t } = useTranslation()
  return (
    <div className="flex items-center gap-2.5 rounded-xl border border-border bg-surface-alt/50 px-3.5 py-3">
      <div className="flex flex-col items-center gap-1">
        <span className="flex size-6 shrink-0 items-center justify-center rounded-full bg-success/15 text-success">
          <Check className="size-3.5" />
        </span>
        <span className="text-[10px] font-medium text-text-muted">{t("customerApp.tracking.timeline.bookingConfirmed")}</span>
      </div>
      <div className="h-0.5 flex-1 bg-border" />
      <div className="flex flex-col items-center gap-1">
        <span className="flex size-6 shrink-0 items-center justify-center rounded-full bg-accent/15 text-accent">
          <Clock className="size-3.5 animate-pulse" />
        </span>
        <span className="text-[10px] font-medium text-text">{t("customerApp.tracking.waitingForTechnician")}</span>
      </div>
    </div>
  )
}
