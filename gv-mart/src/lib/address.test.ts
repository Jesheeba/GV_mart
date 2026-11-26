import { describe, expect, it } from "vitest"
import { addressLine, addressLocalityText, composeFullAddress, hasStreetLevelFields, pinStatus, resolveFullAddress, splitAddressForForm } from "./address"

describe("composeFullAddress", () => {
  it("joins all structured fields in order, skipping blanks", () => {
    expect(
      composeFullAddress({
        doorNo: "12A",
        plotNo: "7",
        buildingName: "Sri Towers",
        streetCross: "4th Cross",
        subArea: "Gandhi Nagar",
        area: "Anna Nagar",
        landmark: "Near temple",
      })
    ).toBe("12A, 7, Sri Towers, 4th Cross, Gandhi Nagar, Anna Nagar, Near temple")
  })

  it("skips blank, null and undefined fields without leaving empty gaps", () => {
    expect(
      composeFullAddress({
        doorNo: "12A",
        plotNo: "",
        buildingName: null,
        streetCross: undefined,
        subArea: "  ",
        area: "Anna Nagar",
        landmark: undefined,
      })
    ).toBe("12A, Anna Nagar")
  })

  it("returns an empty string when every field is blank", () => {
    expect(composeFullAddress({})).toBe("")
  })

  it("trims whitespace around each field", () => {
    expect(composeFullAddress({ doorNo: "  12A  ", area: "  Anna Nagar  " })).toBe("12A, Anna Nagar")
  })
})

describe("addressLocalityText / addressLine", () => {
  // Regression: full_address saved via composeFullAddress bakes `area` into the
  // joined text (e.g. "2/22E, Kamaraja Nagar, Oil Mill" with area = "Oil Mill").
  // Every caller that does `[addressLocalityText(a), a.area].join(", ")` must not
  // show "Oil Mill" twice.
  it("does not duplicate area when full_address already bakes it in", () => {
    const addr = { full_address: "2/22E, Kamaraja Nagar, Oil Mill", area: "Oil Mill" }
    expect(addressLocalityText(addr)).toBe("2/22E, Kamaraja Nagar")
    expect(addressLine(addr)).toBe("2/22E, Kamaraja Nagar, Oil Mill")
  })

  it("still appends area for a legacy full_address that never included it", () => {
    const addr = { full_address: "No. 5, Old Street, near bus stop", area: "Anna Nagar" }
    expect(addressLocalityText(addr)).toBe("No. 5, Old Street, near bus stop")
    expect(addressLine(addr)).toBe("No. 5, Old Street, near bus stop, Anna Nagar")
  })
})

describe("splitAddressForForm", () => {
  it("prefers structured columns when any are populated", () => {
    const result = splitAddressForForm({
      door_no: "12A",
      plot_no: null,
      building_name: null,
      street_cross: null,
      landmark: null,
      area: null,
      full_address: "12A, Old Free Text Address",
    })
    expect(result.hasStructuredFields).toBe(true)
    expect(result.doorNo).toBe("12A")
    expect(result.legacyFullAddress).toBe("")
  })

  it("falls back to full_address when every structured column is empty", () => {
    const result = splitAddressForForm({
      door_no: null,
      plot_no: null,
      building_name: null,
      street_cross: null,
      landmark: null,
      area: null,
      full_address: "No. 5, Old Street, near bus stop",
    })
    expect(result.hasStructuredFields).toBe(false)
    expect(result.legacyFullAddress).toBe("No. 5, Old Street, near bus stop")
    expect(result.doorNo).toBe("")
  })

  it("returns all-blank fields for a customer with no address data at all", () => {
    const result = splitAddressForForm(null)
    expect(result.hasStructuredFields).toBe(false)
    expect(result.legacyFullAddress).toBe("")
    expect(result.doorNo).toBe("")
    expect(result.area).toBe("")
  })

  // Replaced 2026-11-26 (sweep item 2). The old test asserted that an area-only row's full_address is "stale text
  // that should be ignored". But the customer app's address box writes exactly that shape (area + full_address, no
  // street-level parts), so the admin form threw away the customer's address and Save rebuilt it from the bare area.
  it("an area-only row whose full_address says more (customer app / legacy) shows that text in the fallback box", () => {
    const result = splitAddressForForm({
      door_no: null,
      plot_no: null,
      building_name: null,
      street_cross: null,
      landmark: null,
      area: "Anna Nagar",
      full_address: "45, New Street, Anna Nagar",
    })
    expect(result.hasStructuredFields).toBe(false)
    expect(result.area).toBe("Anna Nagar")
    expect(result.legacyFullAddress).toBe("45, New Street, Anna Nagar")
  })

  it("an area-only row composed by this form (full_address = the area) needs no fallback box", () => {
    const result = splitAddressForForm({ area: "Anna Nagar", full_address: "Anna Nagar" })
    expect(result.hasStructuredFields).toBe(false)
    expect(result.legacyFullAddress).toBe("")
    expect(result.area).toBe("Anna Nagar")
  })

  it("round-trips sub_area once its column exists", () => {
    const result = splitAddressForForm({
      door_no: null,
      plot_no: null,
      building_name: null,
      street_cross: null,
      landmark: null,
      area: null,
      sub_area: "Gandhi Nagar",
      full_address: "stale text that should be ignored",
    })
    expect(result.hasStructuredFields).toBe(true)
    expect(result.subArea).toBe("Gandhi Nagar")
    expect(result.legacyFullAddress).toBe("")
  })

  it("partially-populated columns (some filled, some blank) never fall back to full_address text, and preserve every filled column", () => {
    // Regression guard: a customer edited once under the structured-fields
    // form, then edited again, could end up with only SOME of the six
    // columns filled (e.g. doorNo and landmark saved, plotNo/buildingName/
    // streetCross/subArea/area never typed). The fallback must trigger only
    // when ALL six are blank -- never "most are blank" -- or the already-
    // saved doorNo/landmark text would be silently replaced by the stale
    // full_address box and be unrecoverable once the form re-saves.
    const result = splitAddressForForm({
      door_no: "12A",
      plot_no: null,
      building_name: null,
      street_cross: null,
      sub_area: null,
      landmark: "Near the water tank",
      area: null,
      full_address: "stale text that must NOT be shown or used",
    })
    expect(result.hasStructuredFields).toBe(true)
    expect(result.doorNo).toBe("12A")
    expect(result.landmark).toBe("Near the water tank")
    expect(result.plotNo).toBe("")
    expect(result.buildingName).toBe("")
    expect(result.streetCross).toBe("")
    expect(result.subArea).toBe("")
    expect(result.area).toBe("")
    expect(result.legacyFullAddress).toBe("")
  })

  it("treats whitespace-only legacy columns as blank (not a reason to skip the fallback)", () => {
    const result = splitAddressForForm({
      door_no: "   ",
      plot_no: "",
      building_name: null,
      street_cross: undefined,
      sub_area: null,
      landmark: null,
      area: null,
      full_address: "No. 5, Old Street, near bus stop",
    })
    expect(result.hasStructuredFields).toBe(false)
    expect(result.legacyFullAddress).toBe("No. 5, Old Street, near bus stop")
  })
})

