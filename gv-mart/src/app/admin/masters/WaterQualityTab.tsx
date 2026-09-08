import { useMemo } from "react"
import { useTranslation } from "react-i18next"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { EntityCrudTable, type CrudFieldDef } from "@/components/shared/EntityCrudTable"
import { productsHooks, productTdsRecommendationsHooks, waterQualityDistrictAliasesHooks, waterQualityReferenceHooks } from "@/hooks/useMasters"
import { useProfile } from "@/hooks/useProfile"
import type { ProductTdsRecommendationRow, WaterQualityDistrictAliasRow, WaterQualityReferenceRow } from "@/services/masters"

const BANDS = ["low", "medium", "high"] as const

/**
 * TDS-based RO recommendation admin screen (standalone feature — see
 * 20260902100000_water_quality_tds_recommendation.sql and
 * services/waterQuality.ts). Three related tables, one screen: the
 * district TDS reference data (imported from CGWB, editable here in case
 * local knowledge is more accurate for a specific area), the district-name
 * aliases that resolve a customer's free-text address.district to a
 * reference row, and the band → RO product picks shown on the customer
 * profile's "Next best action" panel.
 */
export function WaterQualityTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  return (
    <div className="space-y-4">
      <Card>
        <CardHeader>
          <CardTitle>{t("masters.waterQuality.districtsTitle")}</CardTitle>
        </CardHeader>
        <CardContent>
          <DistrictsSection orgId={orgId} />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>{t("masters.waterQuality.aliasesTitle")}</CardTitle>
        </CardHeader>
        <CardContent>
          <AliasesSection orgId={orgId} />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>{t("masters.waterQuality.productsTitle")}</CardTitle>
        </CardHeader>
        <CardContent>
          <ProductsSection orgId={orgId} />
        </CardContent>
      </Card>
    </div>
  )
}

function DistrictsSection({ orgId }: { orgId: string | undefined }) {
  const { t } = useTranslation()
  const { data: rows, isLoading, isError, refetch } = waterQualityReferenceHooks.useList(orgId)
  const createMut = waterQualityReferenceHooks.useCreate()
  const updateMut = waterQualityReferenceHooks.useUpdate()
  const deleteMut = waterQualityReferenceHooks.useDelete()

  const fields: CrudFieldDef[] = [
    { key: "district", label: t("masters.waterQuality.district"), type: "text", required: true },
    { key: "typical_tds_ppm", label: t("masters.waterQuality.typicalTds"), type: "number", step: "0.1", required: true, min: 0 },
    { key: "tds_range_low", label: t("masters.waterQuality.rangeLow"), type: "number", step: "0.1", required: true, min: 0 },
    { key: "tds_range_high", label: t("masters.waterQuality.rangeHigh"), type: "number", step: "0.1", required: true, min: 0 },
    { key: "sample_count", label: t("masters.waterQuality.sampleCount"), type: "number", min: 0 },
    { key: "data_year", label: t("masters.waterQuality.dataYear"), type: "number", required: true, min: 1990, max: 2100 },
  ]

  return (
    <EntityCrudTable<WaterQualityReferenceRow>
      fields={fields}
      rows={rows ?? []}
      getId={(r) => r.id}
      loading={isLoading}
      error={isError ? t("masters.loadFailed") : null}
      onRetry={() => refetch()}
      isMutating={createMut.isPending || updateMut.isPending}
      addLabel={t("masters.waterQuality.addDistrict")}
      emptyMessage={t("masters.waterQuality.emptyDistricts")}
      toFormValues={(r) => ({
        district: r.district,
        typical_tds_ppm: String(r.typical_tds_ppm),
        tds_range_low: String(r.tds_range_low),
        tds_range_high: String(r.tds_range_high),
        sample_count: String(r.sample_count),
        data_year: String(r.data_year),
      })}
      columns={[
        { key: "district", header: t("masters.waterQuality.district"), render: (r) => <span className="font-medium text-text">{r.district}</span> },
        { key: "typical_tds_ppm", header: t("masters.waterQuality.typicalTds"), render: (r) => `${r.typical_tds_ppm} ppm` },
        { key: "range", header: t("masters.waterQuality.range"), render: (r) => `${r.tds_range_low}–${r.tds_range_high} ppm` },
        { key: "data_year", header: t("masters.waterQuality.dataYear"), render: (r) => `${r.data_year} · ${r.sample_count} ${t("masters.waterQuality.samples")}` },
      ]}
      onCreate={(v) =>
        createMut.mutateAsync({
          org_id: orgId!,
          district: v.district,
          typical_tds_ppm: Number(v.typical_tds_ppm),
          tds_range_low: Number(v.tds_range_low),
          tds_range_high: Number(v.tds_range_high),
          sample_count: v.sample_count ? Number(v.sample_count) : 0,
          data_year: Number(v.data_year),
        })
      }
      onUpdate={(id, v) =>
        updateMut.mutateAsync({
          id,
          patch: {
            district: v.district,
            typical_tds_ppm: Number(v.typical_tds_ppm),
            tds_range_low: Number(v.tds_range_low),
            tds_range_high: Number(v.tds_range_high),
            sample_count: v.sample_count ? Number(v.sample_count) : 0,
            data_year: Number(v.data_year),
          },
        })
      }
      onDelete={(id) => deleteMut.mutateAsync(id)}
    />
  )
}

