import { beforeEach, describe, expect, it, vi } from "vitest"

/**
 * address-from-location: reverseGeocode is a thin wrapper around the `geocode` Edge Function's
 * "reverse" action -- the actual Google Geocoding API call happens server-side (the key never
 * reaches the browser). This pins the exact request body sent and the two failure fallbacks
 * (Edge Function error, empty result) a caller must handle.
 */
const state: { invokeCalls: { name: string; opts: unknown }[]; nextResult: unknown; nextError: unknown } = {
  invokeCalls: [],
  nextResult: null,
  nextError: null,
}

vi.mock("@/lib/supabase", () => ({
  supabase: {
    functions: {
      invoke: (name: string, opts: unknown) => {
        state.invokeCalls.push({ name, opts })
        return Promise.resolve({ data: state.nextResult, error: state.nextError })
      },
    },
  },
}))

import { reverseGeocode } from "@/services/maps"

beforeEach(() => {
  state.invokeCalls = []
  state.nextResult = null
  state.nextError = null
})

describe("reverseGeocode", () => {
  it("sends action 'reverse' with the given coordinates to the geocode Edge Function", async () => {
    state.nextResult = { result: { formatted: "T Nagar, Chennai", lat: 13.08, lon: 80.27, city: "Chennai", district: "Chennai", state: "Tamil Nadu", postcode: "600017", suburb: "T Nagar", locationType: "ROOFTOP", streetNumber: "12", route: "Usman Road" } }
    const result = await reverseGeocode(13.08, 80.27)
    expect(state.invokeCalls[0].name).toBe("geocode")
    expect(state.invokeCalls[0].opts).toEqual({ body: { action: "reverse", lat: 13.08, lng: 80.27 } })
    expect(result.suburb).toBe("T Nagar")
    expect(result.streetNumber).toBe("12")
  })

  it("failure fallback: throws when the Edge Function itself errors", async () => {
    state.nextError = new Error("Edge Function returned 502")
    await expect(reverseGeocode(13.08, 80.27)).rejects.toThrow("Edge Function returned 502")
  })

  it("failure fallback: throws a clear error when the Edge Function returns no result at all", async () => {
    state.nextResult = {}
    await expect(reverseGeocode(13.08, 80.27)).rejects.toThrow("No address found for that location")
  })
})
