/** Geolocation + geofence helpers shared by Attendance (TECH-01) and Map (TECH-04). */

import { Geolocation, type Position } from "@capacitor/geolocation"

/** heading/speed mirror GeolocationCoordinates.heading/.speed — both
 * frequently null (device stationary or sensor doesn't report them), never
 * required. heading is degrees clockwise from true north; speed is m/s. */
export type GeoPoint = { lat: number; lng: number; accuracy?: number; heading?: number | null; speed?: number | null }

function toGeoPoint(pos: Position): GeoPoint {
  return {
    lat: pos.coords.latitude,
    lng: pos.coords.longitude,
    accuracy: pos.coords.accuracy,
    heading: pos.coords.heading,
    speed: pos.coords.speed,
  }
}

// Routed through @capacitor/geolocation rather than navigator.geolocation
// directly — on native it drives proper Android/iOS permission prompts, and
// on web it transparently falls back to the same browser Geolocation API,
// so this is a drop-in replacement for both platforms.

export async function getCurrentPosition(options?: PositionOptions): Promise<GeoPoint> {
  try {
    const pos = await Geolocation.getCurrentPosition({
      enableHighAccuracy: true,
      timeout: 10_000,
      maximumAge: 5_000,
      ...options,
    })
    return toGeoPoint(pos)
  } catch (err) {
    throw err instanceof Error ? err : new Error("geolocation_unsupported")
  }
}

export function watchPosition(cb: (pos: GeoPoint) => void, onError?: (err: GeolocationPositionError | Error) => void) {
  let watchId: string | null = null
  let cancelled = false

  Geolocation.watchPosition({ enableHighAccuracy: true, maximumAge: 5_000, timeout: 15_000 }, (pos, err) => {
    if (err) {
      onError?.(err instanceof Error ? err : new Error(String(err)))
      return
    }
    if (pos) cb(toGeoPoint(pos))
  })
    .then((id) => {
      if (cancelled) void Geolocation.clearWatch({ id })
      else watchId = id
    })
    .catch((err) => onError?.(err instanceof Error ? err : new Error("geolocation_unsupported")))

  return () => {
    cancelled = true
    if (watchId) void Geolocation.clearWatch({ id: watchId })
  }
}

/**
 * Maps a Geolocation failure (native GeolocationPositionError, or the plain
 * Error("geolocation_unsupported") thrown by this module on an unsupported
 * browser) to a stable kind so callers can show actionable, distinct
 * guidance instead of one generic "location error" message — permission
 * denied, GPS/network unavailable, and a stale timeout each need a
 * different fix from the technician.
 */
export type GeoErrorKind = "unsupported" | "permissionDenied" | "unavailable" | "timeout" | "unknown"

export function classifyGeoError(err: unknown): GeoErrorKind {
  if (err instanceof Error && err.message === "geolocation_unsupported") return "unsupported"
  const code = (err as GeolocationPositionError | undefined)?.code
  if (code === 1) return "permissionDenied"
  if (code === 2) return "unavailable"
  if (code === 3) return "timeout"
  // @capacitor/geolocation's native (non-web-fallback) errors don't carry
  // the numeric GeolocationPositionError.code above — only a message.
  const message = err instanceof Error ? err.message.toLowerCase() : ""
  if (message.includes("denied") || message.includes("permission")) return "permissionDenied"
  if (message.includes("unavailable") || message.includes("disabled")) return "unavailable"
  if (message.includes("timeout")) return "timeout"
  return "unknown"
}

/** Haversine distance in kilometres. */
export function distanceKm(a: GeoPoint, b: GeoPoint) {
  const R = 6371
  const dLat = ((b.lat - a.lat) * Math.PI) / 180
  const dLng = ((b.lng - a.lng) * Math.PI) / 180
  const lat1 = (a.lat * Math.PI) / 180
  const lat2 = (b.lat * Math.PI) / 180
  const h = Math.sin(dLat / 2) ** 2 + Math.sin(dLng / 2) ** 2 * Math.cos(lat1) * Math.cos(lat2)
  return R * 2 * Math.asin(Math.sqrt(h))
}

/** True when `point` is inside the geofence radius (metres) around `center`. */
export function isInsideGeofence(point: GeoPoint, center: GeoPoint, radiusM: number) {
  return distanceKm(point, center) * 1000 <= radiusM
}

/** Expected travel minutes at the admin-set per-km rate (v2.2 "1 km = 5 min"). */
export function expectedMinutes(km: number, perKmMinutes: number) {
  return km * perKmMinutes
}
