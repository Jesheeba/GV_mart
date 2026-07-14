// Proxies the Google Maps Platform for the customer address-picker. The
// Google Maps API key stays a Deno.env secret here — never sent to or held
// by the browser. JWT verification stays on (the project default), so only
// signed-in staff can call this, not the open internet.
//
// Four actions, matching Google's own two-step Autocomplete flow plus a
// plain-geocode fallback and a driving-distance lookup for live tracking:
//   - "autocomplete": Places Autocomplete API — live-as-you-type predictions
//     (text only, no coordinates). Billed as part of an Autocomplete
//     *session* when a sessionToken is supplied and the session ends with a
//     "details" call using that same token — much cheaper than per-request
//     billing, which is why the token must be threaded through correctly.
//   - "details": Place Details API — resolves a prediction's place_id into
//     coordinates + address components, using the same sessionToken to
//     close out (and bill) the session.
//   - "geocode": Geocoding API — a plain one-shot forward geocode, billed
//     per call with no session concept. Used as a fallback when Autocomplete
//     returns zero predictions (e.g. plus-codes, unusual queries) so the
//     picker still has somewhere to go.
//   - "directions": Directions API (v2.2 §6.6 live tracking) — real driving
//     distance from a technician's current position to a job's address, used
//     by the admin tracking map to compare against the admin-set per-km
//     standard and to flag an off-route technician (driving distance far
//     exceeding the straight-line distance). Requires "Directions API"
//     enabled on the same Google Cloud project/key as the other three.
import { corsHeaders, handleCors } from "../_shared/cors.ts"

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

type AutocompletePrediction = { placeId: string; description: string }

type LatLng = { lat: number; lng: number }

type GeocodeRequest =
  | { action: "autocomplete"; input: string; sessionToken: string }
  | { action: "details"; placeId: string; sessionToken: string }
  | { action: "geocode"; query: string }
  | { action: "directions"; origin: LatLng; destination: LatLng }

type GoogleAddressComponent = { long_name: string; short_name: string; types: string[] }

function jsonError(message: string, status: number) {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  })
}

function jsonOk(body: unknown) {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  })
}

function extractComponents(components: GoogleAddressComponent[]) {
  const find = (type: string) => components.find((c) => c.types.includes(type))?.long_name ?? null
  return {
    city: find("locality") ?? find("administrative_area_level_2"),
    // Kept as its own field (not folded into `city`'s fallback above) so a
    // result with a real `locality` still surfaces India's district-level
    // administrative_area_level_2 separately — the address form has a
    // distinct District input that city's fallback chain was never wired to.
    district: find("administrative_area_level_2"),
    state: find("administrative_area_level_1"),
    postcode: find("postal_code"),
    suburb: find("sublocality_level_1") ?? find("sublocality") ?? find("neighborhood"),
  }
}

function toGeocodeResult(r: {
  formatted_address?: string
  geometry?: { location?: { lat?: number; lng?: number } }
  address_components?: GoogleAddressComponent[]
}): GeocodeResult | null {
  const lat = r.geometry?.location?.lat
  const lon = r.geometry?.location?.lng
  if (lat == null || lon == null) return null
  const { city, district, state, postcode, suburb } = extractComponents(r.address_components ?? [])
  return { formatted: r.formatted_address ?? "", lat, lon, city, district, state, postcode, suburb }
}

// GV Mart operates out of Chennai — a soft preference (biases ranking, does
// not exclude results elsewhere), matching the same "bias not a hard filter"
// intent the previous Geoapify integration used.
const CHENNAI_LOCATION_BIAS = "circle:50000@13.0827,80.2707"

