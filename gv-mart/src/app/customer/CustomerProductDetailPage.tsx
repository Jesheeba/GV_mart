import { useTranslation } from "react-i18next"
import { useNavigate, useParams } from "react-router-dom"
import { ArrowLeft, FileText, Video } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Card } from "@/components/ui/card"
import { Table, TableBody, TableCell, TableRow } from "@/components/ui/table"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import {
  useActiveProductAttributeKeys,
  useCustomerAppSettings,
  useEffectiveProductCtas,
  useMyCustomerId,
  useProductDetail,
} from "@/hooks/useCustomerApp"
import { productDocumentPublicUrl } from "@/services/productMedia"
import { CTA_RENDERERS } from "./productEnquiry/moduleRegistry"
import { ProductPhotoHero } from "./productEnquiry/ProductPhotoHero"
import { EmiEstimateCard } from "./productEnquiry/EmiEstimateCard"
import type { Json } from "@/types/database"

function toStringArray(json: Json | null | undefined): string[] {
  return Array.isArray(json) ? json.filter((x): x is string => typeof x === "string") : []
}
function toNumberArray(json: Json | null | undefined): number[] {
  return Array.isArray(json) ? json.filter((x): x is number => typeof x === "number") : []
}

/**
 * Product Enquiry rebuild (2026-08-04), Phase 4 / restyle — full-hydration
 * detail page. Reorganized into a "buy box" (photo → name → price +
 * warranty + CTAs grouped together, all above the fold) loosely following
 * a reference e-commerce product-page layout the user supplied, adapted to
 * what this app actually has: no MRP/discount/ratings exist, so those are
 * omitted rather than faked, and the CTAs stay lead/quotation-based (no
 * cart/checkout — see CTA_RENDERERS). Specs render as a table (closer to
 * the reference's "product information" table) instead of a definition
 * list. Feature bullets / documents / videos / EMI / related products keep
 * their own sections below the buy box, unchanged in content.
 */
