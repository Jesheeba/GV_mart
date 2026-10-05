import type { TFunction } from "i18next"
import type { LeadSourceRow } from "@/services/masters"

/** Stable key for a custom source: lowercase snake_case slug of its label. */
export function leadSourceKeyFromLabel(label: string): string {
  return label
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "")
}

/** Display label for a source key: built-ins use their translation (so Tamil
 * works), custom sources use the admin-entered master label. */
export function leadSourceLabel(key: string, sources: LeadSourceRow[] | undefined, t: TFunction): string {
  const row = sources?.find((s) => s.key === key)
  if (row && !row.is_system) return row.label
  return t(`leads.source.${key}`, { defaultValue: row?.label ?? key })
}
