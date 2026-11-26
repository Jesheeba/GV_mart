import { useTranslation } from "react-i18next"
import { GstModeToggle } from "@/components/shared/GstModeToggle"
import { billBreakdown, formatCurrency, gstModeParts, type GstMode } from "@/lib/sale-calc"

/**
 * GST line + total for a single bill (gst-everywhere, 2026-11-26): technician
 * on-site invoice and AMC, rentals, admin Sell AMC, customer renewal. `net` is
 * the amount after any discount. Pass `onModeChange` to show the per-bill
 * switch; leave it out where the org default applies (customer app).
 * Same math as the server (public._gst_amount) via billBreakdown; "none" = rate 0.
 */
export function GstSummary({
  net,
  rate,
  mode,
  onModeChange,
  totalLabel,
}: {
  net: number
  rate: number
  mode: GstMode
  onModeChange?: (mode: GstMode) => void
  totalLabel?: string
}) {
  const { t } = useTranslation()
  const parts = gstModeParts(mode, rate)
  const bill = billBreakdown(net, 0, parts.rate, parts.gstInclusive)
  return (
    <div className="space-y-1 text-sm">
      {onModeChange ? <GstModeToggle value={mode} onChange={onModeChange} /> : null}
      {parts.noGst ? (
        <div className="flex justify-between">
          <span className="text-text-muted">{t("sales.gst.notCharged")}</span>
          <span className="text-text">{formatCurrency(0)}</span>
        </div>
      ) : rate > 0 ? (
        <div className="flex justify-between">
          <span className="text-text-muted">{t(parts.gstInclusive ? "sales.gst.includedLine" : "sales.summary.gst", { rate })}</span>
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
