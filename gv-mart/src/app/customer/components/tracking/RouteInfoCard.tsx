import { useTranslation } from "react-i18next"
import { Car } from "lucide-react"
import type { TrackingStage } from "@/lib/tracking/stages"

const TITLE_KEY: Partial<Record<TrackingStage, string>> = {
  technician_assigned: "customerApp.tracking.routeCard.titleAssigned",
  heading_to_you: "customerApp.tracking.routeCard.titleOnTheWay",
  nearby: "customerApp.tracking.routeCard.titleNearby",
  arrived_working: "customerApp.tracking.routeCard.titleArrived",
}

/** Arrival micro-thresholds (spec: distinct treatment at ~200m and ~100m,
 * on top of the 500m "nearby" stage already in lib/tracking/stages.ts) —
 * deliberately just a display-layer refinement, not additional
 * TrackingStage values: the status chip/timeline/notifications don't need
 * three more states, but the copy and precision customers actually read
 * should sharpen as the technician gets close, same as Uber/Rapido swapping
 * "X km" for a tighter "X m" readout right before arrival. */
const ARRIVING_NOW_KM = 0.1

function formatDistance(t: (key: string, opts?: Record<string, unknown>) => string, distanceKm: number, isApproximate: boolean) {
  const value =
    distanceKm < 1
      ? t("customerApp.tracking.routeCard.distanceValueMeters", { meters: Math.max(10, Math.round(distanceKm * 1000)) })
      : t("customerApp.tracking.routeCard.distanceValue", { distance: distanceKm.toFixed(1) })
  return isApproximate ? `~${value}` : value
}

/**
 * Compact route-confirmation summary (Uber/Find My style redesign, replaces
 * a plain map embed as the customer's first read) — sits directly above
 * TrackingMap. Three-stat row (ETA/Distance/Status) is the whole point: the
 * customer should get the answer without reading anything else on the page.
 */
export function RouteInfoCard({
  stage,
  etaMinutes,
  distanceKm,
  isApproximateDistance,
  statusLabel,
  routeError,
}: {
  stage: TrackingStage
  etaMinutes: number | null
  distanceKm: number | null
  /** True when `distanceKm` is the haversine straight-line fallback rather
   * than a real Directions API response — a wrong-looking-real number is
   * worse than an obviously-approximate one, so this must never render
   * identically to a routed distance. */
  isApproximateDistance?: boolean
  statusLabel: string
  /** Surfaced on-screen (not just console) so a non-technical tester can
   * just read/report this instead of needing devtools — see TrackingMap's
   * DirectionsService error handling. Null once a route is showing fine. */
  routeError?: string | null
}) {
  const { t } = useTranslation()
  const isArrivingNow = stage === "nearby" && distanceKm != null && distanceKm <= ARRIVING_NOW_KM
  const title = t(isArrivingNow ? "customerApp.tracking.routeCard.titleArrivingNow" : (TITLE_KEY[stage] ?? "customerApp.tracking.routeCard.titleOnTheWay"))

  return (
    <div className="rounded-[20px] border border-border bg-surface px-5 py-4.5 shadow-[0_10px_30px_-14px_rgba(26,26,26,.16)]">
      <div className="mb-4 flex items-center gap-2.5">
        <span className="flex size-9 shrink-0 items-center justify-center rounded-full bg-accent-soft text-accent">
          <Car className="size-4.5" />
        </span>
        <p className="text-[15px] font-bold text-text">{title}</p>
      </div>
      <div className="grid grid-cols-3 gap-3 text-center">
        <div>
          <p className="text-[10px] font-semibold tracking-wide text-text-muted uppercase">{t("customerApp.tracking.routeCard.eta")}</p>
          <p className="gv-tnum mt-1 text-lg font-extrabold text-text">
            {etaMinutes != null ? t("customerApp.tracking.routeCard.etaValue", { count: Math.max(1, Math.round(etaMinutes)) }) : "—"}
          </p>
        </div>
        <div className="border-x border-border">
          <p className="text-[10px] font-semibold tracking-wide text-text-muted uppercase">{t("customerApp.tracking.routeCard.distance")}</p>
          <p className="gv-tnum mt-1 text-lg font-extrabold text-text">
            {distanceKm != null ? formatDistance(t, distanceKm, !!isApproximateDistance) : "—"}
          </p>
        </div>
        <div>
          <p className="text-[10px] font-semibold tracking-wide text-text-muted uppercase">{t("customerApp.tracking.routeCard.status")}</p>
          <p className="mt-1 text-lg font-extrabold text-accent">{statusLabel}</p>
        </div>
      </div>
      {routeError ? (
        <p className="mt-3 rounded-lg bg-warning/10 px-2.5 py-1.5 text-center text-[11px] font-medium text-warning">
          {t("customerApp.tracking.routeCard.routeUnavailable", { code: routeError })}
        </p>
      ) : null}
    </div>
  )
}
