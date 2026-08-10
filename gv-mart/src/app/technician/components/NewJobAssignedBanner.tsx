import { useEffect, useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { useQueryClient } from "@tanstack/react-query"
import { Wrench, X } from "lucide-react"
import { supabase } from "@/lib/supabase"
import { Button } from "@/components/ui/button"

type NotificationRow = { type: string; user_id: string | null }

/**
 * "From the morning itself the technician is assigned to a particular
 * service but nothing is flagged on the technician side" — the auto-assign
 * engine (ticket creation, and the check-in/completion backlog scan) always
 * writes an `appointment_assigned` notification row for the technician, but
 * previously nothing surfaced it besides a 30s-polled bell badge that's
 * easy to miss if the app isn't already open on that screen. App-wide,
 * shell-mounted banner (same pattern as the customer app's OtpAlertBanner)
 * that pops the moment that row lands and also invalidates the jobs list so
 * it shows up on Home without waiting for its own 60s poll.
 */
export function NewJobAssignedBanner({ userId }: { userId: string | undefined }) {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const [visible, setVisible] = useState(false)

  useEffect(() => {
    if (!userId) return
    const channel = supabase
      .channel(`technician-job-assigned-alerts-${userId}`)
      .on(
        "postgres_changes",
        { event: "INSERT", schema: "public", table: "notifications", filter: `user_id=eq.${userId}` },
        (payload) => {
          const row = payload.new as NotificationRow
          if (row.type !== "appointment_assigned") return
          setVisible(true)
          void queryClient.invalidateQueries({ queryKey: ["jobs"] })
        }
      )
      .subscribe()

    return () => {
      supabase.removeChannel(channel)
    }
  }, [userId, queryClient])

  if (!visible) return null

  return (
    <div
      role="status"
      aria-live="polite"
      className="mx-4 mb-3 flex items-center gap-2.5 rounded-xl border border-accent/30 bg-accent-soft pl-3.5 pr-2 py-1"
    >
      <Wrench className="size-4 shrink-0 text-accent" />
      <button
        type="button"
        onClick={() => {
          setVisible(false)
          navigate("/technician")
        }}
        className="flex-1 truncate py-2.5 text-left text-xs font-medium text-text"
      >
        {t("technician.newJobAssignedAlert.message")}
      </button>
      <Button
        type="button"
        variant="ghost"
        size="icon-xs"
        onClick={() => setVisible(false)}
        aria-label={t("technician.newJobAssignedAlert.dismiss")}
        className="shrink-0 text-text-muted"
      >
        <X />
      </Button>
    </div>
  )
}
