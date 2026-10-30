import { describe, expect, it } from "vitest"
import { googleMapsPinUrl, isValidCoordPair, isValidLat, isValidLng } from "./googleMapsLink"

describe("googleMapsPinUrl", () => {
  it("builds a directions link with the destination coordinates", () => {
    expect(googleMapsPinUrl(13.0827, 80.2707)).toBe("https://www.google.com/maps/dir/?api=1&destination=13.0827%2C80.2707")
  })
})

describe("isValidLat", () => {
  it("accepts the full -90..90 range", () => {
    expect(isValidLat(-90)).toBe(true)
    expect(isValidLat(90)).toBe(true)
    expect(isValidLat(0)).toBe(true)
  })
  it("rejects out-of-range and non-finite values", () => {
    expect(isValidLat(-90.0001)).toBe(false)
    expect(isValidLat(90.0001)).toBe(false)
    expect(isValidLat(NaN)).toBe(false)
  })
})

describe("isValidLng", () => {
  it("accepts the full -180..180 range", () => {
    expect(isValidLng(-180)).toBe(true)
    expect(isValidLng(180)).toBe(true)
  })
  it("rejects out-of-range values", () => {
    expect(isValidLng(-180.0001)).toBe(false)
    expect(isValidLng(180.0001)).toBe(false)
  })
})

describe("isValidCoordPair", () => {
  it("requires both lat and lng to be present and valid", () => {
    expect(isValidCoordPair(13.08, 80.27)).toBe(true)
    expect(isValidCoordPair(null, 80.27)).toBe(false)
    expect(isValidCoordPair(13.08, null)).toBe(false)
    expect(isValidCoordPair(null, null)).toBe(false)
    expect(isValidCoordPair(undefined, undefined)).toBe(false)
  })
  it("rejects a pair where one value is out of range", () => {
    expect(isValidCoordPair(100, 80.27)).toBe(false)
    expect(isValidCoordPair(13.08, 200)).toBe(false)
  })
})
