/** Mirrors the arithmetic in supabase/migrations/20260702100100_sales_phase5_functions.sql exactly — this is a client-side preview only, the RPC recomputes authoritatively from master prices. */
export function round2(n: number) {
  return Math.round((n + Number.EPSILON) * 100) / 100
}

export function billBreakdown(subtotal: number, discountPercent: number, gstRatePercent: number) {
  const discount = round2((subtotal * discountPercent) / 100)
  const gst = round2(((subtotal - discount) * gstRatePercent) / 100)
  const total = round2(subtotal - discount + gst)
  return { subtotal: round2(subtotal), discount, gst, total }
}

export function formatCurrency(n: number) {
  return `₹${n.toLocaleString("en-IN", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
}
