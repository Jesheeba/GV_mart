import { useEffect, useMemo, useRef, useState } from "react"
import { useTranslation } from "react-i18next"
import { MapPin, Route } from "lucide-react"
import { Button, buttonVariants } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger } from "@/components/ui/dropdown-menu"
import { StatusDot, type StatusTone } from "@/components/shared/StatusDot"
import { Map, MapControls, MapMarker, MapMarkerLabel, MapPolyline, type MapViewport } from "@/components/ui/map"
import { useProfile } from "@/hooks/useProfile"
import { useDirectionsDistance, useMapApiKey } from "@/hooks/useMaps"
import {
  useTechniciansActiveJobs,
  useTechniciansOpenVisits,
  useTechniciansWithLocation,
  useTechnicianActiveAppointments,
  useTechnicianTrailForDate,
  useTechnicianVisitTimingsForDate,
} from "@/hooks/useTechniciansAdmin"
import { useSettings } from "@/hooks/useMasters"
import { listRecentTechnicianLocations, notifyJobOverrunAlert } from "@/services/techniciansAdmin"
import { supabase } from "@/lib/supabase"
import { distanceKm } from "@/lib/offline/geo"
import { computeJobOverrun } from "@/lib/job-overrun"
import { buildDayLegs, classifyRouteTrail, mergeDayLegs, sliceTrailForWindow, ROUTE_COLOR_HEX, type ClassifiedRouteSegment, type IdleSpot } from "@/lib/routeColor"
import type { TechnicianActiveJob, TechnicianLocationRow, TechnicianOpenVisit, TechnicianWithLatestLocation } from "@/services/techniciansAdmin"
import { cn } from "@/lib/utils"

// v2.2 §6.6: "A per kilometre travel time is set by you... If the technician
// reaches within the expected time, the map shows green. If they take a
// wrong route or stay somewhere for 5 to 10 minutes, it shows a red box
// explaining how long they stayed." These constants implement that as two
// independent, cheap-to-compute proxies (no ground-truth "correct route"
// exists to compare against):
//   - idle: no meaningful movement for IDLE_TRIGGER_MINUTES, straight from
//     the location history buffer — no Directions call needed.
//   - off-route: Directions' real driving distance is far larger than the
//     straight-line distance to the destination — a route deviation, not
//     just ordinary road curvature.
const HISTORY_WINDOW_MINUTES = 12
const IDLE_TRIGGER_MINUTES = 5
const IDLE_MOVE_THRESHOLD_KM = 0.05
const OFF_ROUTE_RATIO = 1.6

const CHENNAI_CENTER: MapViewport = { center: [80.2707, 13.0827], zoom: 11 }

