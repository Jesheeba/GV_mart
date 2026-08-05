import { useEffect, useMemo, useRef, useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate, useSearchParams } from "react-router-dom"
import { CheckCircle2, Loader2, MapPin, Navigation, RefreshCw, TriangleAlert } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { useProfile } from "@/hooks/useProfile"
import { useDirectionsDistance } from "@/hooks/useMaps"
import { useJobDetail, useMyTechnician, useStartVisit, useTechnicianSettings, useTodaysJobs } from "@/hooks/useTechnician"
import { classifyGeoError, distanceKm, expectedMinutes, getCurrentPosition, isInsideGeofence, watchPosition, type GeoPoint } from "@/lib/offline/geo"
import { findOpenVisit, isTicketClosed, OFFICE_LOCATION, selectNextJob } from "@/services/technician"
import { cn } from "@/lib/utils"
import { PhotoCapture } from "./components/PhotoCapture"

// Deliberately takes the technician's own live-tracked `position` as an
// explicit `origin=`, rather than leaving it out and letting Google Maps
// resolve "Your location" itself on open — that resolution can return a
// stale/cached browser geolocation fix, which reads to the technician as
// the map "repeating the old" starting point on every tap instead of
// routing from where they actually are right now.
function googleMapsUrl(dest: GeoPoint, origin?: GeoPoint | null) {
  const params = new URLSearchParams({ api: "1", destination: `${dest.lat},${dest.lng}` })
  if (origin) params.set("origin", `${origin.lat},${origin.lng}`)
  return `https://www.google.com/maps/dir/?${params.toString()}`
}

// v2.2 §6.5/§6.6: arrival is detected "within a small threshold" and must
// auto-start the productivity timer. GPS drift (multipath bounce, a single
// noisy fix) can make one reading look within range while the technician is
// genuinely still far off, or flicker in/out right at the boundary — so
// arrival requires *sustained* proximity from a fix accurate enough to
// trust, not one lucky sample.
//
// This same radius also gates the manual "I've Arrived" button (see
// `insideArrivalGeofence` below) — tapping it must not start the
// productivity timer from across town. 250m is the midpoint of tech.md's
// 200-300m guidance, reconciled here into one shared constant used by both
// the auto-detect effect and the manual button instead of two diverging
// thresholds.
const ARRIVAL_GEOFENCE_RADIUS_M = 250
const ARRIVAL_CONFIRM_MS = 15_000
const MAX_USABLE_ACCURACY_M = 75

// The browser Geolocation API only returns real GPS on a device with a GPS
// chip (phones); on a desktop/laptop it falls back to Wi-Fi/IP-based
// positioning, which is routinely off by several kilometres. Rather than
// silently showing a confidently-wrong distance/ETA from a fix that coarse,
// surface it — `position.accuracy` past this threshold means "don't trust
// this number" (well above MAX_USABLE_ACCURACY_M, which gates the much
// stricter arrival-detection radius above).
const LOW_ACCURACY_WARNING_M = 500

const GEO_ERROR_KEYS: Record<ReturnType<typeof classifyGeoError>, string> = {
  unsupported: "technician.map.locationUnsupported",
  permissionDenied: "technician.map.locationPermissionDenied",
  unavailable: "technician.map.locationUnavailable",
  timeout: "technician.map.locationTimeout",
  unknown: "technician.map.locationError",
}

