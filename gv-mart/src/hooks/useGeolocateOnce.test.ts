import { describe, expect, it } from "vitest"
import { classifyGeolocationError } from "./useGeolocateOnce"

/**
 * Customer-side discoverability fix: both the map's own corner locate control (MapControls)
 * and the new visible "Use my current location" button go through this exact classification,
 * via the shared useGeolocateOnce hook -- so neither path can show a different message for the
 * same browser error.
 */
function fakeError(code: number): GeolocationPositionError {
  return { code, PERMISSION_DENIED: 1, POSITION_UNAVAILABLE: 2, TIMEOUT: 3, message: "" } as GeolocationPositionError
}

describe("classifyGeolocationError", () => {
  it("classifies PERMISSION_DENIED as 'denied'", () => {
    expect(classifyGeolocationError(fakeError(1))).toBe("denied")
  })

  it("classifies TIMEOUT as 'timeout'", () => {
    expect(classifyGeolocationError(fakeError(3))).toBe("timeout")
  })

  it("classifies POSITION_UNAVAILABLE as 'unavailable'", () => {
    expect(classifyGeolocationError(fakeError(2))).toBe("unavailable")
  })

  it("classifies any other/unknown code as 'unavailable' (safe default, never throws)", () => {
    expect(classifyGeolocationError(fakeError(99))).toBe("unavailable")
  })
})
