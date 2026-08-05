import { useTranslation } from "react-i18next"
import { TIMELINE_STAGES, timelineIndexForStage, type TrackingStage } from "@/lib/tracking/stages"
import { cn } from "@/lib/utils"

// Keyed on the full TrackingStage union (not just TIMELINE_STAGES) so the
// Record type-checks without a partial — "nearby"/"cancelled" entries are
// never actually looked up here (StatusTimeline only ever renders
// TIMELINE_STAGES items; "nearby" collapses into "heading_to_you" via
// timelineIndexForStage, and "cancelled" is handled by its own banner
// elsewhere, not this timeline).
const STEP_LABEL_KEY: Record<TrackingStage, string> = {
  booking_confirmed: "customerApp.tracking.timeline.bookingConfirmed",
  technician_assigned: "customerApp.tracking.timeline.technicianAssigned",
  heading_to_you: "customerApp.tracking.timeline.headingToYou",
  nearby: "customerApp.tracking.timeline.headingToYou",
  arrived_working: "customerApp.tracking.timeline.arrivedWorking",
  completed: "customerApp.tracking.timeline.completed",
  cancelled: "customerApp.tracking.stage.cancelled",
}

/** Vertical dot+line timeline — same visual language as CustomerDetailPage's
 * service-history timeline, driven by the derived tracking stage instead of
 * a literal DB status column (see lib/tracking/stages.ts). */
export function StatusTimeline({ stage }: { stage: TrackingStage }) {
  const { t } = useTranslation()
  const currentIndex = timelineIndexForStage(stage)

  return (
    <div className="flex flex-col">
      {TIMELINE_STAGES.map((step, i, arr) => {
        const isDone = i < currentIndex
        const isCurrent = i === currentIndex
        return (
          <div key={step} className="flex gap-3.25">
            <div className="flex flex-col items-center">
              <span
                className={cn(
                  "size-2.75 shrink-0 rounded-full",
                  isDone && "border-2.5 border-success/20 bg-success",
                  isCurrent && "animate-in zoom-in-50 border-2.5 border-accent/25 bg-accent duration-300",
                  !isDone && !isCurrent && "bg-border"
                )}
              />
              {i < arr.length - 1 ? <span className={cn("w-0.5 flex-1", isDone ? "bg-success/40" : "bg-border")} /> : null}
            </div>
            <div className={cn("min-w-0", i < arr.length - 1 && "pb-4.5")}>
              <p className={cn("text-sm font-semibold", isDone || isCurrent ? "text-text" : "text-text-muted")}>{t(STEP_LABEL_KEY[step])}</p>
            </div>
          </div>
        )
      })}
    </div>
  )
}
