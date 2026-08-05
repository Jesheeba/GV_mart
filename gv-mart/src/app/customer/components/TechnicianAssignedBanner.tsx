import { useEffect } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { useQueryClient } from "@tanstack/react-query"
import { Wrench } from "lucide-react"
import { supabase } from "@/lib/supabase"
import { useMyCustomerId, useActiveAssignedTickets } from "@/hooks/useCustomerApp"

/**
 * App-wide, shell-mounted banner (see OtpAlertBanner.tsx for the same
 * pattern) that surfaces the moment a technician is assigned to a booking
 * and stays up — across navigation and page reload — until that booking's
 * status leaves 'assigned'/'in_progress' (i.e. completed or cancelled).
 * Ground truth is the polled activeAssignedTickets query, not local/session
 * state, so a reload doesn't lose the banner; the realtime subscription on
 * service_tickets just makes the transition (in either direction) show up
 * without waiting for the next poll.
 */
export function TechnicianAssignedBanner() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const { customerId } = useMyCustomerId()
  const { data: activeTickets } = useActiveAssignedTickets(customerId)

  useEffect(() => {
    const channel = supabase
      .channel("customer-technician-assigned-alerts")
      .on("postgres_changes", { event: "UPDATE", schema: "public", table: "service_tickets" }, () => {
        void queryClient.invalidateQueries({ queryKey: ["customerApp", "activeAssignedTickets"] })
      })
      .subscribe()

    return () => {
      supabase.removeChannel(channel)
    }
  }, [queryClient])

  const ticket = activeTickets?.[0]
  if (!ticket) return null

  return (
    <div
      role="status"
      aria-live="polite"
      className="mx-4 mb-3 flex items-center gap-2.5 rounded-xl border border-accent/30 bg-accent-soft pl-3.5 pr-2 py-1 lg:mx-25"
    >
      <Wrench className="size-4 shrink-0 text-accent" />
      <button
        type="button"
        onClick={() => navigate(`/customer/bookings/${ticket.id}`)}
        className="flex-1 truncate py-2.5 text-left text-xs font-medium text-text"
      >
        {t("customerApp.technicianAssignedAlert.message")}
      </button>
    </div>
  )
}
