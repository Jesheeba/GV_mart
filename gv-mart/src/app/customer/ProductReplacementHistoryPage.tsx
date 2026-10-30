import { useTranslation } from "react-i18next"
import { useNavigate, useParams } from "react-router-dom"
import { ArrowLeft, History, Package } from "lucide-react"
import { Card } from "@/components/ui/card"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { useMyCustomerId, useOwnedProductsWithStatus } from "@/hooks/useCustomerApp"
import { useCustomerReplacementHistory } from "@/hooks/useCustomerLifecycle"
import { formatDate } from "@/lib/formatDate"

/**
 * Product Lifecycle & Automated Service Reminder System — Drop 2, W3.
 *
 * No owned-product detail page existed to extend (CustomerProductDetailPage
 * is the catalog/Product-Enquiry browse page, keyed by the org's full
 * catalog productId — not an owned installed product; see its own header
 * comment). This is a new, narrowly-scoped page: just the replacement
 * history for one of the customer's own owned products, linked from each
 * OwnedProductStatusCard. Keyed by the catalog productId (same :productId
 * convention CustomerAmcProductDetailPage already uses) rather than a
 * specific installedProductId, since a card only ever has the former; the
 * history list itself still shows the responsible installed unit implicitly
 * through its rows (there's normally exactly one per product).
 */
export function ProductReplacementHistoryPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { productId } = useParams<{ productId: string }>()
  const { customerId, isLoading: loadingId } = useMyCustomerId()
  const { data: rows, isLoading: loadingRows, isError, refetch } = useOwnedProductsWithStatus(customerId)
  const { data: history, isLoading: loadingHistory } = useCustomerReplacementHistory(customerId)

  const isLoading = loadingId || loadingRows || loadingHistory
  if (isLoading) return <FullPageLoader label={t("common.loading")} />

  // Same guard as CustomerAmcProductDetailPage: only ever renders for a
  // product in this customer's own owned set, never falls back to the
  // catalog, so a bad/foreign productId just shows the error state.
  const row = rows?.find((r) => r.product.id === productId)
  if (isError || !row) {
    return <FullPageError message={t("customerLifecycle.history.loadError")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  const entries = (history ?? []).filter((h) => h.productId === productId).sort((a, b) => (a.replacedDate < b.replacedDate ? 1 : -1))
  const brandModel = [row.product.brands?.name, row.product.models?.name].filter(Boolean).join(" · ")

  return (
    <div className="space-y-4 pb-4 pt-2">
      <button type="button" onClick={() => navigate("/customer/products")} className="flex items-center gap-1.5 text-sm font-medium text-text-muted">
        <ArrowLeft className="size-4" />
        {t("customerLifecycle.history.back")}
      </button>

      <Card className="gap-1 lg:px-5">
        <div className="flex items-center justify-between px-1">
          <div>
            <p className="text-base font-semibold text-text">{row.product.name}</p>
            {brandModel ? <p className="text-xs text-text-muted">{brandModel}</p> : null}
          </div>
          <span className="flex size-9 shrink-0 items-center justify-center rounded-full bg-accent-soft text-accent">
            <Package className="size-4" />
          </span>
        </div>
      </Card>

      <Card className="gap-2 lg:px-5">
        <h2 className="flex items-center gap-1.5 px-1 text-sm font-semibold text-text">
          <History className="size-4 text-text-muted" />
          {t("customerLifecycle.history.title")}
        </h2>
        {entries.length === 0 ? (
          <p className="px-1 text-sm text-text-muted">{t("customerLifecycle.history.empty")}</p>
        ) : (
          <div className="space-y-2 px-1">
            {entries.map((entry) => (
              <div key={entry.id} className="space-y-1 rounded-xl border border-border px-3.5 py-2 text-xs">
                <div className="flex items-center justify-between">
                  <span className="font-medium text-text">{entry.label}</span>
                  <span className="text-text-muted">{t("customerLifecycle.history.replacedOn", { date: formatDate(entry.replacedDate) })}</span>
                </div>
                <p className="text-text-muted">{t("customerLifecycle.history.nextDue", { date: formatDate(entry.nextDueDate) })}</p>
              </div>
            ))}
          </div>
        )}
      </Card>
    </div>
  )
}
