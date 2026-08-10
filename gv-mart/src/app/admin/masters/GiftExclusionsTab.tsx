import { useMemo } from "react"
import { useTranslation } from "react-i18next"
import { EntityCrudTable, type CrudFieldDef } from "@/components/shared/EntityCrudTable"
import { giftExclusionProductsHooks, productsHooks } from "@/hooks/useMasters"
import type { GiftExclusionProductRow } from "@/services/masters"
import { useProfile } from "@/hooks/useProfile"

/**
 * Enhancement spec Task 4 — a product on this list is dropped from the
 * gift-qualifying subtotal in create_sale (see
 * 20260807090000_gift_exclusion_products.sql) even when the rest of the
 * cart clears the gift threshold. Same add/edit/delete pattern as
 * GiftsTab/SopStepsTab — see EntityCrudTable.
 */
export function GiftExclusionsTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: products } = productsHooks.useList(orgId)
  const { data: rows, isLoading, isError, refetch } = giftExclusionProductsHooks.useList(orgId)
  const createMut = giftExclusionProductsHooks.useCreate()
  const updateMut = giftExclusionProductsHooks.useUpdate()
  const deleteMut = giftExclusionProductsHooks.useDelete()

  const productOptions = useMemo(() => (products ?? []).map((p) => ({ value: p.id, label: p.name })), [products])

  const fields: CrudFieldDef[] = [
    { key: "product_id", label: t("masters.giftExclusions.product"), type: "select", options: productOptions, required: true },
    {
      key: "is_active",
      label: t("masters.giftExclusions.active"),
      type: "select",
      options: [
        { value: "true", label: t("common.yes") },
        { value: "false", label: t("common.no") },
      ],
    },
  ]

  return (
    <EntityCrudTable<GiftExclusionProductRow>
      fields={fields}
      rows={rows ?? []}
      getId={(r) => r.id}
      loading={isLoading}
      error={isError ? t("masters.loadFailed") : null}
      onRetry={() => refetch()}
      isMutating={createMut.isPending || updateMut.isPending}
      addLabel={t("masters.giftExclusions.add")}
      emptyMessage={t("masters.giftExclusions.empty")}
      toFormValues={(r) => ({ product_id: r.product_id, is_active: String(r.is_active) })}
      columns={[
        { key: "product", header: t("masters.giftExclusions.product"), render: (r) => <span className="font-medium text-text">{r.products?.name ?? "—"}</span> },
        { key: "is_active", header: t("masters.giftExclusions.active"), render: (r) => (r.is_active ? t("common.yes") : t("common.no")) },
      ]}
      onCreate={(v) =>
        createMut.mutateAsync({
          org_id: orgId!,
          product_id: v.product_id,
          is_active: v.is_active !== "false",
        })
      }
      onUpdate={(id, v) =>
        updateMut.mutateAsync({
          id,
          patch: { product_id: v.product_id, is_active: v.is_active !== "false" },
        })
      }
      onDelete={(id) => deleteMut.mutateAsync(id)}
    />
  )
}