function todayDateStr() {
  const now = new Date()
  const pad = (n: number) => String(n).padStart(2, "0")
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`
}

const COLOR_ON_TIME = "#2fae5f"
const COLOR_ALERT = "#e5484d"
const COLOR_NEUTRAL = "#8a8a82"

const LABEL_CLASS =
  "whitespace-nowrap rounded-md border border-border bg-surface px-1.5 py-0.5 text-[10px] font-medium text-text shadow-sm"

type TrackingStatus = "no-job" | "no-location" | "on-time" | "idle" | "off-route"

/** Walks a technician's recent location history backward from the latest
 * known fix, extending "stationary since" as long as each earlier point
 * stays within IDLE_MOVE_THRESHOLD_KM of it. Anchored on `latestLocation`
 * (not history's own last element) so a feed that has gone completely
 * silent — history empty because even the newest ping fell outside the
 * lookback window — still reports its true age instead of silently
 * resetting to 0, which would misreport a stopped technician as on-time. */
function computeIdleMinutes(latestLocation: TechnicianLocationRow, history: TechnicianLocationRow[], nowMs: number) {
  const latestPoint = { lat: latestLocation.lat, lng: latestLocation.lng }
  let stationarySince = latestLocation.recorded_at
  for (let i = history.length - 1; i >= 0; i--) {
    const p = history[i]
    if (distanceKm({ lat: p.lat, lng: p.lng }, latestPoint) > IDLE_MOVE_THRESHOLD_KM) break
    stationarySince = p.recorded_at
  }
  return (nowMs - new Date(stationarySince).getTime()) / 60_000
}

function useTechnicianTrackingStatus(
  latestLocation: TechnicianLocationRow | null,
  activeJob: TechnicianActiveJob | undefined,
  history: TechnicianLocationRow[],
  nowMs: number
): { status: TrackingStatus; idleMinutes: number } {
  const origin = latestLocation ? { lat: latestLocation.lat, lng: latestLocation.lng } : null
  const destination = activeJob ? { lat: activeJob.lat, lng: activeJob.lng } : null
  // React Query dedupes this against the identical call made from the map
  // marker for the same technician — one network request, two consumers.
  const directions = useDirectionsDistance(origin, destination)

  if (!latestLocation) return { status: "no-location", idleMinutes: 0 }
  if (!activeJob || !destination) return { status: "no-job", idleMinutes: 0 }

  const idleMinutes = computeIdleMinutes(latestLocation, history, nowMs)
  if (idleMinutes >= IDLE_TRIGGER_MINUTES) return { status: "idle", idleMinutes }

  const straightKm = distanceKm(origin!, destination)
  const routeKm = directions.data?.distanceKm ?? null
  const offRoute = routeKm != null && straightKm > 0.1 && routeKm / straightKm > OFF_ROUTE_RATIO
  if (offRoute) return { status: "off-route", idleMinutes: 0 }

  return { status: "on-time", idleMinutes: 0 }
}

function statusColor(status: TrackingStatus) {
  if (status === "on-time") return COLOR_ON_TIME
  if (status === "idle" || status === "off-route") return COLOR_ALERT
  return COLOR_NEUTRAL
}

function statusTone(status: TrackingStatus): StatusTone {
  if (status === "on-time") return "success"
  if (status === "idle" || status === "off-route") return "danger"
  return "neutral"
}

const STALE_WARNING_MINUTES = 10
const STALE_DANGER_MINUTES = 60

/** Independent of TrackingStatus/idle detection above (both of which only
 * apply while a technician has an active job) — this covers the case a
 * technician's location feed has simply gone silent (phone off, app
 * force-closed) with nothing else in the UI to flag it. */
function minutesAgoClass(minutesAgo: number) {
  if (minutesAgo >= STALE_DANGER_MINUTES) return "text-danger"
  if (minutesAgo >= STALE_WARNING_MINUTES) return "text-warning"
  return "text-text-muted"
}

function useTicker(intervalMs: number) {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), intervalMs)
    return () => clearInterval(id)
  }, [intervalMs])
  return now
}

/**
 * Build Order A4: independent of TrackingStatus above (that's about travel
 * toward the *next* destination; this is about time spent *inside* the job
 * already started) so it's computed separately and layered on top rather
 * than folded into the same union — a technician can be mid-visit (no
 * meaningful "destination" to compare position against) while still
 * overrunning.
 */
function useJobOverrunAlert(openVisit: TechnicianOpenVisit | undefined, nowMs: number) {
  // GV.md 1.2: allowedDurationMinutes (estimate + earned allowances — see
  // src/lib/job-allowance.ts, precomputed in listTechniciansOpenVisits)
  // replaces the raw estimatedDurationMinutes as the overrun comparison.
  return computeJobOverrun(
    { timerStart: openVisit?.timerStart, timerEnd: openVisit?.timerEnd, estimatedDurationMinutes: openVisit?.allowedDurationMinutes },
    nowMs
  )
}

/**
 * ADM-15 / v2.2 §6.6. A real Google Map replaces the earlier coordinate
 * "pin board" placeholder now that GOOGLE_MAPS_API_KEY is configured
 * (see src/components/ui/map.tsx). Green = on time toward the technician's
 * current job; red = idle 5+ minutes or a route far longer than the
 * straight-line distance, per the spec's own two red-flag conditions.
 */
export function TechniciansMapPage() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: technicians, isLoading, isError, refetch } = useTechniciansWithLocation(orgId)
  const { data: activeJobs } = useTechniciansActiveJobs(orgId)
  const { data: openVisits } = useTechniciansOpenVisits(orgId)
  const { data: apiKey, isError: apiKeyError } = useMapApiKey()
  const { data: settings } = useSettings(orgId)

  const [liveLocations, setLiveLocations] = useState<Record<string, TechnicianLocationRow>>({})
  const [history, setHistory] = useState<Record<string, TechnicianLocationRow[]>>({})
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [viewport, setViewport] = useState<MapViewport>(CHENNAI_CENTER)
  const [mapLoadFailed, setMapLoadFailed] = useState(false)

  // A5(b) — "Track today's movement": once an admin picks a technician here,
  // this fetches that technician's whole day (active/upcoming jobs + today's
  // actual visit timing + the technician_locations trail itself) and colours
  // every leg via routeColor.ts, the same pure classifier the technician-side
  // per-job journey view (JobRoutePage) uses.
  const [trackingTechId, setTrackingTechId] = useState<string | null>(null)
  const dateStr = todayDateStr()
  const trackedAppointments = useTechnicianActiveAppointments(trackingTechId ?? undefined)
  const trackedVisits = useTechnicianVisitTimingsForDate(trackingTechId ?? undefined, dateStr)
  const trackedTrail = useTechnicianTrailForDate(trackingTechId ?? undefined, dateStr)
  const trackingLoading = !!trackingTechId && (trackedAppointments.isLoading || trackedVisits.isLoading || trackedTrail.isLoading)

  const dayRoute = useMemo(() => {
    if (!trackingTechId || !trackedAppointments.data || !trackedVisits.data || !trackedTrail.data) return null
    const dayStartIso = new Date(`${dateStr}T00:00:00`).toISOString()
    const nowIso = new Date().toISOString()
    const legs = mergeDayLegs(trackedAppointments.data, trackedVisits.data)
    const windows = buildDayLegs(legs, dayStartIso, nowIso)
    const segments: ClassifiedRouteSegment[] = []
    const idleSpots: IdleSpot[] = []
    for (const w of windows) {
      const classified = classifyRouteTrail(sliceTrailForWindow(trackedTrail.data, w.startIso, w.endIso), {
        perKmMinutes: settings?.per_km_minutes ?? 5,
        destination: w.destination,
        dueAt: w.dueAt,
      })
      segments.push(...classified.segments)
      idleSpots.push(...classified.idleSpots)
    }
    return { segments, idleSpots }
  }, [trackingTechId, trackedAppointments.data, trackedVisits.data, trackedTrail.data, dateStr, settings?.per_km_minutes])

  // Build Order A4 admin popup: fires a `notifications` row the moment a
  // technician's open visit crosses its ticket's estimated_duration_minutes.
  // notifiedVisitIdsRef is a same-session guard against re-firing every 15s
  // tick; notifyJobOverrunAlert itself re-checks the DB before inserting, so
  // reopening this page later still won't duplicate an alert already raised.
  // Runs its own interval (reading Date.now() directly) rather than driving
  // this off page-level render state, so this background check doesn't force
  // the whole technician list/map to re-render every 15s.
  const notifiedVisitIdsRef = useRef<Set<string>>(new Set())
  useEffect(() => {
    if (!orgId || !openVisits) return
    const safeOrgId = orgId
    function checkOverruns() {
      const nowMs = Date.now()
      for (const [techId, visit] of openVisits!) {
        const overrun = computeJobOverrun(
          { timerStart: visit.timerStart, timerEnd: visit.timerEnd, estimatedDurationMinutes: visit.allowedDurationMinutes },
          nowMs
        )
        if (!overrun.isOverrun || notifiedVisitIdsRef.current.has(visit.visitId)) continue
        notifiedVisitIdsRef.current.add(visit.visitId)
        const loc = liveLocations[techId]
        void notifyJobOverrunAlert(
          safeOrgId,
          visit,
          overrun.overrunByMinutes!,
          loc ? { lat: loc.lat, lng: loc.lng, recordedAt: loc.recorded_at } : null
        )
      }
    }
    checkOverruns()
    const interval = setInterval(checkOverruns, 15_000)
    return () => clearInterval(interval)
  }, [orgId, openVisits, liveLocations])

  // Seeds the idle-detection buffer with recent history so idle/off-route
  // status is available immediately on load, not only after ~5 minutes of
  // fresh Realtime events have accumulated.
  useEffect(() => {
    if (!orgId) return
    let cancelled = false
    const sinceIso = new Date(Date.now() - HISTORY_WINDOW_MINUTES * 60_000).toISOString()
    listRecentTechnicianLocations(orgId, sinceIso)
      .then((rows) => {
        if (cancelled) return
        const grouped: Record<string, TechnicianLocationRow[]> = {}
        for (const row of rows) {
          ;(grouped[row.technician_id] ??= []).push(row)
        }
        setHistory(grouped)
        setLiveLocations((prev) => {
          const next = { ...prev }
          for (const [techId, rowsForTech] of Object.entries(grouped)) {
            if (!next[techId]) next[techId] = rowsForTech[rowsForTech.length - 1]
          }
          return next
        })
      })
      .catch(() => {
        // Best-effort seed — the Realtime subscription below still populates
        // fresh data going forward even if this initial history fetch fails.
      })
    return () => {
      cancelled = true
    }
  }, [orgId])

  useEffect(() => {
    if (!orgId) return
    const channel = supabase
      .channel(`admin-technician-locations-${orgId}`)
      .on(
        "postgres_changes",
        { event: "INSERT", schema: "public", table: "technician_locations", filter: `org_id=eq.${orgId}` },
        (payload) => {
          const row = payload.new as TechnicianLocationRow
          setLiveLocations((prev) => ({ ...prev, [row.technician_id]: row }))
          setHistory((prev) => {
            const cutoff = Date.now() - HISTORY_WINDOW_MINUTES * 60_000
            const existing = (prev[row.technician_id] ?? []).filter((r) => new Date(r.recorded_at).getTime() >= cutoff)
            return { ...prev, [row.technician_id]: [...existing, row] }
          })
        }
      )
      .subscribe()
    return () => {
      supabase.removeChannel(channel)
    }
  }, [orgId])

  const rows: TechnicianWithLatestLocation[] = (technicians ?? []).map((r) => ({
    ...r,
    latestLocation: liveLocations[r.id] ?? r.latestLocation,
  }))
  const tracked = rows.filter((r) => r.latestLocation)

  function handleSelect(row: TechnicianWithLatestLocation) {
    setSelectedId(row.id)
    if (row.latestLocation) {
      setViewport({ center: [row.latestLocation.lng, row.latestLocation.lat], zoom: 14 })
    }
  }

  // A5(b) — "Track today's movement": picking a technician here overlays
  // their whole day's coloured route (dayRoute, computed above) on top of
  // the live pin-board map, additive to the existing live-position markers.
  function handleTrackSelect(row: TechnicianWithLatestLocation) {
    setTrackingTechId(row.id)
    if (row.latestLocation) {
      setViewport({ center: [row.latestLocation.lng, row.latestLocation.lat], zoom: 13 })
    }
  }

  return (
    <div className="space-y-4 pt-2">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold text-text">{t("technicians.map.title")}</h1>
          <p className="text-sm text-text-muted">{t("technicians.map.subtitle")}</p>
        </div>
        <div className="flex items-center gap-2">
          {trackingTechId ? (
            <Button type="button" variant="outline" size="sm" onClick={() => setTrackingTechId(null)}>
              {t("technicians.map.stopTracking")}
            </Button>
          ) : null}
          <DropdownMenu>
            <DropdownMenuTrigger className={cn(buttonVariants({ variant: "outline", size: "sm" }))}>
              <Route className="size-4" />
              {t("technicians.map.trackMovement")}
            </DropdownMenuTrigger>
            <DropdownMenuContent>
              {rows.length === 0 ? (
                <DropdownMenuItem disabled>{t("technicians.map.empty")}</DropdownMenuItem>
              ) : (
                rows.map((row) => (
                  <DropdownMenuItem key={row.id} onClick={() => handleTrackSelect(row)}>
                    {row.profiles?.full_name ?? "—"}
                  </DropdownMenuItem>
                ))
              )}
            </DropdownMenuContent>
          </DropdownMenu>
        </div>
      </div>

      {trackingTechId ? (
        <Card size="sm" className="gap-1.5 py-3">
          <div className="flex items-center justify-between px-1">
            <p className="text-sm font-medium text-text">
              {t("technicians.map.trackingLabel", { name: rows.find((r) => r.id === trackingTechId)?.profiles?.full_name ?? "—" })}
            </p>
            {trackingLoading ? <p className="text-xs text-text-muted">{t("common.loading")}</p> : null}
          </div>
          <div className="flex flex-wrap items-center gap-3 px-1 text-xs text-text-muted">
            <span className="flex items-center gap-1.5">
              <span className="size-2.5 rounded-full" style={{ backgroundColor: ROUTE_COLOR_HEX.green }} /> {t("technicians.map.legendGreen")}
            </span>
            <span className="flex items-center gap-1.5">
              <span className="size-2.5 rounded-full" style={{ backgroundColor: ROUTE_COLOR_HEX.yellow }} /> {t("technicians.map.legendYellow")}
            </span>
            <span className="flex items-center gap-1.5">
              <span className="size-2.5 rounded-full" style={{ backgroundColor: ROUTE_COLOR_HEX.red }} /> {t("technicians.map.legendRed")}
            </span>
          </div>
          {!trackingLoading && dayRoute && dayRoute.segments.length === 0 ? (
            <p className="px-1 text-xs text-text-muted">{t("technicians.map.trackingEmpty")}</p>
          ) : null}
        </Card>
      ) : null}

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-[320px_1fr]">
        <Card size="default" className="max-h-[600px] gap-2 overflow-y-auto">
          <p className="px-1 text-sm font-semibold text-text">{t("technicians.map.sideListTitle")}</p>
          {isLoading ? (
            <p className="px-1 text-sm text-text-muted">{t("common.loading")}</p>
          ) : isError ? (
            <div className="px-1 text-sm text-danger">
              {t("technicians.map.loadFailed")}{" "}
              <button className="underline" onClick={() => refetch()}>
                {t("common.retry")}
              </button>
            </div>
          ) : rows.length === 0 ? (
            <p className="px-1 text-sm text-text-muted">{t("technicians.map.empty")}</p>
          ) : (
            <div className="divide-y divide-border">
              {rows.map((row) => (
                <TechnicianRow
                  key={row.id}
                  row={row}
                  activeJob={activeJobs?.get(row.id)}
                  openVisit={openVisits?.get(row.id)}
                  history={history[row.id] ?? []}
                  selected={selectedId === row.id}
                  onSelect={() => handleSelect(row)}
                />
              ))}
            </div>
          )}
        </Card>

        <Card size="default" className="min-h-[420px] gap-0 overflow-hidden py-0">
          <div className="px-4 py-3">
            <p className="text-sm font-semibold text-text">{t("technicians.map.pinBoardTitle")}</p>
          </div>
          <div className="relative h-[520px] w-full border-t border-border">
            {!apiKey ? (
              <div className="flex h-full flex-col items-center justify-center gap-2 text-center">
                {apiKeyError ? (
                  <>
                    <MapPin className="size-8 text-danger" />
                    <p className="text-sm font-medium text-text">{t("technicians.map.mapLoadFailed")}</p>
                  </>
                ) : (
                  <p className="text-sm text-text-muted">{t("common.loading")}</p>
                )}
              </div>
            ) : mapLoadFailed ? (
              <div className="flex h-full flex-col items-center justify-center gap-2 text-center">
                <MapPin className="size-8 text-danger" />
                <p className="text-sm font-medium text-text">{t("technicians.map.mapLoadFailed")}</p>
              </div>
            ) : (
              <>
                <Map apiKey={apiKey} viewport={viewport} onViewportChange={setViewport} onLoadError={() => setMapLoadFailed(true)}>
                  <MapControls position="bottom-right" showZoom />
                  {tracked.map((row) => (
                    <TechnicianMarker
                      key={row.id}
                      row={row}
                      activeJob={activeJobs?.get(row.id)}
                      openVisit={openVisits?.get(row.id)}
                      history={history[row.id] ?? []}
                    />
                  ))}
                  {tracked
                    .filter((row) => activeJobs?.get(row.id))
                    .flatMap((row) => {
                      const job = activeJobs!.get(row.id)!
                      const destLabel = [job.customerName, job.addressLabel].filter(Boolean).join(" — ")
                      return [
                        <MapMarker key={`dest-${row.id}`} longitude={job.lng} latitude={job.lat} title={destLabel || undefined} />,
                        destLabel ? (
                          <MapMarkerLabel key={`dest-label-${row.id}`} longitude={job.lng} latitude={job.lat} className={LABEL_CLASS}>
                            {destLabel}
                          </MapMarkerLabel>
                        ) : null,
                      ]
                    })}
                  {/* A5(b) — the tracked technician's full-day coloured route, additive on top of the live pin-board above. */}
                  {dayRoute
                    ? dayRoute.segments.map((seg, i) => (
                        <MapPolyline
                          key={`route-${i}`}
                          path={[{ lat: seg.from.lat, lng: seg.from.lng }, { lat: seg.to.lat, lng: seg.to.lng }]}
                          color={ROUTE_COLOR_HEX[seg.color]}
                          weight={5}
                          zIndex={5}
                        />
                      ))
                    : null}
                  {dayRoute
                    ? dayRoute.idleSpots.map((spot, i) => (
                        <MapMarker
                          key={`idle-${i}`}
                          longitude={spot.point.lng}
                          latitude={spot.point.lat}
                          color={ROUTE_COLOR_HEX.red}
                          variant="ring"
                          title={t("technicians.map.idleForMinutes", { count: Math.round(spot.idleMinutes) })}
                        />
                      ))
                    : null}
                </Map>
                {tracked.length === 0 ? (
                  <div className="pointer-events-none absolute inset-0 flex flex-col items-center justify-center gap-2 bg-surface/85 text-center">
                    <MapPin className="size-8 text-text-muted" />
                    <p className="text-sm font-medium text-text">{t("technicians.map.noPinsTitle")}</p>
                    <p className="text-xs text-text-muted">{t("technicians.map.noPinsBody")}</p>
                  </div>
                ) : null}
              </>
            )}
          </div>
        </Card>
      </div>
    </div>
  )
}

function TechnicianMarker({
  row,
  activeJob,
  openVisit,
  history,
}: {
  row: TechnicianWithLatestLocation
  activeJob: TechnicianActiveJob | undefined
  openVisit: TechnicianOpenVisit | undefined
  history: TechnicianLocationRow[]
}) {
  const now = useTicker(15_000)
  const { status } = useTechnicianTrackingStatus(row.latestLocation, activeJob, history, now)
  const overrun = useJobOverrunAlert(openVisit, now)
  if (!row.latestLocation) return null
  const name = row.profiles?.full_name ?? undefined
  return (
    <>
      <MapMarker longitude={row.latestLocation.lng} latitude={row.latestLocation.lat} color={overrun.isOverrun ? COLOR_ALERT : statusColor(status)} title={name} />
      {name ? (
        <MapMarkerLabel longitude={row.latestLocation.lng} latitude={row.latestLocation.lat} className={LABEL_CLASS}>
          {name}
        </MapMarkerLabel>
      ) : null}
    </>
  )
}

function TechnicianRow({
  row,
  activeJob,
  openVisit,
  history,
  selected,
  onSelect,
}: {
  row: TechnicianWithLatestLocation
  activeJob: TechnicianActiveJob | undefined
  openVisit: TechnicianOpenVisit | undefined
  history: TechnicianLocationRow[]
  selected: boolean
  onSelect: () => void
}) {
  const { t } = useTranslation()
  const now = useTicker(15_000)
  const { status, idleMinutes } = useTechnicianTrackingStatus(row.latestLocation, activeJob, history, now)
  const overrun = useJobOverrunAlert(openVisit, now)
  const minutesAgo = row.latestLocation ? Math.round((now - new Date(row.latestLocation.recorded_at).getTime()) / 60_000) : null

  const label =
    status === "on-time"
      ? t("technicians.map.statusOnRoute")
      : status === "idle"
        ? t("technicians.map.statusIdle")
        : status === "off-route"
          ? t("technicians.map.statusOffRoute")
          : status === "no-job"
            ? t("technicians.map.noActiveJob")
            : t("technicians.map.noLocationYet")

  return (
    <button
      type="button"
      onClick={onSelect}
      className={cn(
        "flex w-full flex-col gap-1.5 px-1 py-2.5 text-left transition-colors hover:bg-surface-alt",
        selected && "bg-surface-alt"
      )}
    >
      <div className="flex w-full items-center justify-between gap-2">
        <div>
          <p className="text-sm font-medium text-text">{row.profiles?.full_name ?? "—"}</p>
          <p className={cn("text-xs", minutesAgo != null ? minutesAgoClass(minutesAgo) : "text-text-muted")}>
            {minutesAgo != null ? t("technicians.map.updatedMinutesAgo", { count: minutesAgo }) : t("technicians.map.noLocationYet")}
          </p>
        </div>
        <StatusDot tone={statusTone(status)} label={label} />
      </div>
      {status === "idle" ? (
        <p className="rounded-md border border-danger/30 bg-danger/10 px-2 py-1 text-xs font-medium text-danger">
          {t("technicians.map.idleForMinutes", { count: Math.round(idleMinutes) })}
        </p>
      ) : status === "off-route" ? (
        <p className="rounded-md border border-danger/30 bg-danger/10 px-2 py-1 text-xs font-medium text-danger">
          {t("technicians.map.offRoute")}
        </p>
      ) : null}
      {overrun.isOverrun ? (
        <p className="rounded-md border border-danger/30 bg-danger/10 px-2 py-1 text-xs font-medium text-danger">
          {t("technicians.map.jobOverrunBy", { count: Math.round(overrun.overrunByMinutes!) })}
          {openVisit?.customerName ? ` — ${openVisit.customerName}` : ""}
          {row.latestLocation ? ` (${row.latestLocation.lat.toFixed(5)}, ${row.latestLocation.lng.toFixed(5)})` : ""}
        </p>
      ) : null}
    </button>
  )
}
