import { useEffect, useState } from "react"
import { useTranslation } from "react-i18next"
import { supabase } from "@/lib/supabase"
import { getIstNow } from "@/lib/ist"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import { useCheckOut, useRespondToShiftEndPrompt } from "@/hooks/useTechnician"
import { getTodayAttendanceFresh, type AttendanceRowWithCheckOut } from "@/services/technician"

type NotificationRow = { type: string; user_id: string | null }

/**
 * Shift-end job-assignment prompt (20260831140000) — once a technician
 * finishes a job at/after the org's settings.work_end, create_service_invoice
 * holds back the next auto-assign and flags today's attendance row instead
 * of silently pulling them into more work. This surfaces that decision.
 *
 * Two delivery paths, same reasoning as NewJobAssignedBanner (which this is
 * modeled on): create_service_invoice runs through the offline queue
 * (queueCreateServiceInvoice -> enqueue), so OnSiteVisitPage's own
 * handleCreateInvoice never sees the RPC's response, online or offline —
 * there's no reliable synchronous signal to trigger off. So:
 *   1. Realtime: the same `notifications` INSERT subscription shape,
 *      reacting to type 'shift_end_prompt' instead of 'appointment_assigned'.
 *   2. On-load fallback: a direct query of today's attendance row, for the
 *      case where the notification landed while the app was closed.
 *
 * Blocking by design (showClose={false}, onOpenChange no-op) — a real
 * decision is owed, not something to dismiss and forget; the midnight
 * reset (reset_stale_shift_end_prompts) is the only thing that ever clears
 * it besides the technician's own Continue/Check-out answer.
 */
export function ShiftEndPromptModal({
  orgId,
  technicianId,
  userId,
}: {
  orgId: string | undefined
  technicianId: string | undefined
  userId: string | undefined
}) {
  const { t } = useTranslation()
  const [visible, setVisible] = useState(false)
  const [attendance, setAttendance] = useState<AttendanceRowWithCheckOut | null>(null)
  const [noJobWaiting, setNoJobWaiting] = useState(false)
  const checkOut = useCheckOut()
  const respond = useRespondToShiftEndPrompt()

  useEffect(() => {
    if (!orgId || !technicianId) return
    let cancelled = false
    getTodayAttendanceFresh(orgId, technicianId, getIstNow().date)
      .then((row) => {
        if (!cancelled && row?.shift_end_prompt_pending) {
          setAttendance(row)
          setVisible(true)
        }
      })
      .catch(() => {
        // Fails open, same as NewJobAssignedBanner's realtime path failing
        // silently on a bad subscription — the realtime path below is the
        // primary trigger for a technician actively using the app; this is
        // only the "app was closed when it landed" backstop.
      })
    return () => {
      cancelled = true
    }
  }, [orgId, technicianId])

  useEffect(() => {
    if (!userId || !orgId || !technicianId) return
    const channel = supabase
      .channel(`technician-shift-end-prompt-${userId}`)
      .on(
        "postgres_changes",
        { event: "INSERT", schema: "public", table: "notifications", filter: `user_id=eq.${userId}` },
        (payload) => {
          const row = payload.new as NotificationRow
          if (row.type !== "shift_end_prompt") return
          getTodayAttendanceFresh(orgId, technicianId, getIstNow().date)
            .then((freshRow) => {
              if (freshRow) setAttendance(freshRow)
            })
            .catch(() => {
              /* the modal still opens below even if this re-fetch fails — Check-out doesn't need it, Continue's own error handling covers the rest */
            })
          setNoJobWaiting(false)
          setVisible(true)
        }
      )
      .subscribe()

    return () => {
      supabase.removeChannel(channel)
    }
  }, [userId, orgId, technicianId])

  function handleCheckOut() {
    if (!technicianId || !attendance) return
    checkOut.mutate(
      { technicianId, date: attendance.date },
      {
        onSettled: () => {
          // Best-effort: the checkout itself already succeeded via the
          // proven offline-queued path above regardless of this call's
          // outcome. If this fails (e.g. offline), the flag stays pending
          // until either a retry or the midnight safety net clears it —
          // not a data-loss risk, just delayed admin-notification cleanup.
          respond.mutate("check_out")
          setVisible(false)
        },
      }
    )
  }

  function handleContinue() {
    respond.mutate("continue", {
      onSuccess: (result) => {
        if (result.ok && result.decision === "continue" && !result.assigned.assigned) {
          setNoJobWaiting(true)
          return
        }
        setVisible(false)
      },
      onError: () => {
        // Left open — genuinely needs connectivity (real assignment logic,
        // real admin notification), unlike Check-out which degrades
        // gracefully. The technician can just tap Continue again.
      },
    })
  }

  if (!visible) return null

  return (
    <Dialog open onOpenChange={() => {}}>
      <DialogContent showClose={false} className="max-w-sm">
        <DialogTitle>{t("technician.shiftEndPrompt.title")}</DialogTitle>
        <DialogDescription>{t("technician.shiftEndPrompt.body")}</DialogDescription>
        {noJobWaiting ? <p className="text-sm text-text-muted">{t("technician.shiftEndPrompt.noJobWaiting")}</p> : null}
        <div className="mt-2 flex gap-2">
          <Button type="button" variant="outline" className="flex-1" disabled={checkOut.isPending || respond.isPending} onClick={handleCheckOut}>
            {t("technician.shiftEndPrompt.checkOut")}
          </Button>
          <Button type="button" className="flex-1" disabled={respond.isPending} onClick={handleContinue}>
            {t("technician.shiftEndPrompt.continue")}
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  )
}