async function callGoogle(pathname: string, params: Record<string, string>) {
  const url = new URL(`https://maps.googleapis.com/maps/api/${pathname}/json`)
  for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v)
  let res: Response
  try {
    res = await fetch(url)
  } catch {
    throw new Response(JSON.stringify({ error: "Could not reach the Google Maps service" }), {
      status: 502,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    })
  }
  if (!res.ok) {
    throw new Response(JSON.stringify({ error: `Google Maps service returned ${res.status}` }), {
      status: 502,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    })
  }
  const data = await res.json()
  if (data.status !== "OK" && data.status !== "ZERO_RESULTS") {
    const detail = data.error_message ? `: ${data.error_message}` : ""
    throw new Response(JSON.stringify({ error: `Google Maps error (${data.status})${detail}` }), {
      status: 502,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    })
  }
  return data
}

Deno.serve(async (req) => {
  const preflight = handleCors(req)
  if (preflight) return preflight

  if (req.method !== "POST") {
    return jsonError("Method not allowed", 405)
  }

  let body: GeocodeRequest
  try {
    body = await req.json()
  } catch {
    return jsonError("Invalid JSON body", 400)
  }

  const apiKey = Deno.env.get("GOOGLE_MAPS_API_KEY")
  if (!apiKey) {
    return jsonError("Geocoding is not configured (missing GOOGLE_MAPS_API_KEY)", 500)
  }

  try {
    if (body.action === "autocomplete") {
      if (typeof body.input !== "string" || body.input.trim().length < 3) {
        return jsonError("input must be a string of at least 3 characters", 400)
      }
      if (typeof body.sessionToken !== "string" || !body.sessionToken) {
        return jsonError("sessionToken is required", 400)
      }
      const data = await callGoogle("place/autocomplete", {
        input: body.input.trim(),
        key: apiKey,
        sessiontoken: body.sessionToken,
        locationbias: CHENNAI_LOCATION_BIAS,
        language: "en",
      })
      const predictions: AutocompletePrediction[] = (data.predictions ?? []).map(
        (p: { place_id: string; description: string }) => ({ placeId: p.place_id, description: p.description })
      )
      return jsonOk({ predictions })
    }

    if (body.action === "details") {
      if (typeof body.placeId !== "string" || !body.placeId) {
        return jsonError("placeId is required", 400)
      }
      if (typeof body.sessionToken !== "string" || !body.sessionToken) {
        return jsonError("sessionToken is required", 400)
      }
      const data = await callGoogle("place/details", {
        place_id: body.placeId,
        key: apiKey,
        sessiontoken: body.sessionToken,
        fields: "formatted_address,geometry,address_component",
        language: "en",
      })
      const result = data.result ? toGeocodeResult(data.result) : null
      if (!result) return jsonError("Could not resolve that place to a location", 502)
      return jsonOk({ result })
    }

    if (body.action === "geocode") {
      if (typeof body.query !== "string" || body.query.trim().length < 3) {
        return jsonError("query must be a string of at least 3 characters", 400)
      }
      const data = await callGoogle("geocode", {
        address: body.query.trim(),
        key: apiKey,
        region: "in",
        language: "en",
      })
      const results: GeocodeResult[] = (data.results ?? [])
        .map(toGeocodeResult)
        .filter((r: GeocodeResult | null): r is GeocodeResult => r !== null)
      return jsonOk({ results })
    }

    if (body.action === "directions") {
      const isLatLng = (p: unknown): p is LatLng =>
        !!p && typeof p === "object" && typeof (p as LatLng).lat === "number" && typeof (p as LatLng).lng === "number"
      if (!isLatLng(body.origin) || !isLatLng(body.destination)) {
        return jsonError("origin and destination must each be {lat, lng}", 400)
      }
      const data = await callGoogle("directions", {
        origin: `${body.origin.lat},${body.origin.lng}`,
        destination: `${body.destination.lat},${body.destination.lng}`,
        mode: "driving",
        key: apiKey,
      })
      const distanceMeters = data.routes?.[0]?.legs?.[0]?.distance?.value ?? null
      return jsonOk({ distanceKm: distanceMeters != null ? distanceMeters / 1000 : null })
    }

    return jsonError("action must be one of: autocomplete, details, geocode, directions", 400)
  } catch (e) {
    if (e instanceof Response) return e
    return jsonError("Unexpected error while geocoding", 500)
  }
})
