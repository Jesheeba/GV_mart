import { useEffect, useRef, useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { KeyRound, X } from "lucide-react"
import { supabase } from "@/lib/supabase"

type OtpRow = { visit_id: string; code: string | null; verified_at: string | null }

/**
 * Technician Module Audit, Task 7 — the OTP itself is already fully built
 * (CompletionOtpCard.tsx shows the live code on the booking detail page),
 * but nothing previously alerted the customer to go look at that screen —
 * real WhatsApp/SMS send is a known, deliberately-deferred stub elsewhere
 * in this repo pending the client's Meta App Review + business number, so
 * that's out of scope here. This is the in-app substitute: an app-wide
 * banner, mounted once at the shell level (not per-booking-page like
 * CompletionOtpCard), that fires the moment a code is generated no matter
 * which screen the customer is currently on.
 *
 * Subscribes to the whole `service_visit_otps` table with no visit_id
 * filter — safe because Supabase Realtime enforces the same RLS policy
 * (`service_visit_otps_select_customer`) on postgres_changes as on a normal
 * select, so this customer's session only ever receives their own rows.
 */
export function OtpAlertBanner() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const [pending, setPending] = useState<{ ticketId: string; visitId: string } | null>(null)
  // Visits already shown-and-dismissed (or navigated to, or verified) this
  // session, so the banner doesn't keep reappearing for the same code —
  // per-session is enough; a genuinely new code (Resend) is a fresh INSERT/
  // UPDATE with a new generated_at, handled by the effect below re-showing.
  const handledRef = useRef<Set<string>>(new Set())

  useEffect(() => {
    async function showFor(row: OtpRow) {
      if (!row.code || row.verified_at || handledRef.current.has(row.visit_id)) return
      const { data, error } = await supabase.from("service_visits").select("ticket_id").eq("id", row.visit_id).single()
      if (error || !data) return
      setPending({ ticketId: data.ticket_id, visitId: row.visit_id })
    }

    const channel = supabase
      .channel("customer-otp-alerts")
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "service_visit_otps" }, (payload) => void showFor(payload.new as OtpRow))
      .on("postgres_changes", { event: "UPDATE", schema: "public", table: "service_visit_otps" }, (payload) => {
        const row = payload.new as OtpRow
        if (row.verified_at) {
          handledRef.current.add(row.visit_id)
          setPending((p) => (p?.visitId === row.visit_id ? null : p))
        } else {
          void showFor(row)
        }
      })
      .subscribe()

    return () => {
      supabase.removeChannel(channel)
    }
  }, [])

  if (!pending) return null

  function dismiss() {
    if (pending) handledRef.current.add(pending.visitId)
    setPending(null)
  }

  return (
    <div className="mx-4 mb-3 flex items-center gap-2.5 rounded-xl border border-accent/30 bg-accent-soft px-3.5 py-2.5">
      <KeyRound className="size-4 shrink-0 text-accent" />
      <button
        type="button"
        onClick={() => {
          if (pending) {
            handledRef.current.add(pending.visitId)
            navigate(`/customer/bookings/${pending.ticketId}`)
            setPending(null)
          }
        }}
        className="flex-1 text-left text-xs font-medium text-text"
      >
        {t("customerApp.otpAlert.message")}
      </button>
      <button type="button" onClick={dismiss} className="shrink-0 text-text-muted">
        <X className="size-4" />
      </button>
    </div>
  )
}
