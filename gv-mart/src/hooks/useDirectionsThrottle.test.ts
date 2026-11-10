import { beforeEach, describe, expect, it } from "vitest"
import {
  _resetDirectionsThrottleForTests,
  getThrottledOrigin,
  isDirectionsFetchEnabled,
  shouldRetryDirectionsFetch,
} from "./useMaps"

/**
 * geocode rate-limit follow-up: the fleet live-tracking map's own over-fetching (a new
 * Directions call on every Realtime location ping, not throttled by React Query's staleTime
 * once the query key itself changes) was the real driver of staff-tier Google Maps volume.
 * These are the pure decision functions behind the fix -- no React rendering needed.
 */
beforeEach(() => {
  _resetDirectionsThrottleForTests()
})

describe("getThrottledOrigin (movement + time throttle)", () => {
  const CHENNAI = { lat: 13.0827, lng: 80.2707 }
  const NEARBY_200M = { lat: 13.0845, lng: 80.2707 } // ~0.2 km north
  const FAR_500M = { lat: 13.0872, lng: 80.2707 } // ~0.5 km north

  it("accepts the very first origin for a technician immediately", () => {
    const result = getThrottledOrigin("tech-1", CHENNAI, 1_000_000)
    expect(result).toEqual(CHENNAI)
  })

  it("does NOT refetch when moved far enough but not enough time has passed", () => {
    getThrottledOrigin("tech-1", CHENNAI, 1_000_000)
    const result = getThrottledOrigin("tech-1", FAR_500M, 1_000_000 + 10_000) // only 10s later
    expect(result).toEqual(CHENNAI) // still the old origin
  })

  it("does NOT refetch when enough time has passed but hasn't moved far enough", () => {
    getThrottledOrigin("tech-1", CHENNAI, 1_000_000)
    const result = getThrottledOrigin("tech-1", NEARBY_200M, 1_000_000 + 120_000) // 120s later, only ~0.2km
    expect(result).toEqual(CHENNAI) // still the old origin -- under the 0.3km threshold
  })

  it("refetches once BOTH thresholds are cleared (moved >=300m AND >=90s passed)", () => {
    getThrottledOrigin("tech-1", CHENNAI, 1_000_000)
    const result = getThrottledOrigin("tech-1", FAR_500M, 1_000_000 + 95_000) // 95s later, ~0.5km moved
    expect(result).toEqual(FAR_500M)
  })

  it("tracks each technician independently", () => {
    getThrottledOrigin("tech-1", CHENNAI, 1_000_000)
    const other = getThrottledOrigin("tech-2", FAR_500M, 1_000_000) // brand new technician, first call
    expect(other).toEqual(FAR_500M)
  })

  it("returns null when there's no technician id or no origin at all (no active job / no location yet)", () => {
    expect(getThrottledOrigin(null, CHENNAI, 1_000_000)).toBeNull()
    expect(getThrottledOrigin("tech-1", null, 1_000_000)).toBeNull()
  })
})

describe("isDirectionsFetchEnabled", () => {
  const origin = { lat: 13.0827, lng: 80.2707 }
  const destination = { lat: 13.09, lng: 80.28 }

  it("is enabled when technician, origin, destination are all present and the tab is visible", () => {
    expect(isDirectionsFetchEnabled("tech-1", origin, destination, false)).toBe(true)
  })

  it("is disabled while the browser tab is hidden, even with everything else present", () => {
    expect(isDirectionsFetchEnabled("tech-1", origin, destination, true)).toBe(false)
  })

  it("is disabled with no active job (destination null)", () => {
    expect(isDirectionsFetchEnabled("tech-1", origin, null, false)).toBe(false)
  })

  it("is disabled with no technician id or no origin", () => {
    expect(isDirectionsFetchEnabled(null, origin, destination, false)).toBe(false)
    expect(isDirectionsFetchEnabled("tech-1", null, destination, false)).toBe(false)
  })
})

describe("shouldRetryDirectionsFetch (429 fallback)", () => {
  it("never retries a 429 (rate-limited) response", () => {
    expect(shouldRetryDirectionsFetch(0, { context: { status: 429 } })).toBe(false)
  })

  it("retries a transient failure once", () => {
    expect(shouldRetryDirectionsFetch(0, new Error("network blip"))).toBe(true)
  })

  it("does not retry a transient failure a second time", () => {
    expect(shouldRetryDirectionsFetch(1, new Error("network blip"))).toBe(false)
  })
})
