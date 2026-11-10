export const CATEGORY_ORDER = ["service", "product", "spare", "amc"] as const

/** Active kind keys in the fixed chip display order, dropping any key with no matching active kind. */
export function orderedCategoryChips(activeKinds: { key: string }[]): string[] {
  const activeKeys = new Set(activeKinds.map((k) => k.key))
  return CATEGORY_ORDER.filter((key) => activeKeys.has(key))
}
