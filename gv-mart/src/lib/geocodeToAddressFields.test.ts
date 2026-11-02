import { describe, expect, it } from "vitest"
import { geocodeResultToAddressFields, mergeAddressFieldsPreservingTyped } from "./geocodeToAddressFields"
import type { GeocodeResult } from "@/services/maps"

function result(overrides: Partial<GeocodeResult> = {}): GeocodeResult {
  return {
    formatted: "",
    lat: 13.08,
    lon: 80.27,
    city: null,
    district: null,
    state: null,
    postcode: null,
    suburb: null,
    locationType: null,
    streetNumber: null,
    route: null,
    ...overrides,
  }
}

describe("geocodeResultToAddressFields", () => {
  it("maps a full result onto every field", () => {
    const fields = geocodeResultToAddressFields(
      result({ streetNumber: "12", route: "Anna Salai", suburb: "T Nagar", postcode: "600017", district: "Chennai", state: "Tamil Nadu" })
    )
    expect(fields).toEqual({
      doorNo: "12",
      streetCross: "Anna Salai",
      area: "T Nagar",
      pincode: "600017",
      district: "Chennai",
      state: "Tamil Nadu",
    })
  })

  it("falls back to city when suburb is absent", () => {
    const fields = geocodeResultToAddressFields(result({ city: "Chennai", suburb: null, postcode: "600001" }))
    expect(fields.area).toBe("Chennai")
    expect(fields.pincode).toBe("600001")
  })

  it("prefers suburb over city when both are present", () => {
    const fields = geocodeResultToAddressFields(result({ city: "Chennai", suburb: "Adyar" }))
    expect(fields.area).toBe("Adyar")
  })

  it("maps a partial result -- only the components Google actually returned", () => {
    const fields = geocodeResultToAddressFields(result({ postcode: "600017", state: "Tamil Nadu" }))
    expect(fields).toEqual({ pincode: "600017", state: "Tamil Nadu" })
  })

  it("maps an empty result to an empty patch -- never invents a value", () => {
    const fields = geocodeResultToAddressFields(result())
    expect(fields).toEqual({})
  })

  it("maps a non-India result (e.g. US: no administrative_area_level_2 district) by omitting district, not guessing it", () => {
    const fields = geocodeResultToAddressFields(
      result({ streetNumber: "1600", route: "Amphitheatre Parkway", city: "Mountain View", district: null, state: "California", postcode: "94043" })
    )
    expect(fields).toEqual({
      doorNo: "1600",
      streetCross: "Amphitheatre Parkway",
      area: "Mountain View",
      pincode: "94043",
      state: "California",
    })
    expect("district" in fields).toBe(false)
  })
})

describe("mergeAddressFieldsPreservingTyped", () => {
  it("fills every field when the current form is entirely empty", () => {
    const patch = mergeAddressFieldsPreservingTyped({}, { area: "Adyar", pincode: "600020" })
    expect(patch).toEqual({ area: "Adyar", pincode: "600020" })
  })

  it("never overwrites a field the customer has already typed", () => {
    const patch = mergeAddressFieldsPreservingTyped({ area: "My Typed Area" }, { area: "Adyar", pincode: "600020" })
    expect(patch).toEqual({ pincode: "600020" })
    expect(patch.area).toBeUndefined()
  })

  it("treats a whitespace-only current value as empty (fillable)", () => {
    const patch = mergeAddressFieldsPreservingTyped({ area: "   " }, { area: "Adyar" })
    expect(patch).toEqual({ area: "Adyar" })
  })

  it("returns an empty patch when every derived field is already filled", () => {
    const patch = mergeAddressFieldsPreservingTyped({ area: "Existing", pincode: "600001" }, { area: "Adyar", pincode: "600020" })
    expect(patch).toEqual({})
  })

  it("returns an empty patch for an empty derived result", () => {
    const patch = mergeAddressFieldsPreservingTyped({ area: "" }, {})
    expect(patch).toEqual({})
  })
})
