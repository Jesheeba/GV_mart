import { useTranslation } from "react-i18next"
import { useNavigate, useSearchParams } from "react-router-dom"
import { ArrowLeft } from "lucide-react"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { useCatalogProductsByIds, useMyCustomerId, useProductEnquiryComparisonFields } from "@/hooks/useCustomerApp"
import { CompareTable } from "./productEnquiry/CompareTable"

const MAX_COMPARE = 3

/**
 * Product Enquiry rebuild (2026-08-04), Phase 5 — reads `ids` from the
 * query string (comma-joined, e.g. ?ids=a,b,c), silently caps at 3 if
 * more are hand-edited into the URL (no server-side enforcement needed —
 * this is a read-only comparison view, not a mutation).
 */
export function CustomerCompareProductsPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const [searchParams] = useSearchParams()
  const ids = (searchParams.get("ids") ?? "").split(",").filter(Boolean).slice(0, MAX_COMPARE)
  const { orgId, isLoading: loadingId } = useMyCustomerId()
  const { data: products, isLoading: loadingProducts, isError, refetch } = useCatalogProductsByIds(orgId, ids)
  const { data: fields, isLoading: loadingFields } = useProductEnquiryComparisonFields(orgId)

  if (loadingId || loadingProducts || loadingFields) return <FullPageLoader label={t("common.loading")} />
  if (isError) {
    return <FullPageError message={t("customerApp.productEnquiry.compare.loadError")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  return (
    <div className="space-y-4 pb-4 pt-2">
      <button type="button" onClick={() => navigate(-1)} className="flex items-center gap-1.5 text-sm font-medium text-text-muted">
        <ArrowLeft className="size-4" />
        {t("customerApp.productEnquiry.close")}
      </button>
      <h1 className="text-xl font-bold text-text">{t("customerApp.productEnquiry.compare.title")}</h1>

      {!products || products.length === 0 || !fields || fields.length === 0 ? (
        <p className="rounded-xl border border-dashed border-border px-3.5 py-6 text-center text-sm text-text-muted">{t("customerApp.productEnquiry.compare.empty")}</p>
      ) : (
        <CompareTable fields={fields} products={products} />
      )}
    </div>
  )
}
