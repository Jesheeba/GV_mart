/**
 * Shared address display formatting (migration 20261103090000). The
 * "street-level" part of an address used to be split across door_no,
 * building_no, building_name, plot_no, street_cross, landmark, flat_no —
 * every display site built its own ad-hoc join of some subset of them. Those
 * columns are now deprecated in favour of one free-text full_address field,
 * but are kept (not dropped) so pre-existing rows still show something.
 * This is the one place that decides which to use, so every consumer agrees.
 */

type LegacyAddressFields = {
  full_address?: string | null
  door_no?: string | null
  building_no?: string | null
  building_name?: string | null
  plot_no?: string | null
  street_cross?: string | null
  landmark?: string | null
  flat_no?: string | null
  area?: string | null
}

/**
 * The street-level portion only (no area/pincode/district/state) — callers that already append `a.area` keep doing so.
 * `full_address` saved via composeFullAddress bakes `area` in as one of its comma-joined tokens (see below), so that
 * token is stripped back out here to honour this contract — otherwise every one of those callers would show the area
 * twice (once from here, once from their own appended `a.area`).
 */
export function addressLocalityText(a: LegacyAddressFields | null | undefined): string {
  if (!a) return ""
  const full = a.full_address?.trim()
  if (full) {
    const area = a.area?.trim()
    if (!area) return full
    return full
      .split(", ")
      .filter((part) => part !== area)
      .join(", ")
  }
  return [a.door_no, a.plot_no, a.building_no, a.building_name, a.flat_no, a.street_cross, a.landmark].filter((v) => v?.trim()).join(", ")
}

/** Locality + Main Area in one line — for short subtitles/list rows that previously did `[door_no, area]`. */
export function addressLine(a: (LegacyAddressFields & { area?: string | null }) | null | undefined): string {
  if (!a) return ""
  return [addressLocalityText(a), a.area?.trim()].filter(Boolean).join(", ")
}

/**
 * Clean-address-form redesign (2026-11-03): replaces the single free-text
 * "Full address" box with the separate fields the owner asked for (Door no,
 * Plot no, Building Name, Street/Cross, Sub Area, Main Area, Landmark — PIN
 * Code/District/State/Zone already have their own columns/inputs and aren't
 * part of this join). `full_address` stays the canonical composed text —
 * search, printing and the invoice all read it — so this is the one place
 * that builds it from the structured fields, same spirit as
 * addressLocalityText above being the one place that reads them back.
 *
 * `subArea` round-trips through `addresses.sub_area` (migration
 * 20261204170000_address_sub_area_field.sql) the same way the other
 * structured fields do — see splitAddressForForm below.
 */
export type StructuredAddressFields = {
  doorNo?: string | null
  plotNo?: string | null
  buildingName?: string | null
  streetCross?: string | null
  subArea?: string | null
  area?: string | null
  landmark?: string | null
}

/** Joins the structured fields into one line, in display order, skipping blanks. */
export function composeFullAddress(fields: StructuredAddressFields): string {
  return [fields.doorNo, fields.plotNo, fields.buildingName, fields.streetCross, fields.subArea, fields.area, fields.landmark]
    .map((v) => v?.trim())
    .filter((v): v is string => !!v)
    .join(", ")
}

/**
 * Decides what the address step should show: structured fields loaded from
 * their own columns when any are present, or — for a customer saved before
 * this change, whose columns are all empty — the old free-text full_address
 * in a clearly labelled fallback field instead. Never both, so there's no
 * ambiguity about which one Save will treat as the source of truth.
 */
export function splitAddressForForm(
  row:
    | (LegacyAddressFields & {
        plot_no?: string | null
        building_name?: string | null
        area?: string | null
        sub_area?: string | null
      })
    | null
    | undefined
): {
  doorNo: string
  plotNo: string
  buildingName: string
  streetCross: string
  subArea: string
  landmark: string
  area: string
  hasStructuredFields: boolean
  legacyFullAddress: string
} {
  const doorNo = row?.door_no?.trim() ?? ""
  const plotNo = row?.plot_no?.trim() ?? ""
  const buildingName = row?.building_name?.trim() ?? ""
  const streetCross = row?.street_cross?.trim() ?? ""
  const subArea = row?.sub_area?.trim() ?? ""
  const landmark = row?.landmark?.trim() ?? ""
  const area = row?.area?.trim() ?? ""
  // ANY structured field populated wins over the legacy fallback — never
  // just the first one checked, and never "most are blank so fall back".
  // Bug this guards against: editing a customer who has e.g. only
  // door_no + landmark saved (some columns populated, others still blank)
  // must show those two values, not silently swap in the old full_address
  // text and leave them unrecoverable once Save re-composes from the form.
  const hasStructuredFields = [doorNo, plotNo, buildingName, streetCross, subArea, landmark, area].some(Boolean)
  return {
    doorNo,
    plotNo,
    buildingName,
    streetCross,
    subArea,
    landmark,
    area,
    hasStructuredFields,
    legacyFullAddress: hasStructuredFields ? "" : (row?.full_address?.trim() ?? ""),
  }
}
