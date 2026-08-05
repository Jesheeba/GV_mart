import { useEffect, useRef, useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { KeyRound, X } from "lucide-react"
import { supabase } from "@/lib/supabase"
import { Button } from "@/components/ui/button"

type OtpRow = { visit_id: string; code: string | null; verified_at: string | null; generated_at: string }

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
  const [pending, setPending] = useState<{ ticketId: string; visitId: string; generatedAt: string } | null>(null)
  // Codes already shown-and-dismissed (or navigated to, or verified) this
  // session, so the banner doesn't keep reappearing for the same code —
  // keyed by visit_id+generated_at (not just visit_id) so a genuinely new
  // code (Resend, a fresh UPDATE with a new generated_at on the same row)
  // still re-triggers the banner even if the previous code for that visit
  // was already dismissed.
  const handledRef = useRef<Set<string>>(new Set())
  const codeKey = (row: OtpRow) => `${row.visit_id}:${row.generated_at}`

  useEffect(() => {
    async function showFor(row: OtpRow) {
      if (!row.code || row.verified_at || handledRef.current.has(codeKey(row))) return
      const { data, error } = await supabase.from("service_visits").select("ticket_id").eq("id", row.visit_id).single()
      if (error || !data) return
      setPending({ ticketId: data.ticket_id, visitId: row.visit_id, generatedAt: row.generated_at })
    }

    const channel = supabase
      .channel("customer-otp-alerts")
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "service_visit_otps" }, (payload) => void showFor(payload.new as OtpRow))
      .on("postgres_changes", { event: "UPDATE", schema: "public", table: "service_visit_otps" }, (payload) => {
        const row = payload.new as OtpRow
        if (row.verified_at) {
          handledRef.current.add(codeKey(row))
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
    if (pending) handledRef.current.add(`${pending.visitId}:${pending.generatedAt}`)
    setPending(null)
  }

  return (
    <div
      role="status"
      aria-live="polite"
      className="mx-4 mb-3 flex items-center gap-2.5 rounded-xl border border-accent/30 bg-accent-soft pl-3.5 pr-2 py-1 lg:mx-25"
    >
      <KeyRound className="size-4 shrink-0 text-accent" />
      <button
        type="button"
        onClick={() => {
          if (pending) {
            handledRef.current.add(`${pending.visitId}:${pending.generatedAt}`)
            navigate(`/customer/bookings/${pending.ticketId}`)
            setPending(null)
          }
        }}
        className="flex-1 py-2.5 text-left text-xs font-medium text-text"
      >
        {t("customerApp.otpAlert.message")}
      </button>
      <Button
        type="button"
        variant="ghost"
        size="icon-xs"
        onClick={dismiss}
        aria-label={t("customerApp.otpAlert.dismiss")}
        className="shrink-0 text-text-muted"
      >
        <X />
      </Button>
    </div>
  )
}