export function CustomerProductDetailPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { productId } = useParams<{ productId: string }>()
  const { orgId } = useMyCustomerId()
  const { data: product, isLoading, isError, refetch } = useProductDetail(productId)
  const { data: attributeKeys } = useActiveProductAttributeKeys(orgId)
  const { data: ctas } = useEffectiveProductCtas(orgId, productId)
  const { data: settings } = useCustomerAppSettings(orgId)

  if (isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError || !product) {
    return <FullPageError message={t("customerApp.productEnquiry.detail.loadError")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  const customAttributes = (product.custom_attributes as Record<string, unknown>) ?? {}
  const assignedAttributes = (attributeKeys ?? []).filter((k) => customAttributes[k.id] !== undefined)
  const documents = product.product_documents ?? []
  const videos = (product.product_videos ?? []).filter((v) => v.is_active)
  const related = product.product_related ?? []
  const featureBullets = toStringArray(product.feature_bullets)

  const tenureMonths = settings?.emi_enabled ? toNumberArray(settings.emi_tenure_months) : []
  const emiPerMonth = tenureMonths.length > 0 ? product.price / tenureMonths[0] : null

  return (
    <div className="space-y-4 pb-4 pt-2">
      <button type="button" onClick={() => navigate(-1)} className="flex items-center gap-1.5 text-sm font-medium text-text-muted">
        <ArrowLeft className="size-4" />
        {t("customerApp.productEnquiry.close")}
      </button>

      <ProductPhotoHero images={product.product_images ?? []} name={product.name} />

      {/* Buy box — name, price, warranty, and every CTA grouped together right under the photo. */}
      <Card className="gap-3 lg:px-5">
        <div>
          <h1 className="text-xl font-bold text-text">{product.name}</h1>
          <p className="text-sm text-text-muted">
            {product.brands?.name ?? "—"} · {product.models?.name ?? "—"}
          </p>
        </div>
        <div className="flex items-center gap-2">
          <p className="text-2xl font-extrabold tracking-tight text-text">₹{product.price.toLocaleString("en-IN")}</p>
          <Badge variant="info">{t("customerApp.productEnquiry.detail.warrantyBadge", { months: product.warranty_months })}</Badge>
        </div>
        <div className="space-y-2">
          {(ctas ?? []).map((cta) =>
            CTA_RENDERERS[cta.cta_type]({
              orgId,
              productId: product.id,
              cta,
              product: { name: product.name, price: product.price, brandName: product.brands?.name ?? null },
              emiPerMonth,
            })
          )}
        </div>
      </Card>

      {product.description ? (
        <Card className="gap-2 lg:px-5">
          <h2 className="px-1 text-sm font-semibold text-text">{t("customerApp.productEnquiry.detail.descriptionTitle")}</h2>
          <p className="whitespace-pre-line px-1 text-sm text-text-muted">{product.description}</p>
        </Card>
      ) : null}

      {featureBullets.length > 0 ? (
        <Card className="gap-2 lg:px-5">
          <h2 className="px-1 text-sm font-semibold text-text">{t("customerApp.productEnquiry.detail.featuresTitle")}</h2>
          <ul className="space-y-1 px-1">
            {featureBullets.map((bullet, i) => (
              <li key={i} className="text-sm text-text">
                • {bullet}
              </li>
            ))}
          </ul>
        </Card>
      ) : null}

      {assignedAttributes.length > 0 ? (
        <Card className="gap-2 lg:px-5">
          <h2 className="px-1 text-sm font-semibold text-text">{t("customerApp.productEnquiry.detail.attributesTitle")}</h2>
          <Table>
            <TableBody>
              {assignedAttributes.map((k) => (
                <TableRow key={k.id}>
                  <TableCell className="font-medium text-text">{k.label}</TableCell>
                  <TableCell className="text-text-muted">{String(customAttributes[k.id])}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </Card>
      ) : null}

      {documents.length > 0 || videos.length > 0 ? (
        <Card className="gap-2 lg:px-5">
          <h2 className="px-1 text-sm font-semibold text-text">{t("customerApp.productEnquiry.detail.mediaTitle")}</h2>
          <ul className="space-y-1 px-1">
            {documents.map((d) => (
              <li key={d.id}>
                <a href={productDocumentPublicUrl(d.storage_path)} target="_blank" rel="noreferrer" className="flex items-center gap-1.5 text-sm text-accent hover:underline">
                  <FileText className="size-3.5" />
                  {d.label}
                </a>
              </li>
            ))}
            {videos.map((v) => (
              <li key={v.id}>
                <a href={v.url} target="_blank" rel="noreferrer" className="flex items-center gap-1.5 text-sm text-accent hover:underline">
                  <Video className="size-3.5" />
                  {v.title || v.url}
                </a>
              </li>
            ))}
          </ul>
        </Card>
      ) : null}

      {tenureMonths.length > 0 ? <EmiEstimateCard price={product.price} tenureMonths={tenureMonths} disclaimer={settings?.emi_disclaimer ?? null} /> : null}

      {related.length > 0 ? (
        <Card className="gap-2 lg:px-5">
          <h2 className="px-1 text-sm font-semibold text-text">{t("customerApp.productEnquiry.detail.relatedTitle")}</h2>
          <div className="flex gap-2 overflow-x-auto px-1">
            {related.map((r) =>
              r.related ? (
                <button
                  key={r.id}
                  type="button"
                  onClick={() => navigate(`/customer/product-enquiry/catalog/${r.related!.id}`)}
                  className="shrink-0 rounded-xl border border-border px-3 py-2 text-left"
                >
                  <p className="text-sm font-medium text-text">{r.related.name}</p>
                  <p className="text-xs text-text-muted">₹{r.related.price.toLocaleString("en-IN")}</p>
                </button>
              ) : null
            )}
          </div>
        </Card>
      ) : null}
    </div>
  )
}
