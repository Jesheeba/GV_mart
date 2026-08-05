import { useEffect, useState } from "react"
import { supabase } from "@/lib/supabase"
import type { Enums } from "@/types/database"

export type ConnectionState = "live" | "reconnecting"

/**
 * Realtime `invoices.payment_status` for the customer's payment screen —
 * same subscribe/cleanup shape as CompletionOtpCard.tsx, so the QR screen
 * flips to "paid" the moment the technician confirms, without a refresh.
 */
export function usePaymentStatus(invoiceId: string | undefined, initialStatus: Enums<"payment_status"> | undefined) {
  const [paymentStatus, setPaymentStatus] = useState<Enums<"payment_status"> | undefined>(initialStatus)
  const [connectionState, setConnectionState] = useState<ConnectionState>("live")

  useEffect(() => {
    setPaymentStatus(initialStatus)
  }, [initialStatus])

  useEffect(() => {
    if (!invoiceId) return
    const channel = supabase
      .channel(`invoice-payment-${invoiceId}`)
      .on(
        "postgres_changes",
        { event: "UPDATE", schema: "public", table: "invoices", filter: `id=eq.${invoiceId}` },
        (payload) => setPaymentStatus((payload.new as { payment_status: Enums<"payment_status"> }).payment_status)
      )
      .subscribe((status) => {
        if (status === "SUBSCRIBED") setConnectionState("live")
        else if (status === "CHANNEL_ERROR" || status === "TIMED_OUT" || status === "CLOSED") setConnectionState("reconnecting")
      })
    return () => {
      supabase.removeChannel(channel)
    }
  }, [invoiceId])

  return { paymentStatus, connectionState }
}
