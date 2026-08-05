import { useEffect, useRef, useState } from "react"
import { supabase } from "@/lib/supabase"
import { useLatestTechnicianLocation } from "@/hooks/useCustomerApp"
import type { TechnicianLocationRow } from "@/services/customerApp"
import { bearingDegrees, haversineDistanceKm, interpolatePoint, type LatLng } from "@/lib/tracking/geo"
import { deriveTrackingStage, type TrackingStage, type TrackingStageInput } from "@/lib/tracking/stages"

/** Ceiling on the technician's publish throttle (see useLiveLocationStream) —
 * tweening across this long guarantees the marker finishes easing into a fix
 * before (or right as) the next one lands, so it never "waits" mid-tween. */
const TWEEN_DURATION_MS = 4000
/** No fresh ping in this long → treat the connection as degraded, independent
 * of whether the Realtime channel itself still reports SUBSCRIBED (covers a
 * technician's phone losing GPS/signal, not just a socket drop). */
const STALE_AFTER_MS = 90_000

type Locations = { current: TechnicianLocationRow | null; previous: TechnicianLocationRow | null }

export type ConnectionState = "live" | "reconnecting" | "no_location"

export type LiveTrackingResult = {
  /** Smoothed/interpolated point — use this for marker rendering. */
  position: LatLng | null
  /** Latest RAW GPS fix (not tweened) — this is what the map's own
   * client-side DirectionsService call uses as the route origin, so a route
   * recalculation is tied to real position changes, not animation frames. */
  rawPosition: LatLng | null
  bearingDeg: number | null
  /** Straight-line distance, recomputed locally on every tween frame — cheap, used for the "nearby" threshold and as an immediate readout before the real road distance (from TrackingMap's own DirectionsService call) arrives. */
  distanceKm: number | null
  stage: TrackingStage
  /** Increments exactly once per transition into "arrived_working" — consumers useEffect on this to fire a one-shot celebration. */
  arrivalSignal: number
  connectionState: ConnectionState
  minutesSinceUpdate: number | null
}

export function useLiveTracking(params: {
  technicianId: string | undefined
  destination: LatLng | null
  stageInput: Omit<TrackingStageInput, "distanceKm">
}): LiveTrackingResult {
  const { technicianId, destination, stageInput } = params
  const { data: initialLocation } = useLatestTechnicianLocation(technicianId)
  const [locations, setLocations] = useState<Locations>({ current: null, previous: null })
  const [channelState, setChannelState] = useState<"connecting" | "live" | "reconnecting">("connecting")
  const [position, setPosition] = useState<LatLng | null>(null)
  const [bearingDeg, setBearingDeg] = useState<number | null>(null)
  const [now, setNow] = useState(() => Date.now())
  const rafRef = useRef<number | null>(null)

  useEffect(() => {
    if (!initialLocation) return
    setLocations((prev) => (prev.current ? prev : { current: initialLocation, previous: null }))
  }, [initialLocation])

  useEffect(() => {
    if (!technicianId) return
    const channel = supabase
      .channel(`customer-tracking-${technicianId}`)
      .on(
        "postgres_changes",
        { event: "INSERT", schema: "public", table: "technician_locations", filter: `technician_id=eq.${technicianId}` },
        (payload) => {
          const next = payload.new as TechnicianLocationRow
          setLocations((prev) => ({ current: next, previous: prev.current }))
        }
      )
      .subscribe((status) => {
        if (status === "SUBSCRIBED") setChannelState("live")
        else if (status === "CHANNEL_ERROR" || status === "TIMED_OUT" || status === "CLOSED") setChannelState("reconnecting")
      })

    return () => {
      supabase.removeChannel(channel)
    }
  }, [technicianId])

  // Ticks independently of pings so "minutes since update"/staleness stays
  // accurate between GPS fixes, not just re-derived when a new one lands.
  useEffect(() => {
    const id = window.setInterval(() => setNow(Date.now()), 10_000)
    return () => window.clearInterval(id)
  }, [])

  // Tween the marker between the last two fixes instead of snapping — the
  // "never jump" requirement. Runs a plain rAF loop rather than a CSS
  // transition because the map wrapper's MapMarker imperatively calls
  // marker.setPosition() (legacy google.maps.Marker, no CSS to animate).
  useEffect(() => {
    const { current, previous } = locations
    if (!current) return
    if (!previous) {
      setPosition({ lat: current.lat, lng: current.lng })
      return
    }
    const from: LatLng = { lat: previous.lat, lng: previous.lng }
    const to: LatLng = { lat: current.lat, lng: current.lng }
    // Prefer the device's own GeolocationCoordinates.heading (persisted
    // Premium Live Tracking — more accurate than deriving it from two fixes,
    // especially right after the publish throttle stretched the gap between
    // them out to 10-20s) — fall back to the computed bearing when the
    // device didn't report one (common while stationary/turning in place).
    if (current.heading != null) {
      setBearingDeg(current.heading)
    } else {
      const moved = haversineDistanceKm(from, to) > 0.003 // >3m — ignore GPS jitter, keep prior heading
      if (moved) setBearingDeg(bearingDegrees(from, to))
    }

    const start = performance.now()
    function tick(t: number) {
      const progress = Math.min(1, (t - start) / TWEEN_DURATION_MS)
      setPosition(interpolatePoint(from, to, progress))
      if (progress < 1) {
        rafRef.current = requestAnimationFrame(tick)
      }
    }
    rafRef.current = requestAnimationFrame(tick)
    return () => {
      if (rafRef.current != null) cancelAnimationFrame(rafRef.current)
    }
  }, [locations])

  const distanceKm = position && destination ? haversineDistanceKm(position, destination) : null
  const rawPosition: LatLng | null = locations.current ? { lat: locations.current.lat, lng: locations.current.lng } : null

  const stage = deriveTrackingStage({ ...stageInput, distanceKm })

  const prevStageRef = useRef<TrackingStage | null>(null)
  const [arrivalSignal, setArrivalSignal] = useState(0)
  useEffect(() => {
    if (stage === "arrived_working" && prevStageRef.current && prevStageRef.current !== "arrived_working") {
      setArrivalSignal((n) => n + 1)
    }
    prevStageRef.current = stage
  }, [stage])

  const recordedAtMs = locations.current ? new Date(locations.current.recorded_at).getTime() : null
  const minutesSinceUpdate = recordedAtMs != null ? Math.max(0, Math.round((now - recordedAtMs) / 60_000)) : null

  let connectionState: ConnectionState = "no_location"
  if (locations.current) {
    connectionState = channelState === "reconnecting" || (recordedAtMs != null && now - recordedAtMs > STALE_AFTER_MS) ? "reconnecting" : "live"
  }

  return {
    position,
    rawPosition,
    bearingDeg,
    distanceKm,
    stage,
    arrivalSignal,
    connectionState,
    minutesSinceUpdate,
  }
}
