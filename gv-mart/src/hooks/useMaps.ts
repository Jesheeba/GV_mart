import { useEffect, useState } from "react"
import { useMutation, useQuery } from "@tanstack/react-query"
import * as maps from "@/services/maps"
import { isTooManyRequestsError } from "@/services/maps"
import { distanceKm, type GeoPoint } from "@/lib/offline/geo"

export function useMapApiKey() {
  return useQuery({
    queryKey: ["maps", "apiKey"],
    queryFn: () => maps.getMapApiKey(),
    staleTime: 5 * 60_000,
    retry: 1,
  })
}

export function useAutocomplete() {
  return useMutation({
    mutationFn: ({ input, sessionToken }: { input: string; sessionToken: string }) => maps.autocompleteAddress(input, sessionToken),
  })
}

export function usePlaceDetails() {
  return useMutation({
    mutationFn: ({ placeId, sessionToken }: { placeId: string; sessionToken: string }) => maps.getPlaceDetails(placeId, sessionToken),
  })
}

/** One-shot Geocoding API fallback for when Autocomplete comes back empty — no session token involved. */
export function useGeocodeAddress() {
  return useMutation({
    mutationFn: (query: string) => maps.geocodeAddress(query),
  })
}

/** "Use my current location" -> address text (reverse geocode), for AddressForm and AddressPinDialog. */
export function useReverseGeocode() {
  return useMutation({
    mutationFn: ({ lat, lng }: { lat: number; lng: number }) => maps.reverseGeocode(lat, lng),
  })
}

// address-from-location rate-limit follow-up (geocode_rate_limit): this is what actually drove
// staff-tier Google Directions volume high enough to need its own daily cap raised/fixed --
// Realtime technician_locations pings update `origin` far more often than the live-tracking
// map actually needs a fresh route for. Re-fetch only when the technician has genuinely moved
// a meaningful distance AND a minimum amount of wall-clock time has passed, whichever caller
// renders first for a given technician (module-level, not per-hook-instance, so the marker and
// the status-row callers for the SAME technician -- which already dedupe to one network
// request via an identical query key -- keep landing on the identical throttled key, not two
// slightly different ones).
const DIRECTIONS_THROTTLE_MIN_INTERVAL_MS = 90_000
const DIRECTIONS_THROTTLE_MIN_MOVE_KM = 0.3
const lastAcceptedOriginByTechnician = new Map<string, { origin: GeoPoint; at: number }>()

/** Exported for tests only -- lets each test start from a clean slate instead of leaking
 * accepted-origin state between cases (this map is otherwise module-lifetime, by design, to
 * survive component remounts within one browser session). */
export function _resetDirectionsThrottleForTests() {
  lastAcceptedOriginByTechnician.clear()
}

/** Exported for tests -- pure, no React/network involved. */
export function getThrottledOrigin(technicianId: string | null, origin: GeoPoint | null, now: number): GeoPoint | null {
  if (!technicianId || !origin) return null
  const last = lastAcceptedOriginByTechnician.get(technicianId)
  if (!last) {
    lastAcceptedOriginByTechnician.set(technicianId, { origin, at: now })
    return origin
  }
  const movedEnough = distanceKm(last.origin, origin) >= DIRECTIONS_THROTTLE_MIN_MOVE_KM
  const enoughTimePassed = now - last.at >= DIRECTIONS_THROTTLE_MIN_INTERVAL_MS
  if (movedEnough && enoughTimePassed) {
    lastAcceptedOriginByTechnician.set(technicianId, { origin, at: now })
    return origin
  }
  return last.origin
}

/** True while the browser tab is hidden (backgrounded/minimized) -- pauses the live-tracking
 * map's own polling while nobody is looking at it, the other half of the same cost-reduction
 * fix as the movement/time throttle above. */
function useIsTabHidden() {
  const [hidden, setHidden] = useState(() => typeof document !== "undefined" && document.hidden)
  useEffect(() => {
    const onVisibilityChange = () => setHidden(document.hidden)
    document.addEventListener("visibilitychange", onVisibilityChange)
    return () => document.removeEventListener("visibilitychange", onVisibilityChange)
  }, [])
  return hidden
}

/** Exported for tests -- pure. Never retry a 429 (that would only add to the same limit it
 * just hit); a transient network/5xx failure still gets its one retry, same as before. */
export function shouldRetryDirectionsFetch(failureCount: number, error: unknown): boolean {
  return !isTooManyRequestsError(error) && failureCount < 1
}

/** Exported for tests -- pure. */
export function isDirectionsFetchEnabled(
  technicianId: string | null,
  effectiveOrigin: GeoPoint | null,
  destination: GeoPoint | null,
  isTabHidden: boolean
): boolean {
  return !!technicianId && !!effectiveOrigin && !!destination && !isTabHidden
}

/**
 * Real driving distance + live-traffic travel time, for the admin live-tracking map (v2.2
 * §6.6) and the technician's own ETA widget. `technicianId` is required (not just
 * origin/destination coordinates) so the movement/time throttle above can track "has THIS
 * technician moved enough" independent of coordinate rounding.
 *
 * Stops fetching entirely when there's no active job (destination null, same as before), when
 * the tab is hidden, or when the rate limiter returns 429 for this user (the per-user limit is
 * server-side and shared across every technician this one dispatcher is watching, so retrying
 * immediately would only make it worse) -- `isRateLimited` lets the caller keep showing the
 * last known route with a small "updates paused" note instead of an error state.
 */
export function useDirectionsDistance(
  technicianId: string | null,
  origin: GeoPoint | null,
  destination: GeoPoint | null
) {
  const isTabHidden = useIsTabHidden()
  const effectiveOrigin = getThrottledOrigin(technicianId, origin, Date.now())
  const originKey = effectiveOrigin ? `${effectiveOrigin.lat.toFixed(3)},${effectiveOrigin.lng.toFixed(3)}` : null
  const destKey = destination ? `${destination.lat.toFixed(3)},${destination.lng.toFixed(3)}` : null
  const query = useQuery({
    queryKey: ["maps", "directions", technicianId, originKey, destKey],
    queryFn: () => maps.getDirectionsDistance(effectiveOrigin!, destination!),
    enabled: isDirectionsFetchEnabled(technicianId, effectiveOrigin, destination, isTabHidden),
    staleTime: DIRECTIONS_THROTTLE_MIN_INTERVAL_MS,
    retry: shouldRetryDirectionsFetch,
  })
  return { ...query, isRateLimited: isTooManyRequestsError(query.error) }
}
