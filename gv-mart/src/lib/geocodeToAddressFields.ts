import type { GeocodeResult } from "@/services/maps"

/** The subset of AddressForm's text fields a geocode result can confidently fill. */
export type AddressTextFields = {
  fullAddress?: string
  area?: string
  pincode?: string
  district?: string
  state?: string
}

/**
 * "Use my current location" -> address text. Maps a reverse-geocode result onto
 * the subset of AddressForm's fields it can confidently fill. Never invents a
 * value: a component Google didn't return (common outside India, or for rural
 * addresses) is simply omitted, not set to "" or guessed.
 *
 * fullAddress (2026-11-03, Full Address redesign): street number and route are
 * the only components precise enough to belong in the free-text locality box —
 * area/district/state stay their own structured fields (see src/lib/address.ts
 * for why `area` in particular can never be folded into free text). Joined with
 * a space to match how Google already formats them ("12 Main Street"); either
 * one alone is used as-is, and if neither is present fullAddress is simply
 * omitted, same never-invent-a-value policy as every other field here.
 */
export function geocodeResultToAddressFields(result: GeocodeResult): AddressTextFields {
  const fields: AddressTextFields = {}
  const fullAddress = [result.streetNumber, result.route].filter(Boolean).join(" ")
  if (fullAddress) fields.fullAddress = fullAddress
  const area = result.suburb ?? result.city
  if (area) fields.area = area
  if (result.postcode) fields.pincode = result.postcode
  if (result.district) fields.district = result.district
  if (result.state) fields.state = result.state
  return fields
}

/**
 * Merges derived fields onto the customer's current form values without ever
 * overwriting text they have already typed -- only currently empty fields get
 * filled. Returns just the patch to apply (never the full merged object), so a
 * caller can tell at a glance whether there is anything to apply at all.
 */
export function mergeAddressFieldsPreservingTyped(
  current: AddressTextFields,
  derived: AddressTextFields
): AddressTextFields {
  const patch: AddressTextFields = {}
  for (const key of Object.keys(derived) as (keyof AddressTextFields)[]) {
    const currentValue = current[key]
    if (currentValue == null || currentValue.trim() === "") {
      patch[key] = derived[key]
    }
  }
  return patch
}
