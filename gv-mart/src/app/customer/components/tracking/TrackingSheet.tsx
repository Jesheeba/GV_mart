import { useLayoutEffect, useRef, useState, type PointerEvent as ReactPointerEvent } from "react"
import { useTranslation } from "react-i18next"
import { CalendarCheck, Loader2, MapPin, Navigation, Phone, Share2, ShieldCheck, Sparkles, Star, Wrench } from "lucide-react"
import { Button } from "@/components/ui/button"
import { type StatusTone } from "@/components/shared/StatusDot"
import type { ConnectionState } from "@/hooks/useLiveTracking"
import type { TrackingStage } from "@/lib/tracking/stages"
import { cn } from "@/lib/utils"
import { StatusTimeline } from "./StatusTimeline"

type SnapIndex = 0 | 1 | 2
const COLLAPSED_PX = 132

/** Upper bound only — actual settled height is measured from real content
 * (see the useLayoutEffect below), not guessed as a fixed vh fraction. A
 * fixed guess is what caused the sheet to clip/scroll real content that
 * didn't match the guess (e.g. the "Reconnecting…" banner pushing half-state
 * content past a hardcoded 0.38*vh). The cap here only protects the
 * expanded state from exceeding the viewport on a very long address/timeline. */
function snapCaps() {
  const vh = typeof window !== "undefined" ? window.innerHeight : 800
  return [COLLAPSED_PX, Math.round(vh * 0.55), Math.round(vh * 0.82)] as const
}

const STAGE_TONE: Record<TrackingStage, StatusTone> = {
  booking_confirmed: "neutral",
  technician_assigned: "info",
  heading_to_you: "info",
  nearby: "warning",
  arrived_working: "success",
  completed: "success",
  cancelled: "danger",
}
const STAGE_ICON: Record<TrackingStage, typeof Navigation> = {
  booking_confirmed: CalendarCheck,
  technician_assigned: ShieldCheck,
  heading_to_you: Navigation,
  nearby: Sparkles,
  arrived_working: Wrench,
  completed: ShieldCheck,
  cancelled: ShieldCheck,
}
const STAGE_TONE_CLASS: Record<StatusTone, string> = {
  success: "bg-success/15 text-success",
  warning: "bg-warning/15 text-warning",
  danger: "bg-danger/15 text-danger",
  info: "bg-info/15 text-info",
  neutral: "bg-surface-alt text-text-muted",
}

function initialsOf(name: string) {
  return name.trim().split(/\s+/).map((p) => p[0]).filter(Boolean).slice(0, 2).join("").toUpperCase()
}

