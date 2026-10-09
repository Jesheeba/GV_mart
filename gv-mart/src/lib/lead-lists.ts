import type { TFunction } from "i18next"
import type { LeadKindRow, LeadProductTypeRow } from "@/services/masters"

type ListRow = Pick<LeadKindRow, "key" | "label" | "label_ta" | "is_system">

function customLabel(row: ListRow, lang: string): string {
  return lang.startsWith("ta") && row.label_ta ? row.label_ta : row.label
}

/**
 * Display label for a lead kind key. Built-in kinds use their translation
 * (so Tamil always works); custom kinds (e.g. Warranty) use the master's
 * label, with the optional Tamil label on the Tamil UI. A key that is no
 * longer in the list (deleted/other org) falls back to the raw key.
 */
export function leadKindLabel(key: string, rows: LeadKindRow[] | undefined, t: TFunction, lang: string): string {
  const row = rows?.find((r) => r.key === key)
  if (row && !row.is_system) return customLabel(row, lang)
  return t(`leads.kind.${key}`, { defaultValue: row?.label ?? key })
}

/** Same as {@link leadKindLabel} for product types; built-ins reuse the existing category translations. */
export function leadProductTypeLabel(key: string, rows: LeadProductTypeRow[] | undefined, t: TFunction, lang: string): string {
  const row = rows?.find((r) => r.key === key)
  if (row && !row.is_system) return customLabel(row, lang)
  return t(`masters.categories.${key}`, { defaultValue: row?.label ?? key })
}
