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
}

/** The street-level portion only (no area/pincode/district/state) — callers that already append those keep doing so. */
export function addressLocalityText(a: LegacyAddressFields | null | undefined): string {
  if (!a) return ""
  const full = a.full_address?.trim()
  if (full) return full
  return [a.door_no, a.plot_no, a.building_no, a.building_name, a.flat_no, a.street_cross, a.landmark].filter((v) => v?.trim()).join(", ")
}

/** Locality + Main Area in one line — for short subtitles/list rows that previously did `[door_no, area]`. */
export function addressLine(a: (LegacyAddressFields & { area?: string | null }) | null | undefined): string {
  if (!a) return ""
  return [addressLocalityText(a), a.area?.trim()].filter(Boolean).join(", ")
}