export function TrackingSheet({
  technicianName,
  technicianPhone,
  technicianSkills,
  avgRating,
  completedCount,
  stage,
  statusLabel,
  etaMinutes,
  etaWindowLabel,
  distanceKm,
  connectionState,
  addressLabel,
  onCall,
  onShare,
}: {
  technicianName: string
  technicianPhone: string | null
  technicianSkills: string[]
  avgRating: number | null
  completedCount: number | null
  stage: TrackingStage
  statusLabel: string
  etaMinutes: number | null
  etaWindowLabel: string | null
  distanceKm: number | null
  connectionState: ConnectionState
  addressLabel: string
  onCall: () => void
  onShare: () => void
}) {
  const { t } = useTranslation()
  const [snapIndex, setSnapIndex] = useState<SnapIndex>(1)
  const [dragHeight, setDragHeight] = useState<number | null>(null)
  const [measuredHeights, setMeasuredHeights] = useState<number[]>(() => [...snapCaps()])
  const dragRef = useRef<{ startY: number; startHeight: number } | null>(null)
  const sheetRef = useRef<HTMLDivElement>(null)

  const caps = snapCaps()
  const committedHeight = measuredHeights[snapIndex]
  const height = dragHeight ?? committedHeight
  const StageIcon = STAGE_ICON[stage]

  // Fits the sheet to its ACTUAL content instead of a guessed height —
  // scrollHeight reports the full natural content height even while this
  // same element is currently clipped to a stale (too-short) explicit
  // height, so this self-corrects in one pre-paint pass whenever content
  // changes length (a banner appearing, a longer technician name, etc.),
  // capped so the expanded state can never exceed the viewport.
  // Deliberately no dependency array — needs to re-measure on every render
  // since arbitrary content (status text, banners) can change length without
  // snapIndex changing; the value-equality check below prevents update loops.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useLayoutEffect(() => {
    if (dragHeight != null || !sheetRef.current) return
    const natural = Math.min(sheetRef.current.scrollHeight, caps[snapIndex])
    setMeasuredHeights((prev) => {
      if (prev[snapIndex] === natural) return prev
      const next = [...prev]
      next[snapIndex] = natural
      return next
    })
  })

  function handlePointerDown(e: ReactPointerEvent<HTMLDivElement>) {
    ;(e.target as HTMLElement).setPointerCapture(e.pointerId)
    dragRef.current = { startY: e.clientY, startHeight: committedHeight }
  }
  function handlePointerMove(e: ReactPointerEvent<HTMLDivElement>) {
    if (!dragRef.current) return
    const delta = dragRef.current.startY - e.clientY
    setDragHeight(Math.min(caps[2], Math.max(caps[0], dragRef.current.startHeight + delta)))
  }
  function handlePointerUp() {
    if (dragRef.current == null || dragHeight == null) {
      dragRef.current = null
      return
    }
    // Snap to whichever state's cap the drag ended up closest to — the
    // actual committed height for that state is then re-measured (above)
    // from its real content on the next paint, not this cap.
    const distances = caps.map((h) => Math.abs(h - dragHeight))
    const nearest = distances.indexOf(Math.min(...distances)) as SnapIndex
    setSnapIndex(nearest)
    setDragHeight(null)
    dragRef.current = null
  }

  // Deliberately in-flow (not a fixed viewport overlay) — CustomerShell has
  // its own `fixed` bottom tab bar (BottomTabBar.tsx); a fixed sheet pinned
  // to the true viewport bottom would sit underneath/collide with it. This
  // still delivers the drag/snap/height-animation interaction, it just
  // pushes the page's own content below it in normal flow instead of
  // floating above everything, which also sidesteps needing to coordinate
  // z-index with the tab bar's z-40.
  return (
    <div
      ref={sheetRef}
      style={{ height }}
      className={cn(
        "relative flex flex-col overflow-y-auto rounded-3xl border border-border bg-surface shadow-[0_10px_30px_-12px_rgba(26,26,26,.18)]",
        dragHeight == null && "transition-[height] duration-300 ease-out"
      )}
    >
      <div
        onPointerDown={handlePointerDown}
        onPointerMove={handlePointerMove}
        onPointerUp={handlePointerUp}
        onPointerCancel={handlePointerUp}
        className="flex shrink-0 touch-none flex-col items-center gap-2.5 px-4 pt-2 pb-2.5"
      >
        <span className="h-1.25 w-10 shrink-0 rounded-full bg-border" aria-hidden="true" />
        <div className="flex w-full items-center gap-3">
          <span className="flex size-11 shrink-0 items-center justify-center rounded-full bg-ink text-sm font-bold text-white">
            {initialsOf(technicianName)}
          </span>
          <div className="min-w-0 flex-1">
            <p className="truncate text-sm font-bold text-text">{technicianName}</p>
            <p className="truncate text-xs text-text-muted">
              {etaMinutes != null ? t("customerApp.tracking.etaMinutes", { count: Math.max(1, Math.round(etaMinutes)) }) : statusLabel}
            </p>
          </div>
          <span className={cn("flex shrink-0 items-center gap-1.5 rounded-full px-2.75 py-1.25 text-xs font-bold", STAGE_TONE_CLASS[STAGE_TONE[stage]])}>
            <StageIcon className="size-3.5" />
            {statusLabel}
          </span>
        </div>
        {connectionState === "reconnecting" ? (
          <div className="flex w-full items-center gap-1.5 rounded-lg bg-warning/10 px-2.5 py-1.5 text-xs font-medium text-warning">
            <Loader2 className="size-3 animate-spin" />
            {t("customerApp.tracking.reconnecting")}
          </div>
        ) : null}
      </div>

      <div className="px-4 pb-4">
        {snapIndex >= 1 ? (
          <div className="flex flex-col gap-3 border-t border-border pt-3.5">
            {etaWindowLabel ? (
              <div className="rounded-2xl bg-accent-soft px-3.5 py-3">
                <p className="text-[11px] font-semibold text-accent uppercase">{t("customerApp.tracking.expectedBetween")}</p>
                <p className="text-lg font-extrabold text-text">{etaWindowLabel}</p>
              </div>
            ) : null}

            <div className="flex items-center gap-2.5">
              <Button type="button" variant="outline" className="w-full flex-1" onClick={onCall} disabled={!technicianPhone}>
                <Phone className="size-4" />
                {t("customerApp.tracking.call")}
              </Button>
              <Button type="button" variant="outline" size="icon" onClick={onShare} aria-label={t("customerApp.tracking.shareTracking")}>
                <Share2 className="size-4" />
              </Button>
            </div>

            <div className="flex flex-wrap items-center gap-x-4 gap-y-1.5 text-xs text-text-muted">
              {distanceKm != null ? (
                <span className="flex items-center gap-1">
                  <MapPin className="size-3.5" />
                  {t("customerApp.tracking.distanceAway", { distance: distanceKm.toFixed(1) })}
                </span>
              ) : null}
              {avgRating != null ? (
                <span className="flex items-center gap-1">
                  <Star className="size-3.5 fill-warning text-warning" />
                  {avgRating.toFixed(1)}
                </span>
              ) : null}
              {completedCount != null ? <span>{t("customerApp.tracking.servicesCompleted", { count: completedCount })}</span> : null}
            </div>

            {technicianSkills.length > 0 ? (
              <div className="flex flex-wrap gap-1.5">
                {technicianSkills.map((s) => (
                  <span key={s} className="rounded-full border border-border bg-surface-alt px-2.5 py-1 text-[11px] font-semibold text-text">
                    {t(`technicians.list.skillOptions.${s}`, s)}
                  </span>
                ))}
              </div>
            ) : null}
          </div>
        ) : null}

        {snapIndex >= 2 ? (
          <div className="flex flex-col gap-4 border-t border-border pt-4 pb-2">
            <div>
              <p className="mb-1 text-xs font-semibold text-text-muted uppercase">{t("customerApp.tracking.serviceAddress")}</p>
              <p className="text-sm text-text">{addressLabel}</p>
            </div>
            <div>
              <p className="mb-2 text-xs font-semibold text-text-muted uppercase">{t("customerApp.tracking.timelineTitle")}</p>
              <StatusTimeline stage={stage} />
            </div>
          </div>
        ) : null}
      </div>
    </div>
  )
}