describe("resolveFullAddress (what the admin address step saves)", () => {
  it("any street-level part filled: composed from the structured fields, the free-text box is ignored", () => {
    expect(resolveFullAddress({ doorNo: "12A", area: "Anna Nagar", fullAddress: "old text" })).toBe("12A, Anna Nagar")
  })
  it("no street-level part: the free-text box is kept (customer-app edit survives an admin save)", () => {
    expect(resolveFullAddress({ area: "Anna Nagar", fullAddress: " 45, New Street, Anna Nagar " })).toBe("45, New Street, Anna Nagar")
  })
  it("no street-level part and an empty box: falls back to the area alone", () => {
    expect(resolveFullAddress({ area: "Anna Nagar", fullAddress: "" })).toBe("Anna Nagar")
    expect(resolveFullAddress({})).toBe("")
  })
  it("hasStreetLevelFields ignores Main Area and whitespace", () => {
    expect(hasStreetLevelFields({ area: "Anna Nagar" })).toBe(false)
    expect(hasStreetLevelFields({ landmark: "   " })).toBe(false)
    expect(hasStreetLevelFields({ subArea: "Block C" })).toBe(true)
  })
  it("round trip: an app-written address loaded into the form and saved unchanged keeps its text", () => {
    const row = { area: "Anna Nagar", full_address: "45, New Street, Anna Nagar" }
    const split = splitAddressForForm(row)
    expect(resolveFullAddress({ ...split, fullAddress: split.legacyFullAddress })).toBe(row.full_address)
  })
  it("round trip: a structured row saved unchanged keeps the same composed text", () => {
    const row = { door_no: "12A", street_cross: "2nd Cross", area: "Anna Nagar", full_address: "12A, 2nd Cross, Anna Nagar" }
    const split = splitAddressForForm(row)
    expect(resolveFullAddress({ ...split, fullAddress: split.legacyFullAddress })).toBe(row.full_address)
  })
})

// pin-autocorrect: customer-page pin chip
describe("pinStatus", () => {
  const addr = { lat: 10.81, lng: 78.7, location_verified_at: null }
  it("no pin -> notPinned", () => expect(pinStatus({ lat: null, lng: null }, null)).toBe("notPinned"))
  it("locked -> verified, even with a correction event", () =>
    expect(pinStatus({ ...addr, location_verified_at: "2026-11-26T10:00:00Z" }, { event: "corrected", new_lat: 10.81, new_lng: 78.7 })).toBe("verified"))
  it("latest event is a correction at the current pin -> corrected", () =>
    expect(pinStatus(addr, { event: "corrected", new_lat: 10.8100004, new_lng: 78.7000003 })).toBe("corrected"))
  it("office moved the pin after the correction -> pinned", () =>
    expect(pinStatus(addr, { event: "corrected", new_lat: 10.9, new_lng: 78.7 })).toBe("pinned"))
  it("latest event is a reset -> pinned", () => expect(pinStatus(addr, { event: "reset", new_lat: null, new_lng: null })).toBe("pinned"))
  it("no events -> pinned", () => expect(pinStatus(addr, undefined)).toBe("pinned"))
})
