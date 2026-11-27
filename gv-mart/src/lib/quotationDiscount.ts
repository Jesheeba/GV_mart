/**
 * Quotation ₹ discount (quotation-edit-discount, 2026-11-27). Mirrors the DB check
 * `_check_quotation_discount`: never negative, at most `maxPercent`% of the subtotal
 * (settings.discount_admin_max, the same cap a sale has), and a reason when > 0.
 * Returns an i18n key (with its params) for the first problem, or null.
 */
export type DiscountProblem = { key: string; params?: Record<string, string | number> } | null

const round2 = (n: number) => Math.round(n * 100) / 100

export function maxQuotationDiscount(subtotal: number, maxPercent: number): number {
  return round2((subtotal * maxPercent) / 100)
}

export function quotationDiscountProblem(subtotal: number, discount: number, reason: string, maxPercent: number): DiscountProblem {
  if (!Number.isFinite(discount) || discount < 0) return { key: "quotations.discount.errorNegative" }
  const max = maxQuotationDiscount(subtotal, maxPercent)
  if (discount > max) return { key: "quotations.discount.errorOverCap", params: { percent: maxPercent, max } }
  if (discount > 0 && !reason.trim()) return { key: "quotations.discount.errorReason" }
  return null
}

/** Percent the sale's discount step needs to reproduce a ₹ amount (2 decimals, like the sale's own ₹ input). */
export function discountPercentOf(subtotal: number, discount: number): number {
  return subtotal > 0 ? round2((discount / subtotal) * 100) : 0
}
