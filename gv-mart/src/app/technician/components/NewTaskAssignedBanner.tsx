import { useEffect, useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { useQueryClient } from "@tanstack/react-query"
import { ClipboardCheck, X } from "lucide-react"
import { supabase } from "@/lib/supabase"
import { Button } from "@/components/ui/button"

type NotificationRow = { type: string; user_id: string | null }

/**
 * Same live-banner pattern as NewJobAssignedBanner (a `notifications` INSERT
 * on this user's row, filtered by `type`) — Phase 0's tasks_notify_assigned
 * trigger writes a `task_assigned` row the moment someone assigns/reassigns
 * a task to this technician, so this just needs to listen for it and pop.
 */
export function NewTaskAssignedBanner({ userId }: { userId: string | undefined }) {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const [visible, setVisible] = useState(false)

  useEffect(() => {
    if (!userId) return
    const channel = supabase
      .channel(`technician-task-assigned-alerts-${userId}`)
      .on(
        "postgres_changes",
        { event: "INSERT", schema: "public", table: "notifications", filter: `user_id=eq.${userId}` },
        (payload) => {
          const row = payload.new as NotificationRow
          if (row.type !== "task_assigned") return
          setVisible(true)
          void queryClient.invalidateQueries({ queryKey: ["tasks"] })
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
      <ClipboardCheck className="size-4 shrink-0 text-accent" />
      <button
        type="button"
        onClick={() => {
          setVisible(false)
          navigate("/technician/tasks")
        }}
        className="flex-1 truncate py-2.5 text-left text-xs font-medium text-text"
      >
        {t("technician.newTaskAssignedAlert.message")}
      </button>
      <Button
        type="button"
        variant="ghost"
        size="icon-xs"
        onClick={() => setVisible(false)}
        aria-label={t("technician.newTaskAssignedAlert.dismiss")}
        className="shrink-0 text-text-muted"
      >
        <X />
      </Button>
    </div>
  )
}
