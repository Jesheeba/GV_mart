import { useMemo } from "react"
import { useTranslation } from "react-i18next"
import { EntityCrudTable, type CrudFieldDef } from "@/components/shared/EntityCrudTable"
import { brandsHooks, modelsHooks, productsHooks } from "@/hooks/useMasters"
import { useProfile } from "@/hooks/useProfile"
import type { Enums } from "@/types/database"

const CATEGORIES = ["ro", "ac", "inverter", "battery"] as const satisfies readonly Enums<"brand_category">[]

type ProductWithRefs = {
  id: string
  org_id: string
  brand_id: string
  model_id: string
  name: string
  category: Enums<"brand_category">
  price: number
  hsn_code: string | null
  warranty_months: number
  created_at: string
  updated_at: string
  brands: { name: string } | null
  models: { name: string } | null
}

export function ProductsTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: brands } = brandsHooks.useList(orgId)
  const { data: models } = modelsHooks.useList(orgId)
  const { data: rows, isLoading, isError, refetch } = productsHooks.useList(orgId)
  const createMut = productsHooks.useCreate()
  const updateMut = productsHooks.useUpdate()
  const deleteMut = productsHooks.useDelete()

  const brandOptions = useMemo(() => (brands ?? []).map((b) => ({ value: b.id, label: b.name })), [brands])
  const modelOptions = useMemo(
    () =>
      (models ?? []).map((m) => ({
        value: m.id,
        label: `${m.name} (${(m as { brands: { name: string } | null }).brands?.name ?? "—"})`,
      })),
    [models]
  )

  const fields: CrudFieldDef[] = [
    { key: "name", label: t("masters.products.name"), type: "text" },
    { key: "brand_id", label: t("masters.products.brand"), type: "select", options: brandOptions },
    { key: "model_id", label: t("masters.products.model"), type: "select", options: modelOptions },
    {
      key: "category",
      label: t("masters.products.category"),
      type: "select",
      options: CATEGORIES.map((c) => ({ value: c, label: t(`masters.categories.${c}`) })),
    },
    { key: "price", label: t("masters.products.price"), type: "number", step: "0.01" },
    { key: "hsn_code", label: t("masters.products.hsn"), type: "text" },
    { key: "warranty_months", label: t("masters.products.warrantyMonths"), type: "number", step: "1" },
  ]

  if (!brands?.length || !models?.length) {
    return <p className="px-1 text-sm text-text-muted">{t("masters.products.needsBrandModelFirst")}</p>
  }

  return (
    <EntityCrudTable<ProductWithRefs>
      fields={fields}
      rows={(rows ?? []) as ProductWithRefs[]}
      getId={(r) => r.id}
      loading={isLoading}
      error={isError ? t("masters.loadFailed") : null}
      onRetry={() => refetch()}
      isMutating={createMut.isPending || updateMut.isPending}
      addLabel={t("masters.products.add")}
      emptyMessage={t("masters.products.empty")}
      toFormValues={(r) => ({
        name: r.name,
        brand_id: r.brand_id,
        model_id: r.model_id,
        category: r.category,
        price: String(r.price),
        hsn_code: r.hsn_code ?? "",
        warranty_months: String(r.warranty_months),
      })}
      columns={[
        { key: "name", header: t("masters.products.name"), render: (r) => <span className="font-medium text-text">{r.name}</span> },
        { key: "brand", header: t("masters.products.brand"), render: (r) => r.brands?.name ?? "—" },
        { key: "model", header: t("masters.products.model"), render: (r) => r.models?.name ?? "—" },
        { key: "price", header: t("masters.products.price"), render: (r) => `₹${r.price}` },
        { key: "warranty", header: t("masters.products.warrantyMonths"), render: (r) => r.warranty_months },
      ]}
      onCreate={(v) =>
        createMut.mutateAsync({
          org_id: orgId!,
          name: v.name,
          brand_id: v.brand_id,
          model_id: v.model_id,
          category: v.category as Enums<"brand_category">,
          price: Number(v.price) || 0,
          hsn_code: v.hsn_code || null,
          warranty_months: Number(v.warranty_months) || 12,
        })
      }
      onUpdate={(id, v) =>
        updateMut.mutateAsync({
          id,
          patch: {
            name: v.name,
            brand_id: v.brand_id,
            model_id: v.model_id,
            category: v.category as Enums<"brand_category">,
            price: Number(v.price) || 0,
            hsn_code: v.hsn_code || null,
            warranty_months: Number(v.warranty_months) || 12,
          },
        })
      }
      onDelete={(id) => deleteMut.mutateAsync(id)}
    />
  )
}