function AliasesSection({ orgId }: { orgId: string | undefined }) {
  const { t } = useTranslation()
  const { data: districts } = waterQualityReferenceHooks.useList(orgId)
  const { data: rows, isLoading, isError, refetch } = waterQualityDistrictAliasesHooks.useList(orgId)
  const createMut = waterQualityDistrictAliasesHooks.useCreate()
  const updateMut = waterQualityDistrictAliasesHooks.useUpdate()
  const deleteMut = waterQualityDistrictAliasesHooks.useDelete()

  const districtOptions = useMemo(() => (districts ?? []).map((d) => ({ value: d.district, label: d.district })), [districts])

  const fields: CrudFieldDef[] = [
    { key: "alias", label: t("masters.waterQuality.alias"), type: "text", required: true, placeholder: t("masters.waterQuality.aliasPlaceholder") },
    { key: "canonical_district", label: t("masters.waterQuality.canonicalDistrict"), type: "select", options: districtOptions, required: true },
    {
      key: "is_proxy",
      label: t("masters.waterQuality.isProxy"),
      type: "select",
      options: [
        { value: "false", label: t("common.no") },
        { value: "true", label: t("common.yes") },
      ],
    },
    { key: "proxy_note", label: t("masters.waterQuality.proxyNote"), type: "textarea", placeholder: t("masters.waterQuality.proxyNotePlaceholder") },
  ]

  return (
    <EntityCrudTable<WaterQualityDistrictAliasRow>
      fields={fields}
      rows={rows ?? []}
      getId={(r) => r.id}
      loading={isLoading}
      error={isError ? t("masters.loadFailed") : null}
      onRetry={() => refetch()}
      isMutating={createMut.isPending || updateMut.isPending}
      addLabel={t("masters.waterQuality.addAlias")}
      emptyMessage={t("masters.waterQuality.emptyAliases")}
      toFormValues={(r) => ({
        alias: r.alias,
        canonical_district: r.canonical_district,
        is_proxy: String(r.is_proxy),
        proxy_note: r.proxy_note ?? "",
      })}
      columns={[
        { key: "alias", header: t("masters.waterQuality.alias"), render: (r) => <span className="font-medium text-text">{r.alias}</span> },
        { key: "canonical_district", header: t("masters.waterQuality.canonicalDistrict"), render: (r) => r.canonical_district },
        { key: "is_proxy", header: t("masters.waterQuality.isProxy"), render: (r) => (r.is_proxy ? t("common.yes") : t("common.no")) },
      ]}
      onCreate={(v) =>
        createMut.mutateAsync({
          org_id: orgId!,
          alias: v.alias.trim().toLowerCase(),
          canonical_district: v.canonical_district,
          is_proxy: v.is_proxy === "true",
          proxy_note: v.proxy_note || null,
        })
      }
      onUpdate={(id, v) =>
        updateMut.mutateAsync({
          id,
          patch: {
            alias: v.alias.trim().toLowerCase(),
            canonical_district: v.canonical_district,
            is_proxy: v.is_proxy === "true",
            proxy_note: v.proxy_note || null,
          },
        })
      }
      onDelete={(id) => deleteMut.mutateAsync(id)}
    />
  )
}

function ProductsSection({ orgId }: { orgId: string | undefined }) {
  const { t } = useTranslation()
  const { data: products } = productsHooks.useList(orgId)
  const { data: rows, isLoading, isError, refetch } = productTdsRecommendationsHooks.useList(orgId)
  const createMut = productTdsRecommendationsHooks.useCreate()
  const updateMut = productTdsRecommendationsHooks.useUpdate()
  const deleteMut = productTdsRecommendationsHooks.useDelete()

  const roProductOptions = useMemo(() => (products ?? []).filter((p) => p.category === "ro").map((p) => ({ value: p.id, label: p.name })), [products])
  const bandOptions = useMemo(() => BANDS.map((b) => ({ value: b, label: t(`masters.waterQuality.band.${b}`) })), [t])

  const fields: CrudFieldDef[] = [
    { key: "band", label: t("masters.waterQuality.band.label"), type: "select", options: bandOptions, required: true },
    { key: "product_id", label: t("masters.waterQuality.product"), type: "select", options: roProductOptions, required: true },
    { key: "sort_order", label: t("masters.waterQuality.sortOrder"), type: "number", min: 0 },
  ]

  return (
    <EntityCrudTable<ProductTdsRecommendationRow>
      fields={fields}
      rows={rows ?? []}
      getId={(r) => r.id}
      loading={isLoading}
      error={isError ? t("masters.loadFailed") : null}
      onRetry={() => refetch()}
      isMutating={createMut.isPending || updateMut.isPending}
      addLabel={t("masters.waterQuality.addProduct")}
      emptyMessage={t("masters.waterQuality.emptyProducts")}
      toFormValues={(r) => ({ band: r.band, product_id: r.product_id, sort_order: String(r.sort_order) })}
      columns={[
        { key: "band", header: t("masters.waterQuality.band.label"), render: (r) => t(`masters.waterQuality.band.${r.band}`) },
        { key: "product", header: t("masters.waterQuality.product"), render: (r) => <span className="font-medium text-text">{r.products?.name ?? "—"}</span> },
        { key: "sort_order", header: t("masters.waterQuality.sortOrder"), render: (r) => r.sort_order },
      ]}
      onCreate={(v) =>
        createMut.mutateAsync({
          org_id: orgId!,
          band: v.band,
          product_id: v.product_id,
          sort_order: v.sort_order ? Number(v.sort_order) : 0,
        })
      }
      onUpdate={(id, v) =>
        updateMut.mutateAsync({
          id,
          patch: { band: v.band, product_id: v.product_id, sort_order: v.sort_order ? Number(v.sort_order) : 0 },
        })
      }
      onDelete={(id) => deleteMut.mutateAsync(id)}
    />
  )
}
