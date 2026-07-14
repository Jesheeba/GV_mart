import { describe, expect, it } from "vitest"
import { classifyGeoError, distanceKm, expectedMinutes, isInsideGeofence } from "./geo"

describe("distanceKm", () => {
  it("is 0 for the same point", () => {
    expect(distanceKm({ lat: 13.0827, lng: 80.2707 }, { lat: 13.0827, lng: 80.2707 })).toBe(0)
  })

  it("matches the known ~111.19km for 1 degree of latitude at the equator", () => {
    const km = distanceKm({ lat: 0, lng: 0 }, { lat: 1, lng: 0 })
    expect(km).toBeCloseTo(111.1949, 3)
  })

  it("matches a quarter of Earth's circumference for 90 degrees of longitude on the equator", () => {
    const km = distanceKm({ lat: 0, lng: 0 }, { lat: 0, lng: 90 })
    expect(km).toBeCloseTo(10007.5434, 3)
  })

  it("matches a quarter of Earth's circumference from the equator to the pole", () => {
    const km = distanceKm({ lat: 0, lng: 0 }, { lat: 90, lng: 0 })
    expect(km).toBeCloseTo(10007.5434, 3)
  })

  it("matches a known city pair (Chennai to Bengaluru, ~290km straight-line)", () => {
    const km = distanceKm({ lat: 13.0827, lng: 80.2707 }, { lat: 12.9716, lng: 77.5946 })
    expect(km).toBeCloseTo(290.172, 2)
  })
})

describe("isInsideGeofence", () => {
  const center = { lat: 13.0827, lng: 80.2707 }
  // ~98.96m north of center (verified via distanceKm above)
  const nearbyPoint = { lat: 13.08359, lng: 80.2707 }

  it("is inside when the radius comfortably covers the distance", () => {
    expect(isInsideGeofence(nearbyPoint, center, 150)).toBe(true)
  })

  it("is outside when the radius is smaller than the distance", () => {
    expect(isInsideGeofence(nearbyPoint, center, 50)).toBe(false)
  })

  it("is inside at the exact boundary (radius === distance)", () => {
    expect(isInsideGeofence(center, center, 0)).toBe(true)
  })

  it("flips from outside to inside right at the ~98.96m boundary", () => {
    expect(isInsideGeofence(nearbyPoint, center, 98)).toBe(false)
    expect(isInsideGeofence(nearbyPoint, center, 99)).toBe(true)
  })
})

describe("expectedMinutes", () => {
  it("is 0 for 0 km", () => {
    expect(expectedMinutes(0, 5)).toBe(0)
  })

  it("applies the v2.2 '1km = 5min' default rate", () => {
    expect(expectedMinutes(5, 5)).toBe(25)
  })

  it("handles fractional km", () => {
    expect(expectedMinutes(2.5, 5)).toBe(12.5)
  })
})

describe("classifyGeoError", () => {
  it("classifies the unsupported-browser sentinel error", () => {
    expect(classifyGeoError(new Error("geolocation_unsupported"))).toBe("unsupported")
  })

  it("classifies GeolocationPositionError code 1 as permissionDenied", () => {
    expect(classifyGeoError({ code: 1 })).toBe("permissionDenied")
  })

  it("classifies GeolocationPositionError code 2 as unavailable", () => {
    expect(classifyGeoError({ code: 2 })).toBe("unavailable")
  })

  it("classifies GeolocationPositionError code 3 as timeout", () => {
    expect(classifyGeoError({ code: 3 })).toBe("timeout")
  })

  it("classifies anything else (unknown code, plain Error, undefined) as unknown", () => {
    expect(classifyGeoError({ code: 99 })).toBe("unknown")
    expect(classifyGeoError(new Error("some other error"))).toBe("unknown")
    expect(classifyGeoError(undefined)).toBe("unknown")
    expect(classifyGeoError(null)).toBe("unknown")
  })
})
