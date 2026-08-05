import { useTranslation } from "react-i18next"
import { Card } from "@/components/ui/card"
import { Skeleton } from "@/components/ui/skeleton"
import { useSettings } from "@/hooks/useMasters"
import { billBreakdown, formatCurrency } from "@/lib/sale-calc"
import { amcSubtotal, payableTotal, productSubtotal, spareSubtotal, type SaleCartState } from "./types"

export function SaleSummaryPanel({
  orgId,
  cart,
  discountPercent,
  giftName,
  redeemAmount,
}: {
  orgId: string
  cart: SaleCartState
  discountPercent: number
  giftName?: string | null
  /** ₹ value of the referral points about to be redeemed (points * referral_point_value), for a live preview only — create_sale applies this against one designated invoice server-side, so this floor-at-zero preview can undercount by a rounding cent or two, never overcount. */
  redeemAmount?: number
}) {
  const { t } = useTranslation()
  const { data: settings, isLoading: settingsLoading, isError: settingsError } = useSettings(orgId)
  const gstRate = settings ? Number(settings.gst_rate) : 0

  const spareBill = spareSubtotal(cart) > 0 ? billBreakdown(spareSubtotal(cart), discountPercent, gstRate) : null
  const productBill = productSubtotal(cart) > 0 ? billBreakdown(productSubtotal(cart), discountPercent, gstRate) : null
  const amcBill = amcSubtotal(cart) > 0 ? billBreakdown(amcSubtotal(cart), discountPercent, gstRate) : null
  const grandTotal = (spareBill?.total ?? 0) + (productBill?.total ?? 0) + (amcBill?.total ?? 0)
  const redeemDiscount = Math.min(redeemAmount ?? 0, grandTotal)
  const payable = payableTotal(cart, discountPercent, gstRate, redeemAmount ?? 0)

  const bills = [
    { key: "product", label: t("sales.summary.productBill"), bill: productBill },
    { key: "spare", label: t("sales.summary.spareBill"), bill: spareBill },
    { key: "amc", label: t("sales.summary.amcBill"), bill: amcBill },
  ].filter((b) => b.bill)

  return (
    <Card className="sticky top-4 gap-3 px-5">
      <p className="px-1 text-sm font-semibold text-text">{t("sales.summary.title")}</p>
      {settingsLoading ? (
        <div className="space-y-2 px-1 py-1">
          <Skeleton className="h-4 w-full" />
          <Skeleton className="h-4 w-2/3" />
          <Skeleton className="h-4 w-1/2" />
        </div>
      ) : settingsError ? (
        <p className="px-1 text-sm text-danger">{t("common.error")}</p>
      ) : bills.length === 0 ? (
        <p className="px-1 text-sm text-text-muted">{t("sales.items.emptyCart")}</p>
      ) : (
        <>
          {bills.map(({ key, label, bill }) => (
            <div key={key} className="space-y-1 border-b border-border px-1 pb-2 last:border-0">
              <p className="text-xs font-medium text-text-muted">{label}</p>
              <div className="flex justify-between text-sm text-text">
                <span>{t("sales.summary.subtotal")}</span>
                <span>{formatCurrency(bill!.subtotal)}</span>
              </div>
              {bill!.discount > 0 ? (
                <div className="flex justify-between text-sm text-danger">
                  <span>{t("sales.summary.discount")}</span>
                  <span>−{formatCurrency(bill!.discount)}</span>
                </div>
              ) : null}
              <div className="flex justify-between text-sm text-text-muted">
                <span>{t("sales.summary.gst", { rate: gstRate })}</span>
                <span>{formatCurrency(bill!.gst)}</span>
              </div>
              <div className="flex justify-between text-sm font-semibold text-text">
                <span>{t("sales.summary.total")}</span>
                <span>{formatCurrency(bill!.total)}</span>
              </div>
            </div>
          ))}
          {bills.length > 1 ? (
            <div className="flex justify-between px-1 text-sm font-bold text-text" aria-live="polite" aria-atomic="true">
              <span>{t("sales.summary.grandTotal")}</span>
              <span>{formatCurrency(grandTotal)}</span>
            </div>
          ) : null}
          {bills.length > 1 ? <p className="px-1 text-xs text-info">{t("sales.summary.twoBillNotice")}</p> : null}
          {giftName ? <p className="px-1 text-xs text-success">{t("sales.summary.giftApplied", { gift: giftName })}</p> : null}
          {redeemDiscount > 0 ? (
            <>
              <div className="flex justify-between px-1 text-sm text-success">
                <span>{t("sales.summary.redeemDiscount")}</span>
                <span>−{formatCurrency(redeemDiscount)}</span>
              </div>
              <div className="flex justify-between px-1 text-sm font-bold text-text" aria-live="polite" aria-atomic="true">
                <span>{t("sales.summary.payable")}</span>
                <span>{formatCurrency(payable)}</span>
              </div>
            </>
          ) : null}
        </>
      )}
    </Card>
  )
}
