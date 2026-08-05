import { useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { Package } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { FullPageLoader } from "@/components/shared/FullPageLoader"
import { useCatalogProducts, useProductEnquiryFilters } from "@/hooks/useCustomerApp"
import { productImagePublicUrl } from "@/services/productMedia"
import type { Enums, Json } from "@/types/database"

const MAX_COMPARE = 3

function toNumberArray(json: Json | null | undefined): number[] {
  return Array.isArray(json) ? json.filter((x): x is number => typeof x === "number") : []
}
function toStringArray(json: Json | null | undefined): string[] {
  return Array.isArray(json) ? json.filter((x): x is string => typeof x === "string") : []
}

/**
 * Product Enquiry rebuild (2026-08-04), Phase 3 (minimal) / Phase 4 (full) /
 * Phase 6 (filter chips) / restyle (list rows). Lean grid query only — no
 * documents/videos/custom_attributes/related products here, those load on
 * the single-product detail fetch so the grid stays cheap regardless of
 * how much detail a product has. Filter chips only support category/brand/
 * price_range (the fields already in this lean select) — an admin-
 * configured attribute-key filter would need custom_attributes in this
 * query too, which would defeat the point of keeping it lean, so those
 * don't render as chips here (a deliberate scope line, not a silent bug).
 *
 * Row layout is modeled on a reference e-commerce search-results screenshot
 * the user supplied — adapted to what this app actually has: no MRP/
 * discount, star ratings, review counts, or delivery dates exist in this
 * domain, so those are dropped rather than faked. Only the real fields
 * (image, name, brand/model, feature bullets, warranty, price) are laid out
 * in the same horizontal image-left/details-right row density. "Request
 * Quotation" navigates to the detail page's existing quotation flow instead
 * of submitting inline, to avoid an N+1 CTA-config fetch per row.
 */
export function CustomerCatalogGrid({ orgId }: { orgId: string | undefined }) {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { data: products, isLoading } = useCatalogProducts(orgId)
  const { data: filterRows } = useProductEnquiryFilters(orgId)
  const [compareIds, setCompareIds] = useState<string[]>([])
  const [filterValues, setFilterValues] = useState<Record<string, string>>({})

  if (isLoading) return <FullPageLoader label={t("common.loading")} />

  if (!products || products.length === 0) {
    return <p className="rounded-xl border border-dashed border-border px-3.5 py-6 text-center text-sm text-text-muted">{t("customerApp.productEnquiry.catalog.empty")}</p>
  }

  const chipFilters = (filterRows ?? []).filter(
    (f): f is typeof f & { product_field: Enums<"product_enquiry_field"> } => f.product_field === "category" || f.product_field === "brand" || f.product_field === "price_range"
  )

  function toggleCompare(id: string) {
    setCompareIds((ids) => (ids.includes(id) ? ids.filter((x) => x !== id) : ids.length >= MAX_COMPARE ? ids : [...ids, id]))
  }
  function toggleFilterValue(filterId: string, value: string) {
    setFilterValues((v) => ({ ...v, [filterId]: v[filterId] === value ? "" : value }))
  }

  const filteredProducts = products.filter((p) =>
    chipFilters.every((f) => {
      const selected = filterValues[f.id]
      if (!selected) return true
      if (f.product_field === "category") return p.category === selected
      if (f.product_field === "brand") return p.brands?.name === selected
      if (f.product_field === "price_range") {
        const buckets = toNumberArray((f.config as Record<string, Json>)?.buckets)
        const idx = Number(selected)
        const lo = buckets[idx] ?? 0
        const hi = buckets[idx + 1]
        return p.price >= lo && (hi === undefined || p.price < hi)
      }
      return true
    })
  )

  return (
    <div className="space-y-3 pt-2 pb-4">
      {chipFilters.map((f) => {
        let options: { value: string; label: string }[] = []
        if (f.product_field === "category") {
          options = Array.from(new Set(products.map((p) => p.category))).map((c) => ({ value: c, label: t(`customerApp.productEnquiry.compare.category.${c}`) }))
        } else if (f.product_field === "brand") {
          options = Array.from(new Set(products.map((p) => p.brands?.name).filter((n): n is string => !!n))).map((n) => ({ value: n, label: n }))
        } else if (f.product_field === "price_range") {
          const buckets = toNumberArray((f.config as Record<string, Json>)?.buckets)
          options = buckets.map((lo, i) => {
            const hi = buckets[i + 1]
            return { value: String(i), label: hi !== undefined ? `₹${lo.toLocaleString("en-IN")}–₹${hi.toLocaleString("en-IN")}` : `₹${lo.toLocaleString("en-IN")}+` }
          })
        }
        if (options.length === 0) return null
        return (
          <div key={f.id} className="flex flex-wrap items-center gap-1.5">
            <span className="text-xs font-medium text-text-muted">{f.label}:</span>
            {options.map((opt) => {
              const active = filterValues[f.id] === opt.value
              return (
                <button
                  key={opt.value}
                  type="button"
                  onClick={() => toggleFilterValue(f.id, opt.value)}
                  className={`rounded-full border px-2.5 py-1 text-xs font-medium ${active ? "border-accent bg-accent text-white" : "border-border text-text-muted"}`}
                >
                  {opt.label}
                </button>
              )
            })}
          </div>
        )
      })}

      {filteredProducts.length === 0 ? (
        <p className="rounded-xl border border-dashed border-border px-3.5 py-6 text-center text-sm text-text-muted">{t("customerApp.productEnquiry.catalog.empty")}</p>
      ) : (
        <div className="space-y-3">
          {filteredProducts.map((p) => {
            const primaryImage = (p.product_images ?? []).find((img) => img.is_primary) ?? (p.product_images ?? [])[0]
            const inCompare = compareIds.includes(p.id)
            const bullets = toStringArray(p.feature_bullets).slice(0, 4)
            const goToDetail = () => navigate(`/customer/product-enquiry/catalog/${p.id}`)

            return (
              <Card key={p.id} className="relative flex-row items-start gap-5 p-4 sm:p-6">
                <button type="button" onClick={goToDetail} className="shrink-0">
                  {primaryImage ? (
                    <img
                      src={productImagePublicUrl(primaryImage.storage_path)}
                      alt={p.name}
                      className="size-32 rounded-subcard object-cover sm:size-48"
                    />
                  ) : (
                    <div className="flex size-32 items-center justify-center rounded-subcard bg-surface-alt text-text-muted sm:size-48">
                      <Package className="size-12" />
                    </div>
                  )}
                </button>

                <div className="flex min-w-0 flex-1 flex-col gap-1.5">
                  <button type="button" onClick={goToDetail} className="text-left">
                    <p className="line-clamp-2 text-base font-semibold text-text sm:text-lg">{p.name}</p>
                  </button>
                  <p className="text-sm text-text-muted">
                    {p.brands?.name ?? "—"} · {p.models?.name ?? "—"}
                  </p>

                  {p.description ? <p className="line-clamp-2 text-sm text-text-muted">{p.description}</p> : null}

                  {bullets.length > 0 ? (
                    <ul className="mt-1 list-disc space-y-1 pl-4 text-sm text-text-muted">
                      {bullets.map((b, i) => (
                        <li key={i} className="line-clamp-1">
                          {b}
                        </li>
                      ))}
                    </ul>
                  ) : null}

                  <Badge variant="info" className="mt-1.5 self-start">
                    {t("customerApp.productEnquiry.detail.warrantyBadge", { months: p.warranty_months })}
                  </Badge>

                  <div className="mt-3 flex flex-col items-start gap-2 sm:hidden">
                    <p className="text-xl font-bold text-text">₹{p.price.toLocaleString("en-IN")}</p>
                    <Button size="sm" onClick={goToDetail} className="w-full">
                      {t("customerApp.productEnquiry.detail.requestQuotationCta")}
                    </Button>
                  </div>
                </div>

                <div className="hidden w-48 shrink-0 flex-col items-end gap-3 text-right sm:flex">
                  <p className="text-2xl font-bold text-text">₹{p.price.toLocaleString("en-IN")}</p>
                  <Button size="sm" onClick={goToDetail}>
                    {t("customerApp.productEnquiry.detail.requestQuotationCta")}
                  </Button>
                  <label className="flex items-center gap-1 text-xs font-medium text-text-muted">
                    <input
                      type="checkbox"
                      checked={inCompare}
                      onChange={() => toggleCompare(p.id)}
                      className="size-4 accent-accent"
                      title={t("customerApp.productEnquiry.compare.cta")}
                    />
                    {t("customerApp.productEnquiry.compare.cta")}
                  </label>
                </div>

                <label className="absolute top-3 right-3 flex shrink-0 items-center gap-1 text-[11px] font-medium text-text-muted sm:hidden">
                  <input
                    type="checkbox"
                    checked={inCompare}
                    onChange={() => toggleCompare(p.id)}
                    className="size-3.5 accent-accent"
                    title={t("customerApp.productEnquiry.compare.cta")}
                  />
                </label>
              </Card>
            )
          })}
        </div>
      )}

      {compareIds.length > 0 ? (
        <div className="sticky bottom-2 z-20 flex items-center justify-between rounded-xl border border-border bg-surface px-3.5 py-2.5 shadow-lg">
          <span className="text-sm text-text-muted">{t("customerApp.productEnquiry.compare.selectedCount", { count: compareIds.length, max: MAX_COMPARE })}</span>
          <Button size="sm" onClick={() => navigate(`/customer/product-enquiry/compare?ids=${compareIds.join(",")}`)}>
            {t("customerApp.productEnquiry.compare.cta")} ({compareIds.length})
          </Button>
        </div>
      ) : null}
    </div>
  )
}
