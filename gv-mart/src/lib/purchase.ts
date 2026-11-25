// Pure helpers for the vendor (supplier → PO → receipt → bill → paid) screens.
// See build-docs/features/vendor-flow-fixes.md.

/** Same rule as the DB's _normalize_in_mobile: last 10 digits once there are at least 10. */
export function normalizeInMobile(value: string | null | undefined): string | null {
  const digits = (value ?? "").replace(/\D/g, "")
  return digits.length >= 10 ? digits.slice(-10) : null
}

/** POs a bill/receipt can be recorded against: sent (awaiting delivery), optionally for one supplier. */
export function receivablePurchaseOrders<T extends { status: string; supplier_id: string }>(pos: T[], supplierId: string): T[] {
  return pos.filter((p) => p.status === "sent" && (!supplierId || p.supplier_id === supplierId))
}

/** Payment is separate from delivery: a sent or received PO can be paid; a paid one can be undone. */
export function poPaymentActions(po: { status: string; paid_at: string | null }, isMaster: boolean) {
  return {
    canMarkPaid: isMaster && !po.paid_at && (po.status === "sent" || po.status === "received"),
    canUndoPaid: isMaster && !!po.paid_at,
  }
}

/** Units still missing on a PO line. 0 when the line was never received (PO not delivered yet). */
export function lineShortfall(item: { qty: number; received_qty: number | null }): number {
  return item.received_qty == null ? 0 : Math.max(0, item.qty - item.received_qty)
}

/** Maps a Postgres error code from a supplier write to a translation key, or null for "show as is". */
export function supplierWriteErrorKey(error: unknown): string | null {
  const code = typeof error === "object" && error !== null && "code" in error ? (error as { code: unknown }).code : null
  if (code === "23505") return "suppliers.duplicateLink"
  if (code === "23503") return "suppliers.cannotDelete"
  return null
}

/** True when at least one receipt line has a quantity above zero. */
export function hasReceivedQuantity(qtys: number[]): boolean {
  return qtys.some((q) => Number.isFinite(q) && q > 0)
}
