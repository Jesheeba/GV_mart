import { useMutation, useQuery } from "@tanstack/react-query"
import * as maps from "@/services/maps"

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

/** Real driving distance + live-traffic travel time, for the admin
 * live-tracking map (v2.2 §6.6) and the technician's own ETA widget. Keyed
 * on coordinates rounded to ~100m so small GPS jitter reuses the cached
 * result instead of re-calling Directions on every Realtime location tick. */
export function useDirectionsDistance(
  origin: { lat: number; lng: number } | null,
  destination: { lat: number; lng: number } | null
) {
  const originKey = origin ? `${origin.lat.toFixed(3)},${origin.lng.toFixed(3)}` : null
  const destKey = destination ? `${destination.lat.toFixed(3)},${destination.lng.toFixed(3)}` : null
  return useQuery({
    queryKey: ["maps", "directions", originKey, destKey],
    queryFn: () => maps.getDirectionsDistance(origin!, destination!),
    enabled: !!origin && !!destination,
    staleTime: 45_000,
    retry: 1,
  })
}
