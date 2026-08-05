// Pure geo math for live tracking — no DOM/React deps, so this is trivial to
// reason about independently of the map/animation plumbing that consumes it.
// Distance itself reuses lib/offline/geo.ts's existing `distanceKm` (same
// haversine formula the technician's own arrival-geofence logic already
// relies on) rather than redefining it here — only bearing/easing/tweening
// are genuinely new.

export type { GeoPoint as LatLng } from "@/lib/offline/geo"
export { distanceKm as haversineDistanceKm } from "@/lib/offline/geo"
import type { GeoPoint as LatLng } from "@/lib/offline/geo"

function toRad(deg: number) {
  return (deg * Math.PI) / 180
}

/** Initial bearing from a to b, in degrees clockwise from north (0-360). */
export function bearingDegrees(a: LatLng, b: LatLng): number {
  const lat1 = toRad(a.lat)
  const lat2 = toRad(b.lat)
  const dLng = toRad(b.lng - a.lng)
  const y = Math.sin(dLng) * Math.cos(lat2)
  const x = Math.cos(lat1) * Math.sin(lat2) - Math.sin(lat1) * Math.cos(lat2) * Math.cos(dLng)
  const deg = (Math.atan2(y, x) * 180) / Math.PI
  return (deg + 360) % 360
}

/** Cubic ease-out — used to tween the marker between two GPS fixes instead of snapping. */
export function easeOutCubic(t: number): number {
  const clamped = Math.min(1, Math.max(0, t))
  return 1 - (1 - clamped) ** 3
}

/** Linear interpolation between two points using an eased progress value (0-1). */
export function interpolatePoint(from: LatLng, to: LatLng, progress: number): LatLng {
  const t = easeOutCubic(progress)
  return { lat: from.lat + (to.lat - from.lat) * t, lng: from.lng + (to.lng - from.lng) * t }
}

/** Shortest angular difference from `from` to `to`, in degrees (-180..180) — avoids a marker spinning the long way round when bearing wraps past 0/360. */
export function shortestAngleDelta(from: number, to: number): number {
  return ((((to - from) % 360) + 540) % 360) - 180
}
