import { Package } from "lucide-react"
import { useTranslation } from "react-i18next"
import { Dialog, DialogContent, DialogTitle } from "@/components/ui/dialog"
import { Badge } from "@/components/ui/badge"
import { StatusDot } from "@/components/shared/StatusDot"
import { useProductImages } from "@/hooks/useMasters"
import { productImagePublicUrl } from "@/services/productMedia"
import { formatCurrency } from "@/lib/sale-calc"
import { cn } from "@/lib/utils"
import type { CustomerMeasuredWaterReading, CustomerTdsSuggestion, TdsBand } from "@/services/waterQuality"

const BAND_TONE: Record<TdsBand, "success" | "warning" | "danger"> = { low: "success", medium: "warning", high: "danger" }

/**
 * One row per product mapped to the matched band (product_tds_recommendations,
 * sort_order ascending — see getCustomerTdsSuggestion) — small square thumbnail,
 * same fallback contract as CustomerCatalogGrid.tsx's list rows (not the big
 * single-product hero from ProductPhotoHero, which doesn't fit a multi-item list).
 */
function ProductRow({ product, isPrimary }: { product: { id: string; name: string; price: number }; isPrimary: boolean }) {
  const { t } = useTranslation()
  const images = useProductImages(product.id)
  const primaryImage = (images.data ?? []).find((img) => img.is_primary) ?? images.data?.[0]

  return (
    <div className="flex items-center gap-3">
      {primaryImage ? (
        <img src={productImagePublicUrl(primaryImage.storage_path)} alt={product.name} className="size-16 shrink-0 rounded-subcard object-cover" />
      ) : (
        <div className="flex size-16 shrink-0 items-center justify-center rounded-subcard bg-surface-alt text-text-muted">
          <Package className="size-6" />
        </div>
      )}
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-1.5">
          <span className="truncate text-sm font-bold text-text">{product.name}</span>
          {isPrimary ? <Badge variant="success">{t("customers.detail.tdsDialog.primary")}</Badge> : null}
        </div>
        <div className="text-sm font-medium text-text-muted">{formatCurrency(product.price)}</div>
      </div>
    </div>
  )
}

/**
 * Opened from the customer profile's "Next best action" panel — the one-line
 * suggestion row only names the primary product (+N more), so this expands
 * to every product mapped to the matched band (primary first — product_tds_
 * recommendations.sort_order), plus the full TDS picture (range, source,
 * year, proxy caveat) shared once at the bottom rather than repeated per
 * product, since it's the same regional estimate for all of them.
 *
 * Shows both the "Measured" on-site reading (a technician's real ro_checklists
 * water_* entry from a service visit, when one exists) and the "Estimated"
 * regional district figure together — by design, one never replaces the
 * other, since the district estimate still matters for customers without a
 * visit yet. Either prop may be null; both null means no dialog is opened.
 */
export function TdsSuggestionDialog({
  tds,
  measured,
  open,
  onClose,
}: {
  tds: CustomerTdsSuggestion | null
  measured: CustomerMeasuredWaterReading | null
  open: boolean
  onClose: () => void
}) {
  const { t } = useTranslation()

  return (
    <Dialog open={open} onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-sm">
        <DialogTitle>{t("customers.detail.tdsDialog.title")}</DialogTitle>

        {tds && tds.products.length > 0 ? (
          <div className={cn("flex flex-col gap-3.5", tds.products.length > 1 && "divide-y divide-border [&>*+*]:pt-3.5")}>
            {tds.products.map((product, i) => (
              <ProductRow key={product.id} product={product} isPrimary={i === 0} />
            ))}
          </div>
        ) : null}

        {measured ? (
          <div className="flex flex-col gap-2 rounded-xl border border-border bg-surface-alt p-3.5">
            <span className="text-xs font-semibold uppercase tracking-wide text-text-muted">{t("customers.detail.tdsDialog.measuredHeading")}</span>
            {measured.tdsPpm != null ? <div className="text-sm text-text">{t("customers.detail.tdsDialog.measuredTds", { ppm: measured.tdsPpm })}</div> : null}
            {measured.ph != null ? <div className="text-sm text-text">{t("customers.detail.tdsDialog.measuredPh", { ph: measured.ph })}</div> : null}
            {measured.hardnessPpm != null ? (
              <div className="text-sm text-text">{t("customers.detail.tdsDialog.measuredHardness", { ppm: measured.hardnessPpm })}</div>
            ) : null}
            {measured.source ? (
              <div className="text-xs text-text-muted">
                {t("customers.detail.tdsDialog.measuredSource", {
                  source: measured.source === "other" ? measured.sourceOther || t("masters.waterQuality.source.other") : t(`masters.waterQuality.source.${measured.source}`),
                })}
              </div>
            ) : null}
            <div className="text-xs text-text-muted">
              {t("customers.detail.tdsDialog.measuredOn", { date: new Date(measured.measuredAt).toLocaleDateString("en-IN", { day: "2-digit", month: "short", year: "numeric" }) })}
            </div>
          </div>
        ) : null}

        {tds ? (
          <div className="flex flex-col gap-2 rounded-xl border border-border bg-surface-alt p-3.5">
            <div className="flex items-center justify-between">
              <span className="text-xs font-semibold uppercase tracking-wide text-text-muted">{t("customers.detail.tdsDialog.estimatedHeading")}</span>
              <StatusDot tone={BAND_TONE[tds.band]} label={t(`masters.waterQuality.band.${tds.band}`)} />
            </div>
            <div className="text-sm text-text">
              {t("customers.detail.tdsDialog.typical", { ppm: Math.round(tds.typicalTdsPpm), district: tds.matchedDistrict })}
            </div>
            <div className="text-xs text-text-muted">{t("customers.detail.tdsDialog.range", { low: tds.rangeLow, high: tds.rangeHigh })}</div>
            <div className="text-xs text-text-muted">{t("customers.detail.tdsDialog.source", { source: tds.dataSource, year: tds.dataYear, count: tds.sampleCount })}</div>
            {tds.isProxy && tds.proxyNote ? <div className="text-xs text-warning">{tds.proxyNote}</div> : null}
          </div>
        ) : null}

        {tds?.recommendWaterTest ? <div className="text-xs font-medium text-text-muted">{t("customers.detail.waterTestRecommended")}</div> : null}
      </DialogContent>
    </Dialog>
  )
}
