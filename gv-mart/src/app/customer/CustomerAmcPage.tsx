import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { ShieldCheck } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { OwnedProductStatusCard } from "@/app/customer/components/OwnedProductStatusCard"
import { AmcBookingPanel } from "@/app/customer/components/AmcBookingPanel"
import { useAmcPlans, useCustomerAppSettings, useMyCustomerId, useOwnedProductsWithStatus } from "@/hooks/useCustomerApp"

export function CustomerAmcPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { customerId, orgId, isLoading: loadingId } = useMyCustomerId()
  const { data: rows, isLoading: loadingRows, isError, refetch } = useOwnedProductsWithStatus(customerId)
  const { data: settings, isLoading: loadingSettings } = useCustomerAppSettings(orgId)
  const { data: plans, isLoading: loadingPlans } = useAmcPlans(orgId)

  const isLoading = loadingId || loadingRows || loadingSettings || loadingPlans
  if (isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError) {
    return <FullPageError message={t("customerApp.amc.loadError")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  const bookWindowDays = settings?.amc_book_window_days ?? 30

  return (
    <div className="space-y-4 pb-4 pt-2">
      <h1 className="text-xl font-bold text-text">{t("customerApp.amc.title")}</h1>

      {(rows ?? []).length === 0 ? (
        <Card className="items-center gap-1.5 py-8 text-center">
          <ShieldCheck className="size-6 text-text-muted" />
          <p className="text-sm text-text-muted">{t("customerApp.amc.noCoverage")}</p>
          <Button size="sm" variant="outline" onClick={() => navigate("/customer/products")}>
            {t("customerApp.amc.viewMyProducts")}
          </Button>
        </Card>
      ) : (
        <div className="space-y-3">
          {(rows ?? []).map(({ product, amc, warranty }) => {
            const isRo = product.category === "ro"
            const dueDateStr = amc?.expiry_date ?? warranty?.expiry_date ?? null
            return (
              <OwnedProductStatusCard
                key={product.id}
                product={product}
                amc={amc}
                warranty={warranty}
                showAmcSection={isRo}
                onHeaderClick={() => navigate(`/customer/amc/${product.id}`)}
                actionSlot={
                  isRo ? (
                    <AmcBookingPanel
                      orgId={orgId!}
                      customerId={customerId!}
                      productId={product.id}
                      dueDateStr={dueDateStr}
                      bookWindowDays={bookWindowDays}
                      plans={plans ?? []}
                      ctaLabel={amc ? t("customerApp.amc.renewNow") : t("customerApp.amc.bookNow")}
                    />
                  ) : undefined
                }
              />
            )
          })}
        </div>
      )}
    </div>
  )
}
