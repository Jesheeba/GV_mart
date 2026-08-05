import { supabase } from "@/lib/supabase"

export type GeocodeResult = {
  formatted: string
  lat: number
  lon: number
  city: string | null
  district: string | null
  state: string | null
  postcode: string | null
  suburb: string | null
  // Google's confidence flag for this match — ROOFTOP/RANGE_INTERPOLATED are
  // precise; GEOMETRIC_CENTER/APPROXIMATE mean Google is guessing (common for
  // survey-number/rural addresses), see the geocode Edge Function's own
  // comment on this field.
  locationType: string | null
}

/** True for Google location_type values precise enough to auto-confirm
 * without forcing the user to verify/drag first. */
export function isPreciseGeocodeResult(locationType: string | null): boolean {
  return locationType === "ROOFTOP" || locationType === "RANGE_INTERPOLATED"
}

export type AutocompletePrediction = { placeId: string; description: string }

/** Proxied through the `geocode` Edge Function — the Google Maps API key never reaches the browser.
 * Live-as-you-type suggestions (text only, no coordinates yet). Pass the
 * same sessionToken on every keystroke of one search, then to
 * getPlaceDetails when the user picks a result — that's what keeps the
 * whole sequence billed as one cheap Autocomplete session instead of
 * per-request. */
export async function autocompleteAddress(input: string, sessionToken: string): Promise<AutocompletePrediction[]> {
  const { data, error } = await supabase.functions.invoke<{ predictions: AutocompletePrediction[] }>("geocode", {
    body: { action: "autocomplete", input, sessionToken },
  })
  if (error) throw error
  return data?.predictions ?? []
}

/** Resolves a prediction's place_id into coordinates + address components, closing out the Autocomplete session started by autocompleteAddress (same sessionToken). */
export async function getPlaceDetails(placeId: string, sessionToken: string): Promise<GeocodeResult> {
  const { data, error } = await supabase.functions.invoke<{ result: GeocodeResult }>("geocode", {
    body: { action: "details", placeId, sessionToken },
  })
  if (error) throw error
  if (!data?.result) throw new Error("No location details returned")
  return data.result
}

/** One-shot forward geocode (Geocoding API, no session token) — used as a fallback when Autocomplete returns zero predictions. */
export async function geocodeAddress(query: string): Promise<GeocodeResult[]> {
  const { data, error } = await supabase.functions.invoke<{ results: GeocodeResult[] }>("geocode", {
    body: { action: "geocode", query },
  })
  if (error) throw error
  return data?.results ?? []
}

/**
 * Decodes Google's polyline encoding (the algorithm behind Directions'
 * `overview_polyline.points`) into a plain lat/lng path — standard
 * algorithm, see https://developers.google.com/maps/documentation/utilities/polylinealgorithm.
 * No dependency on the Maps JS API (`google.maps.geometry.encoding` would
 * work too, but that's an extra library the Map loader doesn't request
 * today, see components/ui/map.tsx), so this runs even before/without the
 * JS API finishing its load.
 */
export function decodePolyline(encoded: string): { lat: number; lng: number }[] {
  const path: { lat: number; lng: number }[] = []
  let index = 0
  let lat = 0
  let lng = 0

  while (index < encoded.length) {
    let shift = 0
    let result = 0
    let byte: number
    do {
      byte = encoded.charCodeAt(index++) - 63
      result |= (byte & 0x1f) << shift
      shift += 5
    } while (byte >= 0x20)
    lat += result & 1 ? ~(result >> 1) : result >> 1

    shift = 0
    result = 0
    do {
      byte = encoded.charCodeAt(index++) - 63
      result |= (byte & 0x1f) << shift
      shift += 5
    } while (byte >= 0x20)
    lng += result & 1 ? ~(result >> 1) : result >> 1

    path.push({ lat: lat / 1e5, lng: lng / 1e5 })
  }
  return path
}

export type DirectionsResult = { distanceKm: number | null; durationMinutes: number | null; path: { lat: number; lng: number }[] | null }

/** Real driving distance (km) + travel time (minutes, live-traffic when
 * available) + the actual road-following route geometry, via the Directions
 * API proxied through the `geocode` Edge Function (v2.2 §6.6 live tracking;
 * `path` added for the route-focused tracking map — Premium Live Tracking).
 * All fields are null when Google finds no drivable route (ZERO_RESULTS) —
 * callers should fall back to straight-line distance / a straight polyline
 * rather than treat that as an error. */
export async function getDirectionsDistance(
  origin: { lat: number; lng: number },
  destination: { lat: number; lng: number }
): Promise<DirectionsResult> {
  const { data, error } = await supabase.functions.invoke<{
    distanceKm: number | null
    durationMinutes: number | null
    overviewPolyline: string | null
  }>("geocode", {
    body: { action: "directions", origin, destination },
  })
  if (error) throw error
  return {
    distanceKm: data?.distanceKm ?? null,
    durationMinutes: data?.durationMinutes ?? null,
    path: data?.overviewPolyline ? decodePolyline(data.overviewPolyline) : null,
  }
}

/** Proxied through the `map-config` Edge Function — the Google Maps API key is fetched at runtime rather than baked into the client bundle (it still ends up client-visible once the Maps JS script loads; see map-config's comment on why that's unavoidable and how it's mitigated). */
export async function getMapApiKey(): Promise<string> {
  const { data, error } = await supabase.functions.invoke<{ apiKey: string }>("map-config", {
    method: "GET",
  })
  if (error) throw error
  if (!data?.apiKey) throw new Error("map-config returned no apiKey")
  return data.apiKey
}