export function MapPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const [searchParams] = useSearchParams()
  const ticketId = searchParams.get("ticketId") ?? undefined

  const { data: profile } = useProfile()
  const technician = useMyTechnician()
  const settings = useTechnicianSettings(profile?.org_id)
  const jobDetail = useJobDetail(ticketId)
  const todaysJobs = useTodaysJobs(technician.data?.id)
  const startVisit = useStartVisit()

  const [position, setPosition] = useState<GeoPoint | null>(null)
  const [geoError, setGeoError] = useState<string | null>(null)
  const [refreshingLocation, setRefreshingLocation] = useState(false)
  const [arrived, setArrived] = useState(false)
  const [arrivedAt, setArrivedAt] = useState<number | null>(null)
  const [elapsedSec, setElapsedSec] = useState(0)
  const [confirming, setConfirming] = useState(false)
  // Task 6 — arrival location verification: a selfie is required before
  // arrival (manual tap or the auto-detect timer) is allowed to confirm.
  const [arrivalSelfie, setArrivalSelfie] = useState<string | null>(null)

  const withinSinceRef = useRef<number | null>(null)
  const arrivedRef = useRef(false)
  // Which ticket the arrival state below was last (re-)derived for — guards
  // the reset effect against re-running on every incidental jobDetail cache
  // update (e.g. a background refetch racing the offline outbox's ~20s sync
  // delay) and stomping a real, already-decided "arrived" state back to
  // "not arrived". Only an actual destination change re-derives it.
  const arrivalInitForTicketRef = useRef<string | null>(null)

  // Hoisted above fallbackJob below (rather than left inline near their other
  // use further down) because selectNextJob needs both to pick a
  // destination: the technician's current position (falling back to the
  // office when GPS hasn't returned a fix yet, same as the live distance/ETA
  // card) and the admin-set travel-time rate for projecting arrival times
  // against each remaining job's availability window.
  const origin = position ?? OFFICE_LOCATION
  const perKmMinutes = settings.data?.per_km_minutes ?? 5

  const ticket = jobDetail.data
  // Build Order STEP 5 / Assignment spec Phase 4 — when no specific ticket
  // was chosen (arrived here via the Map tab, not a job's "Navigate"
  // button), the destination is the nearest remaining job whose
  // availability window is open at the projected arrival, skipping a closer
  // job that isn't available yet in favour of a farther one that is (see
  // computeRouteOrder's doc comment in services/technician.ts). Recomputed
  // every render from the live position/clock, so once the technician
  // finishes the job this picked and moves on, the skipped job is
  // reconsidered fresh from the new position.
  const fallbackJob = !ticketId ? selectNextJob(todaysJobs.data ?? [], origin, new Date(), perKmMinutes) : undefined
  const destAddress = ticket?.addresses ?? fallbackJob?.service_tickets.addresses ?? null
  const destCustomerName = ticket?.customers?.name ?? fallbackJob?.service_tickets.customers?.name ?? null
  const destTicketId = ticketId ?? fallbackJob?.ticket_id ?? null
  const destScheduledAt = ticket?.appointments?.[0]?.scheduled_at ?? fallbackJob?.scheduled_at ?? null
  const destClosed = isTicketClosed(ticket?.status ?? fallbackJob?.service_tickets.status ?? null)
  const destLat = destAddress?.lat ?? null
  const destLng = destAddress?.lng ?? null
  // Memoized on the underlying primitives, not just recreated on every
  // render: the arrival effect below depends on `dest` by reference, and an
  // unmemoized object would re-run that effect on every render even when
  // the destination hasn't actually changed.
  const dest = useMemo<GeoPoint | null>(() => (destLat != null && destLng != null ? { lat: destLat, lng: destLng } : null), [destLat, destLng])
  // Gates the manual "I've Arrived" button (Bug 5/6, Logic 5): without this,
  // tapping it starts the visit/productivity timer regardless of actual GPS
  // distance to the customer. Same radius and helper as the auto-detect
  // effect below, just evaluated on every render for the button's
  // disabled/guard checks rather than the sustained-proximity state machine.
  const insideArrivalGeofence = position != null && dest != null && isInsideGeofence(position, dest, ARRIVAL_GEOFENCE_RADIUS_M)

  // Deliberately `position` (the raw GPS fix), not `origin` — `origin` falls
  // back to OFFICE_LOCATION so selectNextJob above always has *some* start
  // point to order today's jobs from. Reusing that same fallback here would
  // silently show the technician a real "office → customer" distance/ETA
  // whenever their own GPS fix hasn't arrived yet, with nothing on screen to
  // say it isn't actually their position.
  const directions = useDirectionsDistance(dest && position ? position : null, dest)

  // The confirm-window interval below is set up once and never re-runs (see
  // its own comment), so it must call through a ref rather than closing over
  // handleArrived directly — otherwise it would keep calling the version
  // captured on the very first render, before destTicketId/profile/
  // technician.data had loaded, and silently no-op forever.
  const handleArrivedRef = useRef<() => void>(() => {})

  async function handleArrived() {
    // Defense in depth beyond the button's `disabled` guard below — an
    // in-flight tap racing a fresh out-of-range position update (or a
    // programmatic call via handleArrivedRef, i.e. the auto-detect timer)
    // must not slip through. Task 6: the selfie requirement is enforced
    // here too, not just on the manual button, so the auto-detect timer
    // can't confirm arrival without one either.
    if (arrivedRef.current || !destTicketId || !profile || !technician.data || destClosed || !insideArrivalGeofence || !arrivalSelfie) return
    arrivedRef.current = true
    setArrived(true)
    setArrivedAt(Date.now())
    const existing = ticket?.service_visits ? findOpenVisit(ticket.service_visits) : null
    if (existing) {
      setArrivedAt(new Date(existing.timer_start!).getTime())
      return
    }
    const id = crypto.randomUUID()
    const nowIso = new Date().toISOString()
    // Fire-and-forget, matching OnSiteVisitPage's own start-visit call: the
    // local draft + outbox write already succeeded by the time this
    // resolves, so a network hiccup on the online-only appointment status
    // flip shouldn't block the "arrived" UI transition.
    void startVisit.mutateAsync({
      id,
      orgId: profile.org_id,
      ticketId: destTicketId,
      technicianId: technician.data.id,
      timerStart: nowIso,
      arrivalSelfieUrl: arrivalSelfie ?? undefined,
    })
  }
  handleArrivedRef.current = () => void handleArrived()

  // Continuous position while this screen is open — feeds both the
  // live-updating distance/ETA display and the arrival state machine below.
  useEffect(() => {
    setGeoError(null)
    const stop = watchPosition(
      (pos) => setPosition(pos),
      (err) => setGeoError(t(GEO_ERROR_KEYS[classifyGeoError(err)]))
    )
    return stop
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // Manual re-fetch for when the continuous watch above is stuck on a stale
  // fix — some browsers/OSes only push a fresh Wi-Fi/IP-based position
  // occasionally, so a technician who's physically moved can otherwise be
  // stuck looking at an old reading with no way to force a retry.
  async function refreshLocation() {
    setRefreshingLocation(true)
    setGeoError(null)
    try {
      const pos = await getCurrentPosition({ maximumAge: 0 })
      setPosition(pos)
    } catch (err) {
      setGeoError(t(GEO_ERROR_KEYS[classifyGeoError(err)]))
    } finally {
      setRefreshingLocation(false)
    }
  }

  // Resets/restores arrival state when the destination job changes — and, if
  // this job already has an open visit (started from a previous visit to
  // this screen, or from JobDetailPage's direct "Start visit"), adopts it
  // instead of showing "not arrived" for a job that's actually in progress.
  // Only re-derives once per destTicketId (see arrivalInitForTicketRef's doc
  // comment) — a later jobDetail refetch for the *same* ticket must not
  // re-run this, or it would treat "the outbox hasn't synced yet" the same
  // as "no visit was ever started" and flip a real arrival back off.
  useEffect(() => {
    if (!destTicketId || arrivalInitForTicketRef.current === destTicketId) return
    if (ticketId && !ticket) return // jobDetail for this ticket hasn't loaded yet — wait for the real answer instead of locking in "not arrived"
    arrivalInitForTicketRef.current = destTicketId
    arrivedRef.current = false
    withinSinceRef.current = null
    setArrivalSelfie(null)
    const existing = ticket?.service_visits ? findOpenVisit(ticket.service_visits) : null
    if (existing) {
      arrivedRef.current = true
      setArrived(true)
      setArrivedAt(new Date(existing.timer_start!).getTime())
    } else {
      setArrived(false)
      setArrivedAt(null)
    }
  }, [destTicketId, ticket, ticketId])

  // Arrival state machine: only advances/resets on fixes accurate enough to
  // trust, and requires ARRIVAL_CONFIRM_MS of sustained proximity before
  // triggering — see the constants' doc comment above for why. Also never
  // runs once the job is completed/cancelled — without this, a technician
  // revisiting an already-finished job's map (stale ?ticketId= URL, browser
  // back) would still get GPS-driven auto-arrival, spinning up a brand-new
  // service_visits row for a job that's already done.
  useEffect(() => {
    if (!position || !dest || arrived || destClosed) {
      setConfirming(false)
      return
    }
    if (position.accuracy != null && position.accuracy > MAX_USABLE_ACCURACY_M) {
      return
    }
    const withinRange = isInsideGeofence(position, dest, ARRIVAL_GEOFENCE_RADIUS_M)
    if (!withinRange) {
      withinSinceRef.current = null
      setConfirming(false)
      return
    }
    if (withinSinceRef.current == null) withinSinceRef.current = Date.now()
    setConfirming(true)
  }, [position, dest, arrived, destClosed])

  // Confirms arrival on a timer independent of new position fixes: once a
  // device's GPS stabilizes near a destination it can go quiet for tens of
  // seconds without watchPosition firing again, so waiting on the *next* fix
  // to re-check the sustained-proximity window would make arrival unreliable
  // (or never fire at all against a static/rarely-updating position).
  useEffect(() => {
    if (arrived) return
    const interval = setInterval(() => {
      if (withinSinceRef.current != null && Date.now() - withinSinceRef.current >= ARRIVAL_CONFIRM_MS) {
        handleArrivedRef.current()
      }
    }, 1000)
    return () => clearInterval(interval)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [arrived])

  useEffect(() => {
    if (!arrivedAt) return
    const interval = setInterval(() => setElapsedSec(Math.floor((Date.now() - arrivedAt) / 1000)), 1000)
    return () => clearInterval(interval)
  }, [arrivedAt])

  // jobDetail is only relevant (and only loading) when navigated here with a
  // specific ?ticketId= — without one, dest falls back to today's nearest
  // job instead. Without this gate, a specific-ticket navigation could flash
  // "No destination selected" before the ticket query resolved, since `dest`
  // derives from jobDetail.data with no loading check of its own.
  if (technician.isLoading || settings.isLoading || (!!ticketId && jobDetail.isLoading)) {
    return <FullPageLoader label={t("common.loading")} />
  }
  if (technician.isError || !technician.data) {
    return <FullPageError message={t("technician.errors.loadFailed")} onRetry={() => technician.refetch()} retryLabel={t("common.retry")} />
  }
  if (ticketId && jobDetail.isError) {
    return <FullPageError message={t("technician.errors.loadFailed")} onRetry={() => jobDetail.refetch()} retryLabel={t("common.retry")} />
  }

  // Same reasoning as the `directions` hook above: only compute a distance
  // once we have the technician's actual GPS fix, never from the
  // OFFICE_LOCATION fallback baked into `origin`.
  const routeKm = dest && position ? (directions.data?.distanceKm ?? distanceKm(position, dest)) : null
  const km = routeKm
  // Task 2 — prefer the real Directions API travel time (live-traffic aware)
  // over the flat admin-set per-km-minutes rate; the flat rate only fills in
  // until Directions resolves (or if it errors/finds no route).
  const realDurationMinutes = directions.data?.durationMinutes ?? null
  const etaMinutes = realDurationMinutes != null ? Math.round(realDurationMinutes) : km != null ? Math.round(expectedMinutes(km, perKmMinutes)) : null
  const expectedArrivalAt = etaMinutes != null ? new Date(Date.now() + etaMinutes * 60_000) : null

  const isIdle = !!geoError && !position
  const indicatorState: "on-time" | "confirming" | "tracking" | "idle" =
    arrived ? "on-time" : confirming ? "confirming" : isIdle ? "idle" : "tracking"
  const statusColor =
    indicatorState === "on-time" ? "text-success" : indicatorState === "idle" ? "text-danger" : indicatorState === "confirming" ? "text-warning" : "text-warning"
  const statusDotColor =
    indicatorState === "on-time" ? "bg-success" : indicatorState === "idle" ? "bg-danger" : "bg-warning"
  const statusLabel =
    indicatorState === "on-time"
      ? t("technician.map.statusOnRoute")
      : indicatorState === "confirming"
        ? t("technician.map.statusConfirming")
        : indicatorState === "idle"
          ? t("technician.map.statusIdle")
          : t("technician.map.statusTracking")

  const minutes = String(Math.floor(elapsedSec / 60)).padStart(2, "0")
  const seconds = String(elapsedSec % 60).padStart(2, "0")

  return (
    <div className="space-y-4 pt-2">
      <h1 className="text-xl font-bold text-text">{t("technician.map.title")}</h1>

      {destClosed ? (
        <Card className="items-center gap-2 py-8 text-center">
          <CheckCircle2 className="size-8 text-success" />
          <p className="text-sm font-medium text-text">{t("technician.map.jobClosedTitle")}</p>
          <p className="text-xs text-text-muted">{t("technician.map.jobClosedBody")}</p>
        </Card>
      ) : !dest ? (
        <Card className="items-center gap-2 py-8 text-center">
          <MapPin className="size-8 text-text-muted" />
          <p className="text-sm font-medium text-text">{t("technician.map.noDestinationTitle")}</p>
          <p className="text-xs text-text-muted">{t("technician.map.noDestinationBody")}</p>
        </Card>
      ) : (
        <>
          <Card className="gap-3">
            <div className="flex items-center justify-between gap-2 px-1">
              <div className="flex items-center gap-2">
                <span className={cn("flex size-2.5 shrink-0 rounded-full", statusDotColor)} />
                <p className={cn("text-sm font-medium", statusColor)}>{statusLabel}</p>
              </div>
              <button
                type="button"
                onClick={() => void refreshLocation()}
                disabled={refreshingLocation}
                className="flex items-center gap-1 text-xs font-medium text-text-muted disabled:opacity-50"
              >
                <RefreshCw className={cn("size-3.5", refreshingLocation && "animate-spin")} />
                {t("technician.map.refreshLocation")}
              </button>
            </div>
            {geoError ? (
              <p className="flex items-center gap-1.5 px-1 text-xs text-danger">
                <TriangleAlert className="size-3.5" /> {geoError}
              </p>
            ) : !position ? (
              <p className="px-1 text-xs text-text-muted">{t("technician.map.awaitingLocation")}</p>
            ) : position.accuracy != null && position.accuracy > LOW_ACCURACY_WARNING_M ? (
              <p className="flex items-center gap-1.5 px-1 text-xs text-warning">
                <TriangleAlert className="size-3.5 shrink-0" />
                {t("technician.map.lowAccuracyWarning", { accuracy: Math.round(position.accuracy).toLocaleString("en-IN") })}
              </p>
            ) : null}

            <div className="grid grid-cols-2 gap-3 px-1">
              <div>
                <p className="text-xs text-text-muted">{t("technician.map.distance")}</p>
                <p className="text-lg font-semibold text-text">{km != null ? t("technician.map.distanceKm", { km: km.toFixed(1) }) : "—"}</p>
              </div>
              <div>
                <p className="text-xs text-text-muted">{t("technician.map.eta")}</p>
                <p className="text-lg font-semibold text-text">{etaMinutes != null ? t("technician.map.etaMinutes", { minutes: etaMinutes }) : "—"}</p>
              </div>
            </div>

            {/* Task 2 — live expected-arrival time alongside the admin's
                originally scheduled appointment time, kept as two distinct
                lines rather than merged into one, per the requirement. */}
            <div className="grid grid-cols-2 gap-3 px-1">
              <div>
                <p className="text-xs text-text-muted">{t("technician.map.expectedArrival")}</p>
                <p className="text-sm font-medium text-text">
                  {expectedArrivalAt ? expectedArrivalAt.toLocaleTimeString("en-IN", { hour: "2-digit", minute: "2-digit" }) : "—"}
                </p>
              </div>
              <div>
                <p className="text-xs text-text-muted">{t("technician.map.scheduledAppointment")}</p>
                <p className="text-sm font-medium text-text">
                  {destScheduledAt
                    ? new Date(destScheduledAt).toLocaleTimeString("en-IN", { hour: "2-digit", minute: "2-digit" })
                    : t("service.appointment.always")}
                </p>
              </div>
            </div>

            <div className="px-1">
              <p className="text-sm font-medium text-text">{destCustomerName ?? t("technician.home.unknownCustomer")}</p>
              <p className="text-xs text-text-muted">{[destAddress?.door_no, destAddress?.area].filter(Boolean).join(", ") || "—"}</p>
            </div>

            <a href={googleMapsUrl(dest, position)} target="_blank" rel="noreferrer" className="w-full">
              <Button type="button" variant="outline" className="w-full">
                <Navigation className="size-4" />
                {t("technician.map.openInMaps")}
              </Button>
            </a>
          </Card>

          <Card className="gap-3">
            {arrived ? (
              <div className="items-center gap-2 text-center">
                <CheckCircle2 className="mx-auto size-8 text-success" />
                <p className="text-sm font-semibold text-text">{t("technician.map.arrivedTitle")}</p>
                <p className="font-mono text-2xl font-bold text-text">
                  {minutes}:{seconds}
                </p>
                <p className="text-xs text-text-muted">{t("technician.map.productivityTimerNote")}</p>
                {destTicketId ? (
                  <Button type="button" className="mt-2 w-full" onClick={() => navigate(`/technician/jobs/${destTicketId}/visit`)}>
                    {t("technician.map.continueToService")}
                  </Button>
                ) : null}
              </div>
            ) : (
              <>
                {confirming ? <p className="text-center text-xs text-warning">{t("technician.map.confirmingArrivalNote")}</p> : null}
                {/* Task 6 — arrival location verification: required before either
                    the manual button or the auto-detect timer can confirm arrival. */}
                <PhotoCapture label={t("technician.map.arrivalSelfieLabel")} dataUrl={arrivalSelfie} onCaptured={setArrivalSelfie} />
                <Button type="button" disabled={startVisit.isPending || !insideArrivalGeofence || !arrivalSelfie} onClick={() => void handleArrived()}>
                  {startVisit.isPending ? <Loader2 className="size-4 animate-spin" /> : t("technician.map.arrivedButton")}
                </Button>
                {insideArrivalGeofence && !arrivalSelfie ? (
                  <p className="text-center text-xs text-text-muted">{t("technician.map.arrivalSelfieRequired")}</p>
                ) : null}
                {!insideArrivalGeofence ? (
                  <p className="text-center text-xs text-text-muted">
                    {position ? t("technician.map.arrivedOutsideGeofence", { radius: ARRIVAL_GEOFENCE_RADIUS_M }) : t("technician.map.arrivedNoLocation")}
                  </p>
                ) : null}
              </>
            )}
          </Card>
        </>
      )}
    </div>
  )
}
