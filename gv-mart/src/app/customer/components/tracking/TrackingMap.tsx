import { useEffect, useRef, useState } from "react"
import { useTranslation } from "react-i18next"
import { Locate } from "lucide-react"
import { useMapApiKey } from "@/hooks/useMaps"
import { Map, MapMarker, MapMarkerLabel, MapPolyline, MapPulseMarker, useMap, type MapViewport } from "@/components/ui/map"
import { Button } from "@/components/ui/button"
import { Skeleton } from "@/components/ui/skeleton"
import { haversineDistanceKm, shortestAngleDelta, type LatLng } from "@/lib/tracking/geo"
import type { TrackingStage } from "@/lib/tracking/stages"
import { cn } from "@/lib/utils"

const LABEL_CLASS = "whitespace-nowrap rounded-md border border-border bg-surface px-1.5 py-0.5 text-[10px] font-medium text-text shadow-sm"
const ROTATION_UPDATE_THRESHOLD_DEG = 10
const ROUTE_COLOR = "#F5612C" // --accent, index.css
const FIT_BOUNDS_PADDING_PX = 64
/** "Recalculate the route whenever the technician position changes
 * significantly" — significant = moved past this rounding (~100m) AND at
 * least this long since the last DirectionsService call, so a stationary/
 * jittery GPS signal doesn't keep re-requesting a route that hasn't changed. */
const ROUTE_RECALC_MIN_INTERVAL_MS = 20_000
/** "Recalculate whenever the technician deviates from route" — a fix this
 * far from every point on the currently-drawn route bypasses the interval
 * throttle above and re-requests immediately, same as Rapido/Uber snapping
 * back onto a corrected path the moment you miss a turn. */
const OFF_ROUTE_THRESHOLD_KM = 0.12

export type RouteInfo = {
  distanceKm: number | null
  durationMinutes: number | null
  /** Surfaces WHY there's no route line, on-screen — not just in the
   * console — since asking a customer-facing tester to open devtools isn't
   * always practical. Null when a route is currently showing fine. */
  routeError: string | null
}

/** Approximate distance from a point to a route: nearest of the route's own
 * (densely-spaced, full-fidelity) path points — cheap and good enough at
 * this point spacing, vs. true point-to-segment geometry. */
function minDistanceToPathKm(point: LatLng, path: LatLng[]): number {
  let min = Infinity
  for (const p of path) {
    const d = haversineDistanceKm(point, p)
    if (d < min) min = d
  }
  return min
}

/**
 * Fetches the REAL route via google.maps.DirectionsService — client-side,
 * using the same already-loaded Maps JS API key the map itself uses
 * (confirmed same GOOGLE_MAPS_API_KEY as the geocode Edge Function's server-
 * side Directions calls, via map-config's Edge Function — so this works with
 * zero extra deploy/config). Deliberately NOT google.maps.DirectionsRenderer
 * (its default line styling can't be fully suppressed to match the brand-
 * colored 6px rounded route the design calls for) — the route's full-
 * fidelity geometry (every step's `path`, not just the simplified
 * `overview_path`) is extracted and handed to a plain MapPolyline instead,
 * so "every bend, intersection, U-turn and curve" from Google's own
 * turn-by-turn geometry is preserved, matching what Directions/navigation
 * actually renders.
 *
 * Tries DRIVING first, then falls back to WALKING if DRIVING comes back
 * empty — DRIVING legitimately returns ZERO_RESULTS once origin/destination
 * are only a few dozen meters apart (no multi-step road route to compute),
 * which is exactly the "technician is right outside" moment a customer cares
 * about most. WALKING still returns a real Google-computed path over actual
 * roads/footpaths at that range, so the line never has to fall back to a
 * straight-line approximation.
 */
