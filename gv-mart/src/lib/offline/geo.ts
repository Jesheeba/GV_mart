/** Geolocation + geofence helpers shared by Attendance (TECH-01) and Map (TECH-04). */

import { Geolocation, type Position } from "@capacitor/geolocation"
import { Capacitor } from "@capacitor/core"

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

function normalizeGeoError(err: unknown): Error {
  if (err instanceof Error) return err
  if (typeof err === "object" && err !== null) {
    const message = "message" in err && typeof err.message === "string" ? err.message : "geolocation_error"
    const code = "code" in err && typeof err.code === "number" ? err.code : undefined
    return Object.assign(new Error(message), code === undefined ? {} : { code })
  }
  return new Error(typeof err === "string" ? err : "geolocation_error")
}

// Brave's own navigator.brave.isBrave() is present regardless of its
// Shields settings, so this detects the browser itself, not whether
// geolocation is actually being blocked — used only to pick a more useful
// error message (Shields settings vs. "switch browsers") once geolocation
// has already turned out to be unavailable.
function isBraveBrowser(): boolean {
  return typeof navigator !== "undefined" && typeof (navigator as unknown as { brave?: { isBrave?: unknown } }).brave?.isBrave === "function"
}

// Shared by getCurrentPosition and watchPosition so a missing
// navigator.geolocation (unsupported browser, or Brave Shields having
// removed it — see isBraveBrowser's doc comment) is reported the same way
// from both entry points instead of watchPosition falling through to
// whatever generic error Capacitor's web plugin happens to throw instead.
function checkGeoSupport() {
  if (Capacitor.isNativePlatform()) return
  if (typeof window !== "undefined" && window.isSecureContext === false) {
    throw new Error("geolocation_insecure_context")
  }
  if (typeof navigator === "undefined" || !navigator.geolocation) {
    // Brave's "Block fingerprinting" Shields setting (Standard, not just
    // Aggressive) removes navigator.geolocation entirely rather than
    // just denying permission on call, so it lands here looking
    // identical to a truly unsupported browser — but unlike a real
    // unsupported browser, it's fixable per-site from Shields, so it
    // gets its own message instead of "use a different browser".
    throw new Error(isBraveBrowser() ? "geolocation_brave_blocked" : "geolocation_unsupported")
  }
}

// Routed through @capacitor/geolocation rather than navigator.geolocation
// directly — on native it drives proper Android/iOS permission prompts, and
// on web it transparently falls back to the same browser Geolocation API,
// so this is a drop-in replacement for both platforms.

export async function getCurrentPosition(options?: PositionOptions): Promise<GeoPoint> {
  checkGeoSupport()

  try {
    const pos = await Geolocation.getCurrentPosition({
      enableHighAccuracy: true,
      timeout: 20_000,
      maximumAge: 5_000,
      ...options,
    })
    return toGeoPoint(pos)
  } catch (err) {
    const normalized = normalizeGeoError(err)
    // enableHighAccuracy forces a GPS-chip fix, which can genuinely take
    // longer than even a generous timeout indoors or with a weak signal —
    // the single most common real-world complaint from technicians. A
    // much faster network/cell-based fix trades precision for actually
    // getting a position, which is what the geofence/selfie-watermark
    // callers need far more than GPS-grade accuracy, so retry once before
    // surfacing a hard error. Skipped if the caller explicitly asked for
    // low accuracy already (nothing more to fall back to).
    if (classifyGeoError(normalized) === "timeout" && options?.enableHighAccuracy !== false) {
      try {
        const pos = await Geolocation.getCurrentPosition({ enableHighAccuracy: false, timeout: 10_000, maximumAge: 5_000 })
        return toGeoPoint(pos)
      } catch (fallbackErr) {
        throw normalizeGeoError(fallbackErr)
      }
    }
    throw normalized
  }
}

export function watchPosition(cb: (pos: GeoPoint) => void, onError?: (err: GeolocationPositionError | Error) => void) {
  let watchId: string | null = null
  let cancelled = false

  // Caller contract is "always returns a stop function, report failures via
  // onError" (see useLiveLocationStream/MapPage/AttendancePage, none of
  // which wrap this call in try/catch) — so a synchronous checkGeoSupport
  // throw has to be caught here and handed to onError instead of escaping.
  try {
    checkGeoSupport()
  } catch (err) {
    queueMicrotask(() => onError?.(normalizeGeoError(err)))
    return () => {}
  }

  Geolocation.watchPosition({ enableHighAccuracy: true, maximumAge: 5_000, timeout: 20_000 }, (pos, err) => {
    if (err) {
      onError?.(normalizeGeoError(err))
      return
    }
    if (pos) cb(toGeoPoint(pos))
  })
    .then((id) => {
      if (cancelled) void Geolocation.clearWatch({ id })
      else watchId = id
    })
    .catch((err) => onError?.(normalizeGeoError(err)))

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
export type GeoErrorKind = "unsupported" | "braveBlocked" | "insecureContext" | "permissionDenied" | "unavailable" | "timeout" | "unknown"

export function classifyGeoError(err: unknown): GeoErrorKind {
  const message =
    typeof err === "object" && err !== null && "message" in err && typeof err.message === "string"
      ? err.message.toLowerCase()
      : err instanceof Error
        ? err.message.toLowerCase()
        : ""
  if (message === "geolocation_unsupported") return "unsupported"
  if (message === "geolocation_brave_blocked") return "braveBlocked"
  if (message === "geolocation_insecure_context") return "insecureContext"
  const code = typeof err === "object" && err !== null && "code" in err ? err.code : undefined
  if (code === 1) return "permissionDenied"
  if (code === 2) return "unavailable"
  if (code === 3) return "timeout"
  // @capacitor/geolocation's native (non-web-fallback) errors don't carry
  // the numeric GeolocationPositionError.code above — only a message.
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
