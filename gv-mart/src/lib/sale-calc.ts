/** Mirrors the arithmetic in supabase/migrations/20260702100100_sales_phase5_functions.sql exactly — this is a client-side preview only, the RPC recomputes authoritatively from master prices. */
export function round2(n: number) {
  return Math.round((n + Number.EPSILON) * 100) / 100
}

/**
 * Per-bill GST choice (no-gst-bill, 2026-11-26): "none" bills GST 0, the same as the server, which uses rate 0
 * (20270101100000_no_gst_bill.sql). Never the default: the org setting picks extra or included.
 */
export type GstMode = "extra" | "included" | "none"
export const defaultGstMode = (pricesIncludeGst: boolean | null | undefined): GstMode => (pricesIncludeGst ? "included" : "extra")
/** What the RPCs take, plus the rate to preview with. */
export function gstModeParts(mode: GstMode, rate: number) {
  return { gstInclusive: mode === "included", noGst: mode === "none", rate: mode === "none" ? 0 : rate }
}
/** Restores a saved choice: drafts made before no-gst-bill stored a boolean (true = included). */
export function toGstMode(saved: unknown): GstMode | null {
  if (saved === "extra" || saved === "included" || saved === "none") return saved
  if (typeof saved === "boolean") return saved ? "included" : "extra"
  return null
}

/**
 * `gstInclusive` (2026-11-26): prices already include GST, so GST is the
 * share inside the discounted amount and the total doesn't grow. Mirrors
 * public._gst_amount in 20261226110000_gst_inclusive_toggle.sql.
 */
export function billBreakdown(subtotal: number, discountPercent: number, gstRatePercent: number, gstInclusive = false) {
  const discount = round2((subtotal * discountPercent) / 100)
  const net = subtotal - discount
  const gst = gstRatePercent <= 0 ? 0 : round2(gstInclusive ? (net * gstRatePercent) / (100 + gstRatePercent) : (net * gstRatePercent) / 100)
  const total = round2(gstInclusive ? net : net + gst)
  return { subtotal: round2(subtotal), discount, gst, total }
}

export function formatCurrency(n: number) {
  return `₹${n.toLocaleString("en-IN", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
}

/**
 * create_sale's stock check (_sale_create_line_invoice) is a single
 * `UPDATE ... WHERE stock_qty >= qty RETURNING ...`, so "no inventory row
 * exists at all" and "a row exists but qty is too low" both come back as
 * the same generic "insufficient stock" exception -- the two cases need
 * very different instructions for a cashier (add a stock record vs. just
 * sell fewer units), so NewSalePage checks this client-side, before
 * submitting, against the same read-only inventory list the stock hints
 * already use. Pure/no I/O so it's testable without rendering the page.
 */
export type StockGap =
  | { kind: "no_record"; name: string }
  | { kind: "insufficient"; name: string; available: number }

export function findStockGap(
  lines: Array<{ itemId: string; name: string; qty: number }>,
  stock: Array<{ item_id: string; stock_qty: number }> | undefined
): StockGap | null {
  for (const line of lines) {
    const row = (stock ?? []).find((r) => r.item_id === line.itemId)
    if (!row) return { kind: "no_record", name: line.name }
    if (row.stock_qty < line.qty) return { kind: "insufficient", name: line.name, available: row.stock_qty }
  }
  return null
}

/**
 * The discount % a sale sends to create_sale (exact-rupee-discount, 2026-11-27). Typed in ₹ → the exact,
 * unrounded % so the bill's discount equals the ₹ typed (a 2-decimal % could land up to ~₹1 off). Typed in % →
 * that %. Off → 0.
 */
export function saleDiscountPercent(input: { enabled: boolean; byAmount: boolean; percentInput: string; amountInput: string; subtotal: number }): number {
  if (!input.enabled) return 0
  if (!input.byAmount) return Math.max(0, Number(input.percentInput) || 0)
  const amount = Math.max(0, Number(input.amountInput) || 0)
  // 8 decimals: drops float noise (10.000000000000002 → 10) that would trip the cap check; error < ₹0.0001.
  return input.subtotal > 0 ? Math.round((amount / input.subtotal) * 100 * 1e8) / 1e8 : 0
}
