import type { GeocodeResult } from "@/services/maps"

/** The subset of AddressForm's text fields a geocode result can confidently fill. */
export type AddressTextFields = {
  doorNo?: string
  streetCross?: string
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
 */
export function geocodeResultToAddressFields(result: GeocodeResult): AddressTextFields {
  const fields: AddressTextFields = {}
  if (result.streetNumber) fields.doorNo = result.streetNumber
  if (result.route) fields.streetCross = result.route
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
