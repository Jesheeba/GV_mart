import { useTranslation } from "react-i18next"
import { Card } from "@/components/ui/card"

/**
 * Product Enquiry rebuild (2026-08-04), Phase 4 — purely illustrative,
 * client-side EMI display. `monthly = price / months`, no interest, no
 * lender integration anywhere. Tenure options + disclaimer text are
 * admin-configured (settings.emi_tenure_months/emi_disclaimer, Phase 2) —
 * this component only does the arithmetic and always shows the disclaimer
 * (non-dismissible), so it can't be mistaken for a real credit product.
 */
export function EmiEstimateCard({ price, tenureMonths, disclaimer }: { price: number; tenureMonths: number[]; disclaimer: string | null }) {
  const { t } = useTranslation()

  if (tenureMonths.length === 0) return null

  return (
    <Card className="gap-2 lg:px-5">
      <h2 className="px-1 text-sm font-semibold text-text">{t("customerApp.productEnquiry.detail.emiTitle")}</h2>
      <div className="flex flex-wrap gap-2 px-1">
        {tenureMonths.map((months) => (
          <div key={months} className="rounded-xl border border-border px-3 py-2 text-center">
            <p className="text-sm font-bold text-text">₹{Math.round(price / months).toLocaleString("en-IN")}</p>
            <p className="text-xs text-text-muted">{t("customerApp.productEnquiry.detail.emiPerMonth", { months })}</p>
          </div>
        ))}
      </div>
      <p className="px-1 text-xs text-text-muted">{disclaimer || t("customerApp.productEnquiry.detail.emiDisclaimer")}</p>
    </Card>
  )
}
