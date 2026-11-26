/** Trim and collapse inner whitespace — same normalisation the quick_add_* RPCs apply server-side, so client dedupe agrees with the DB. */
export function normalizeLabel(text: string): string {
  return text.trim().replace(/\s+/g, " ")
}

/**
 * The text a picker's "+ Add" option would create, or null when it
 * shouldn't be offered: nothing typed, over `maxLength`, or an existing
 * label already matches (case/space-insensitive — pick that one instead).
 */
export function quickAddText(typed: string, existingLabels: string[], maxLength = 120): string | null {
  const text = normalizeLabel(typed)
  if (!text || text.length > maxLength) return null
  const key = text.toLowerCase()
  return existingLabels.some((l) => normalizeLabel(l).toLowerCase() === key) ? null : text
}

/** First item whose label equals `text` ignoring case and extra spaces — lets a quick-add select an existing entry instead of creating a duplicate. */
export function findByLabel<T>(items: T[], getLabel: (item: T) => string, text: string): T | undefined {
  const key = normalizeLabel(text).toLowerCase()
  return items.find((i) => normalizeLabel(getLabel(i)).toLowerCase() === key)
}
