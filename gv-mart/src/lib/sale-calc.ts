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
