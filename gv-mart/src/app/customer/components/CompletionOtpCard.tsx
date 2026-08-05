import { useEffect, useState } from "react"
import { useTranslation } from "react-i18next"
import { CheckCircle2, KeyRound } from "lucide-react"
import { Card } from "@/components/ui/card"
import { supabase } from "@/lib/supabase"

export type VisitOtpInfo = {
  code: string | null
  generated_at: string
  expires_at: string
  verified_at: string | null
} | null

/**
 * GV.md §2 — "OTP generated in the customer app per work order; customer
 * gives it to the technician to confirm completion." This is the code
 * display. Realtime-subscribed (same postgres_changes pattern as
 * LiveTracking.tsx's technician_locations widget) on top of
 * CustomerBookingDetailPage's own ticket-detail poll, so the code shows up
 * within moments of the technician reaching the Payment step rather than
 * waiting up to the poll's 20s interval.
 *
 * RLS (service_visit_otps_select_customer,
 * 20260725110000_otp_completion_confirmation.sql) already restricts what
 * this customer can ever see to their own ticket's own visit row — safe to
 * mount for any visitId that came from this customer's own ticket data.
 *
 * Renders nothing when there's no code yet (`code` null — either no OTP
 * generated yet, or the visit was completed via admin override, which the
 * customer's own column selection can't distinguish from "not started" and
 * has no reason to surface either way).
 */
export function CompletionOtpCard({ visitId, initialOtp }: { visitId: string; initialOtp: VisitOtpInfo }) {
  const { t } = useTranslation()
  const [otp, setOtp] = useState<VisitOtpInfo>(initialOtp)
  const [now, setNow] = useState(() => Date.now())

  useEffect(() => {
    setOtp(initialOtp)
  }, [initialOtp])

  useEffect(() => {
    const interval = setInterval(() => setNow(Date.now()), 30_000)
    return () => clearInterval(interval)
  }, [])

  useEffect(() => {
    const channel = supabase
      .channel(`visit-otp-${visitId}`)
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "service_visit_otps", filter: `visit_id=eq.${visitId}` },
        (payload) => setOtp(payload.new as VisitOtpInfo)
      )
      .subscribe()

    return () => {
      supabase.removeChannel(channel)
    }
  }, [visitId])

  if (!otp || !otp.code) return null

  const isExpired = new Date(otp.expires_at).getTime() <= now
  const isVerified = !!otp.verified_at

  return (
    <Card className="gap-2 lg:px-5">
      <div className="flex items-center gap-2 px-1">
        <KeyRound className="size-4 text-text-muted" />
        <h2 className="text-sm font-semibold text-text">{t("customerApp.bookingDetail.otpTitle")}</h2>
      </div>
      <div role="status" aria-live="polite">
        {isVerified ? (
          <p className="flex items-center gap-1.5 px-1 text-sm text-success">
            <CheckCircle2 className="size-4" /> {t("customerApp.bookingDetail.otpVerified")}
          </p>
        ) : isExpired ? (
          <p className="px-1 text-sm text-warning">{t("customerApp.bookingDetail.otpExpired")}</p>
        ) : (
          <>
            <p
              className="px-1 text-center font-mono text-3xl font-bold tracking-[0.5em] text-text"
              aria-label={otp.code.split("").join(" ")}
            >
              {otp.code}
            </p>
            <p className="px-1 text-xs text-text-muted">{t("customerApp.bookingDetail.otpHint")}</p>
            <p className="px-1 text-xs text-text-muted">
              {t("customerApp.bookingDetail.otpExpiresAt", { time: new Date(otp.expires_at).toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" }) })}
            </p>
          </>
        )}
      </div>
    </Card>
  )
}
