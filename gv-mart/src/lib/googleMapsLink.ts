/**
 * "Pin my address" (20261201100000). Deliberately NOT imported from
 * app/technician/MapPage.tsx, which this same-format URL also appears in —
 * that file is tied to geofence/location-permission code that this feature
 * must not touch, so the format is duplicated here instead of shared.
 */
export function googleMapsPinUrl(lat: number, lng: number): string {
  const params = new URLSearchParams({ api: "1", destination: `${lat},${lng}` })
  return `https://www.google.com/maps/dir/?${params.toString()}`
}

export function isValidLat(lat: number): boolean {
  return Number.isFinite(lat) && lat >= -90 && lat <= 90
}

export function isValidLng(lng: number): boolean {
  return Number.isFinite(lng) && lng >= -180 && lng <= 180
}

export function isValidCoordPair(lat: number | null | undefined, lng: number | null | undefined): boolean {
  if (lat == null || lng == null) return false
  return isValidLat(lat) && isValidLng(lng)
}
