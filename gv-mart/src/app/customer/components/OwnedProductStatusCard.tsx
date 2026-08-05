import type { ReactNode } from "react"
import { useTranslation } from "react-i18next"
import { Package, ShieldCheck } from "lucide-react"
import { Card } from "@/components/ui/card"
import { StatusDot } from "@/components/shared/StatusDot"
import type { MyOwnedProduct } from "@/hooks/useCustomerApp"
import type { MyAmcContractRow, MyWarrantyRow } from "@/services/customerApp"

/**
 * One card per owned product, unioning warranty + AMC status — the shared
 * rendering both CustomerProductsPage and CustomerAmcPage (redesign) build
 * on, so the two pages can't drift out of visual sync. Ported 1:1 from
 * CustomerProductsPage's original inline card body; `actionSlot` is the only
 * page-specific piece (Products page passes "Book Service", AMC page passes
 * the per-product AmcBookingPanel).
 *
 * `showAmcSection` is passed in by the caller (product.category === "ro")
 * rather than computed here — this component stays a pure status renderer
 * and never needs to know the AMC-is-RO-only business rule itself.
 */
export function OwnedProductStatusCard({
  product,
  amc,
  warranty,
  showAmcSection,
  onHeaderClick,
  actionSlot,
}: {
  product: MyOwnedProduct
  amc: MyAmcContractRow | undefined
  warranty: MyWarrantyRow | undefined
  showAmcSection: boolean
  onHeaderClick?: () => void
  actionSlot?: ReactNode
}) {
  const { t } = useTranslation()
  const today = new Date().toISOString().slice(0, 10)
  const brandModel = [product.brands?.name, product.models?.name].filter(Boolean).join(" · ")

  const header = (
    <div className="flex items-start justify-between px-1">
      <div>
        <p className="text-sm font-semibold text-text">{product.name}</p>
        {brandModel ? <p className="text-xs text-text-muted">{brandModel}</p> : null}
      </div>
      <span className="flex size-9 shrink-0 items-center justify-center rounded-full bg-accent-soft text-accent">
        <Package className="size-4" />
      </span>
    </div>
  )

  return (
    <Card className="gap-2.5 lg:px-5">
      {onHeaderClick ? (
        <button type="button" onClick={onHeaderClick} className="text-left">
          {header}
        </button>
      ) : (
        header
      )}

      {warranty ? (
        <div className="space-y-1.5 rounded-xl border border-border px-3.5 py-2 text-xs">
          <div className="flex items-center justify-between">
            <StatusDot
              tone={warranty.expiry_date >= today ? "info" : "neutral"}
              label={warranty.expiry_date >= today ? t("customerApp.products.warrantyActive") : t("customerApp.products.warrantyExpired")}
            />
            <span className="text-text-muted">{t("customerApp.products.expiresOn", { date: warranty.expiry_date })}</span>
          </div>
          <p className="text-text-muted">{t("customerApp.products.purchasedOn", { date: warranty.start_date })}</p>
        </div>
      ) : null}

      {showAmcSection ? (
        amc ? (
          <div className="space-y-1.5 rounded-xl border border-border px-3.5 py-2 text-xs">
            <div className="flex items-center justify-between">
              <StatusDot
                tone={amc.status === "active" ? "success" : amc.status === "due_soon" ? "warning" : "danger"}
                label={t(`customerApp.amc.status.${amc.status}`)}
              />
              <span className="flex items-center gap-1 text-text-muted">
                <ShieldCheck className="size-3 shrink-0" />
                {amc.amc_plans?.name}
              </span>
            </div>
            <p className="text-text-muted">{t("customerApp.products.expiresOn", { date: amc.expiry_date })}</p>
            {amc.next_service_date ? (
              <p className="text-text-muted">{t("customerApp.products.nextServiceOn", { date: amc.next_service_date })}</p>
            ) : null}
          </div>
        ) : (
          <div className="flex items-center rounded-xl border border-border px-3.5 py-2 text-xs">
            <StatusDot tone="neutral" label={t("customerApp.amc.noAmcForProduct")} />
          </div>
        )
      ) : null}

      {actionSlot}
    </Card>
  )
}
