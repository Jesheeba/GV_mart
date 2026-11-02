import { useCallback, useState } from "react"

export type GeolocateErrorKind = "denied" | "unavailable" | "timeout"
export type GeolocateCoords = { latitude: number; longitude: number; accuracy: number }

/** Exported for tests -- pure, no React/browser-state involved. */
export function classifyGeolocationError(err: GeolocationPositionError): GeolocateErrorKind {
  if (err.code === err.PERMISSION_DENIED) return "denied"
  if (err.code === err.TIMEOUT) return "timeout"
  return "unavailable"
}

/**
 * One-shot browser Geolocation wrapper, shared by the map widget's own corner "locate" control
 * (MapControls, components/ui/map.tsx) and the new visible "Use my current location" button
 * (AddressMapPicker) -- customer-side discoverability fix: the corner control is icon-only with
 * no visible label, easy to miss, so a labelled button was added directly above the map in
 * every customer-app address surface. Both now go through the exact same geolocation call and
 * the exact same denied/unavailable/timeout classification, so neither path can silently drift
 * from the other.
 */
export function useGeolocateOnce() {
  const [locating, setLocating] = useState(false)

  const locate = useCallback((onSuccess: (coords: GeolocateCoords) => void, onError: (kind: GeolocateErrorKind) => void) => {
    if (!("geolocation" in navigator)) {
      onError("unavailable")
      return
    }
    setLocating(true)
    navigator.geolocation.getCurrentPosition(
      (pos) => {
        setLocating(false)
        onSuccess({ latitude: pos.coords.latitude, longitude: pos.coords.longitude, accuracy: pos.coords.accuracy })
      },
      (err) => {
        setLocating(false)
        onError(classifyGeolocationError(err))
      },
      // A finite timeout (the browser default is unspecified and can hang far longer than a
      // tap-and-wait UI should) so the "timeout" classification above is actually reachable.
      { enableHighAccuracy: true, timeout: 10_000, maximumAge: 0 }
    )
  }, [])

  return { locating, locate }
}