const FALLBACK_TRAVEL_MODES = ["DRIVING", "WALKING"] as const
function DirectionsRoute({
  origin,
  destination,
  currentPath,
  onResult,
}: {
  origin: LatLng | null
  destination: LatLng | null
  /** The route currently drawn on the map, if any — used only to detect deviation, see OFF_ROUTE_THRESHOLD_KM. */
  currentPath: LatLng[] | null
  onResult: (path: LatLng[] | null, info: RouteInfo) => void
}) {
  const { map } = useMap()
  const lastFetchRef = useRef<{ key: string; at: number } | null>(null)
  const onResultRef = useRef(onResult)
  onResultRef.current = onResult
  const currentPathRef = useRef(currentPath)
  currentPathRef.current = currentPath
  const originKey = origin ? `${origin.lat.toFixed(3)},${origin.lng.toFixed(3)}` : null
  const destKey = destination ? `${destination.lat.toFixed(3)},${destination.lng.toFixed(3)}` : null

  useEffect(() => {
    if (!map || !origin || !destination || !originKey) return
    const fetchKey = `${originKey}>${destKey}`
    const now = Date.now()
    const last = lastFetchRef.current
    if (last && last.key === fetchKey) return

    const path = currentPathRef.current
    const offRoute = path && path.length > 1 ? minDistanceToPathKm(origin, path) > OFF_ROUTE_THRESHOLD_KM : false
    if (last && !offRoute && now - last.at < ROUTE_RECALC_MIN_INTERVAL_MS) return
    lastFetchRef.current = { key: fetchKey, at: now }

    // Requirement: log the request, response, decoded coordinate count, and
    // any rendering error — so a blank map is diagnosable from the console
    // instead of a guess. `reason` tags every log line with why this
    // particular call fired (first load / periodic 20-30s refresh / the
    // technician went off the currently-drawn route).
    const reason = !last ? "initial" : offRoute ? "off-route" : "periodic-refresh"

    let cancelled = false

    async function fetchRoute() {
      let lastErrorCode = "NO_ROUTE"
      for (const travelMode of FALLBACK_TRAVEL_MODES) {
        const request: google.maps.DirectionsRequest = {
          origin,
          destination,
          travelMode: travelMode as google.maps.TravelMode,
          ...(travelMode === "DRIVING"
            ? { drivingOptions: { departureTime: new Date(), trafficModel: google.maps.TrafficModel.BEST_GUESS } }
            : {}),
        }
        console.info("[TrackingMap] DirectionsService request:", { reason, travelMode, request })

        try {
          const result = await new google.maps.DirectionsService().route(request)
          if (cancelled) return
          console.info("[TrackingMap] DirectionsService response:", { travelMode, status: "OK", routeCount: result.routes.length, result })
          const route = result.routes[0]
          const leg = route?.legs?.[0]
          if (!route || !leg) {
            lastErrorCode = (result as unknown as { status?: string }).status ?? "NO_ROUTE"
            console.warn("[TrackingMap] DirectionsService returned no routes/legs — trying next travel mode", { travelMode, status: lastErrorCode, origin, destination, result })
            continue
          }
          // Concatenating every step's own `path` (not `route.overview_path`,
          // which is Google's intentionally-simplified display polyline) is
          // what preserves every bend/curve at full turn-by-turn fidelity.
          const fullPath = route.legs.flatMap((l) => l.steps.flatMap((s) => (s.path ?? []).map((p) => ({ lat: p.lat(), lng: p.lng() }))))
          const path = fullPath.length > 1 ? fullPath : route.overview_path.map((p) => ({ lat: p.lat(), lng: p.lng() }))
          const distanceMeters = leg.distance?.value ?? null
          const durationSeconds = leg.duration_in_traffic?.value ?? leg.duration?.value ?? null
          console.info("[TrackingMap] Decoded route path:", {
            travelMode,
            decodedCoordinateCount: path.length,
            usedFullStepFidelity: fullPath.length > 1,
            distanceKm: distanceMeters != null ? distanceMeters / 1000 : null,
            durationMinutes: durationSeconds != null ? durationSeconds / 60 : null,
          })
          if (path.length < 2) {
            console.error("[TrackingMap] Decoded path has fewer than 2 coordinates — MapPolyline will render nothing", { travelMode, path })
            lastErrorCode = "NO_ROUTE"
            continue
          }
          onResultRef.current(path, {
            distanceKm: distanceMeters != null ? distanceMeters / 1000 : null,
            durationMinutes: durationSeconds != null ? durationSeconds / 60 : null,
            routeError: null,
          })
          return
        } catch (error: unknown) {
          // Swallowing this silently is exactly what made the previous
          // failure invisible — status is usually one of ZERO_RESULTS/
          // REQUEST_DENIED/OVER_QUERY_LIMIT/INVALID_REQUEST (see
          // google.maps.DirectionsStatus). REQUEST_DENIED here specifically
          // means the API key that already works for the Maps JS script tag
          // isn't authorized for the Directions API from this origin —
          // almost always a Google Cloud Console key-restriction setting,
          // not a bug in this component. On REQUEST_DENIED/OVER_QUERY_LIMIT
          // there's no point trying another travel mode — same key, same
          // failure — so surface immediately instead of double-erroring.
          const code = error && typeof error === "object" && "code" in error ? (error as { code?: unknown }).code : undefined
          const codeStr = typeof code === "string" ? code : "REQUEST_FAILED"
          console.error("[TrackingMap] DirectionsService request failed:", codeStr, { travelMode, origin, destination, request, error })
          lastErrorCode = codeStr
          if (codeStr === "REQUEST_DENIED" || codeStr === "OVER_QUERY_LIMIT") break
        }
      }
      if (!cancelled) onResultRef.current(null, { distanceKm: null, durationMinutes: null, routeError: lastErrorCode })
    }

    fetchRoute()
    return () => {
      cancelled = true
    }
    // Deliberately keyed on originKey/destKey (rounded strings), NOT the raw
    // origin/destination objects — those are fresh object literals on every
    // parent re-render (useLiveTracking's rawPosition isn't memoized), so
    // depending on them here re-ran this effect on nearly every render,
    // cancelling the in-flight DirectionsService request via cleanup before
    // it could resolve, while the "already fetched this key" guard above
    // then blocked any replacement fetch — the route silently never landed.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [map, originKey, destKey])

  return null
}

/** Auto-fits the map to whatever points make up "the route" right now
 * (Route-Focused redesign — "Automatically zoom to fit the complete route",
 * "Users should not need to zoom manually"). Lives inside <Map> so it can
 * reach the real google.maps.Map instance via useMap() — fitBounds is an
 * imperative call the declarative `viewport` prop can't express on its own. */
function AutoFitBounds({ points, enabled, onFit }: { points: LatLng[]; enabled: boolean; onFit: () => void }) {
  const { map } = useMap()
  const key = points.map((p) => `${p.lat.toFixed(5)},${p.lng.toFixed(5)}`).join("|")

  useEffect(() => {
    if (!map || !enabled || points.length === 0) return
    if (points.length === 1) {
      map.setCenter(points[0])
      if ((map.getZoom() ?? 0) < 15) map.setZoom(15)
    } else {
      const bounds = new google.maps.LatLngBounds()
      points.forEach((p) => bounds.extend(p))
      map.fitBounds(bounds, FIT_BOUNDS_PADDING_PX)
    }
    onFit()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [map, enabled, key])

  return null
}

export function TrackingMap({
  technicianPosition,
  rawTechnicianPosition,
  bearingDeg,
  destination,
  stage,
  onRouteInfo,
  className,
}: {
  /** Smoothed/tweened — used for marker rendering. */
  technicianPosition: LatLng | null
  /** Latest raw GPS fix — used as the DirectionsService origin, so route recalculation is tied to real movement, not animation frames. */
  rawTechnicianPosition: LatLng | null
  bearingDeg: number | null
  destination: LatLng | null
  stage: TrackingStage
  /** Fires whenever a fresh Directions response lands — the map is the source of truth for ETA/distance now (spec: "from the Directions response instead of calculating them manually"). */
  onRouteInfo?: (info: RouteInfo) => void
  className?: string
}) {
  const { t } = useTranslation()
  const { data: apiKey, isError: apiKeyError } = useMapApiKey()
  const [viewport, setViewport] = useState<MapViewport | null>(null)
  const [mapLoadFailed, setMapLoadFailed] = useState(false)
  const [isFollowing, setIsFollowing] = useState(true)
  const [smoothedRotation, setSmoothedRotation] = useState(0)
  const [routePath, setRoutePath] = useState<LatLng[] | null>(null)
  const lastRotationRef = useRef(0)
  const prevStageRef = useRef<TrackingStage | null>(null)
  const justFitRef = useRef(false)
  const onRouteInfoRef = useRef(onRouteInfo)
  onRouteInfoRef.current = onRouteInfo

  // Spec: map zooms/recenters automatically the moment the technician enters
  // "nearby" — overrides a manual pan the customer made earlier, once.
  useEffect(() => {
    if (stage === "nearby" && prevStageRef.current !== "nearby") setIsFollowing(true)
    prevStageRef.current = stage
  }, [stage])

  // Seeds the initial viewport (Map requires one to mount) — AutoFitBounds
  // takes over precise framing once the map instance + real points exist.
  useEffect(() => {
    if (viewport) return
    const seed = technicianPosition ?? destination
    if (seed) setViewport({ center: [seed.lng, seed.lat], zoom: 14 })
  }, [viewport, technicianPosition, destination])

  // Only regenerate the rotated marker icon on a meaningful heading change —
  // avoids churning a fresh data-URL Icon on every minor GPS-noise wobble.
  useEffect(() => {
    if (bearingDeg == null) return
    if (Math.abs(shortestAngleDelta(lastRotationRef.current, bearingDeg)) >= ROTATION_UPDATE_THRESHOLD_DEG) {
      lastRotationRef.current = bearingDeg
      setSmoothedRotation(bearingDeg)
    }
  }, [bearingDeg])

  const handleViewportChange = (next: MapViewport) => {
    setViewport(next)
    // A fitBounds/setCenter call from AutoFitBounds also fires this (via the
    // map's own "idle" event) — only a genuine user drag/scroll should ever
    // turn auto-follow off.
    if (justFitRef.current) {
      justFitRef.current = false
      return
    }
    setIsFollowing(false)
  }
  const handleRecenter = () => setIsFollowing(true)
  const handleRouteResult = (path: LatLng[] | null, info: RouteInfo) => {
    setRoutePath(path)
    onRouteInfoRef.current?.(info)
  }

  // Never fall back to a straight line between the two markers — no route
  // yet means no route line at all, just the markers, until DirectionsService
  // actually resolves one.
  const routePoints = routePath && routePath.length > 1 ? routePath : []
  const fitPoints = routePoints.length > 0 ? routePoints : [technicianPosition, destination].filter((p): p is LatLng => !!p)

  return (
    <div className={cn("relative h-full w-full overflow-hidden", className)}>
      {!apiKey ? (
        <div className="flex h-full items-center justify-center bg-surface-alt">
          {apiKeyError ? (
            <p className="px-3 text-center text-sm text-text-muted">{t("customerApp.tracking.mapLoadFailed")}</p>
          ) : (
            <Skeleton className="h-full w-full rounded-none" />
          )}
        </div>
      ) : mapLoadFailed ? (
        <div className="flex h-full items-center justify-center bg-surface-alt">
          <p className="px-3 text-center text-sm text-text-muted">{t("customerApp.tracking.mapLoadFailed")}</p>
        </div>
      ) : viewport ? (
        <Map apiKey={apiKey} viewport={viewport} variant="standard" onViewportChange={handleViewportChange} onLoadError={() => setMapLoadFailed(true)}>
          <DirectionsRoute origin={rawTechnicianPosition} destination={destination} currentPath={routePath} onResult={handleRouteResult} />

          <AutoFitBounds
            points={fitPoints}
            enabled={isFollowing}
            onFit={() => {
              justFitRef.current = true
            }}
          />

          {destination ? (
            <>
              <MapMarker longitude={destination.lng} latitude={destination.lat} variant="house" color="#2E6BE6" title={t("customerApp.tracking.yourLocation")} />
              <MapMarkerLabel longitude={destination.lng} latitude={destination.lat} className={LABEL_CLASS}>
                {t("customerApp.tracking.yourLocation")}
              </MapMarkerLabel>
            </>
          ) : null}

          {routePoints.length > 1 ? (
            <>
              <MapPolyline path={routePoints} color={ROUTE_COLOR} weight={6} opacity={0.92} zIndex={5} />
              {/* Small round end-caps — google.maps.Polyline has no native
                  line-cap style, this approximates the spec's "rounded
                  edges" requirement cheaply. */}
              <MapMarker longitude={routePoints[0].lng} latitude={routePoints[0].lat} variant="dot" color={ROUTE_COLOR} />
              <MapMarker
                longitude={routePoints[routePoints.length - 1].lng}
                latitude={routePoints[routePoints.length - 1].lat}
                variant="dot"
                color={ROUTE_COLOR}
              />
            </>
          ) : null}

          {technicianPosition ? (
            <>
              <MapPulseMarker longitude={technicianPosition.lng} latitude={technicianPosition.lat} color={ROUTE_COLOR} />
              <MapMarker longitude={technicianPosition.lng} latitude={technicianPosition.lat} variant="arrow" color={ROUTE_COLOR} rotationDeg={smoothedRotation} />
            </>
          ) : null}

          {!isFollowing ? (
            <Button
              type="button"
              variant="outline"
              size="icon-sm"
              onClick={handleRecenter}
              aria-label={t("customerApp.tracking.recenter")}
              title={t("customerApp.tracking.recenter")}
              className="absolute right-3 bottom-3 z-10 bg-surface shadow-sm"
            >
              <Locate className="size-4" />
            </Button>
          ) : null}
        </Map>
      ) : (
        <Skeleton className="h-full w-full rounded-none" />
      )}
    </div>
  )
}
