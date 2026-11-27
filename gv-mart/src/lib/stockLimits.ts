/**
 * Min/max warehouse stock typed on the Spare form (spare-stock-limits, 2026-11-27). Min = when stock falls to it
 * the auto purchase order drafts a PO; max = the level that PO refills to (inventory.min_stock / max_stock).
 * Both empty → leave the stock row alone. One without the other, negatives, decimals or max < min → an i18n error key.
 */
export type StockLimits = { kind: "none" } | { kind: "set"; min: number; max: number } | { kind: "error"; key: string }

export function parseStockLimits(minRaw: string, maxRaw: string): StockLimits {
  const minS = minRaw.trim()
  const maxS = maxRaw.trim()
  if (!minS && !maxS) return { kind: "none" }
  if (!minS || !maxS) return { kind: "error", key: "masters.spares.stockLimitsBoth" }
  const min = Number(minS)
  const max = Number(maxS)
  if (!Number.isInteger(min) || !Number.isInteger(max) || min < 0 || max < 0) return { kind: "error", key: "masters.spares.stockLimitsWhole" }
  if (max < min) return { kind: "error", key: "masters.spares.stockLimitsOrder" }
  return { kind: "set", min, max }
}
