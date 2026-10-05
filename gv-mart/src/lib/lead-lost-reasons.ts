import type { TFunction } from "i18next"

/** Preset lost reasons. A preset is stored as its code (so reports can group
 * them regardless of UI language); "other" is stored as the typed free text. */
export const LOST_REASON_PRESETS = ["price_too_high", "chose_competitor", "no_longer_needs", "unresponsive", "duplicate", "wrong_number", "other"] as const
export type LostReasonPreset = (typeof LOST_REASON_PRESETS)[number]

export function isLostReasonPreset(value: string): value is LostReasonPreset {
  return (LOST_REASON_PRESETS as readonly string[]).includes(value) && value !== "other"
}

/** Display text for a stored lost reason: preset codes are translated, free text (and legacy translated text) shown as-is. */
export function lostReasonLabel(reason: string | null | undefined, t: TFunction): string {
  if (!reason) return ""
  return isLostReasonPreset(reason) ? t(`leads.lostReason.${reason}`) : reason
}
