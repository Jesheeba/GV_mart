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

/** Real driving distance (km) via the Directions API, proxied through the
 * `geocode` Edge Function (v2.2 §6.6 live tracking). Returns null when
 * Google finds no drivable route (ZERO_RESULTS) — callers should fall back
 * to straight-line distance rather than treat that as an error. */
export async function getDirectionsDistanceKm(
  origin: { lat: number; lng: number },
  destination: { lat: number; lng: number }
): Promise<number | null> {
  const { data, error } = await supabase.functions.invoke<{ distanceKm: number | null }>("geocode", {
    body: { action: "directions", origin, destination },
  })
  if (error) throw error
  return data?.distanceKm ?? null
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
