import { useTranslation } from "react-i18next"
import { GstModeToggle } from "@/components/shared/GstModeToggle"
import { billBreakdown, formatCurrency } from "@/lib/sale-calc"

/**
 * GST line + total for a single bill (gst-everywhere, 2026-11-26): technician
 * on-site invoice and AMC, rentals, admin Sell AMC, customer renewal. `net` is
 * the amount after any discount. Pass `onInclusiveChange` to show the per-bill
 * switch; leave it out where the org default applies (customer app).
 * Same math as the server (public._gst_amount) via billBreakdown.
 */
export function GstSummary({
  net,
  rate,
  inclusive,
  onInclusiveChange,
  totalLabel,
}: {
  net: number
  rate: number
  inclusive: boolean
  onInclusiveChange?: (inclusive: boolean) => void
  totalLabel?: string
}) {
  const { t } = useTranslation()
  const bill = billBreakdown(net, 0, rate, inclusive)
  return (
    <div className="space-y-1 text-sm">
      {onInclusiveChange ? <GstModeToggle value={inclusive} onChange={onInclusiveChange} /> : null}
      {rate > 0 ? (
        <div className="flex justify-between">
          <span className="text-text-muted">{t(inclusive ? "sales.gst.includedLine" : "sales.summary.gst", { rate })}</span>
          <span className="text-text">{formatCurrency(bill.gst)}</span>
        </div>
      ) : null}
      <div className="flex justify-between font-semibold">
        <span className="text-text">{totalLabel ?? t("sales.summary.total")}</span>
        <span className="text-text">{formatCurrency(bill.total)}</span>
      </div>
    </div>
  )
}
