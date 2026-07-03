import { useTranslation } from "react-i18next"
import { EntityCrudTable, type CrudFieldDef } from "@/components/shared/EntityCrudTable"
import { brandsHooks } from "@/hooks/useMasters"
import type { BrandRow } from "@/services/masters"
import { useProfile } from "@/hooks/useProfile"

const CATEGORIES = ["ro", "ac", "inverter", "battery"] as const

export function BrandsTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: rows, isLoading, isError, refetch } = brandsHooks.useList(orgId)
  const createMut = brandsHooks.useCreate()
  const updateMut = brandsHooks.useUpdate()
  const deleteMut = brandsHooks.useDelete()

  const fields: CrudFieldDef[] = [
    { key: "name", label: t("masters.brands.name"), type: "text" },
    {
      key: "category",
      label: t("masters.brands.category"),
      type: "select",
      options: CATEGORIES.map((c) => ({ value: c, label: t(`masters.categories.${c}`) })),
    },
  ]

  return (
    <EntityCrudTable<BrandRow>
      fields={fields}
      rows={rows ?? []}
      getId={(r) => r.id}
      loading={isLoading}
      error={isError ? t("masters.loadFailed") : null}
      onRetry={() => refetch()}
      isMutating={createMut.isPending || updateMut.isPending}
      addLabel={t("masters.brands.add")}
      emptyMessage={t("masters.brands.empty")}
      toFormValues={(r) => ({ name: r.name, category: r.category })}
      columns={[
        { key: "name", header: t("masters.brands.name"), render: (r) => <span className="font-medium text-text">{r.name}</span> },
        { key: "category", header: t("masters.brands.category"), render: (r) => t(`masters.categories.${r.category}`) },
      ]}
      onCreate={(v) => createMut.mutate({ org_id: orgId!, name: v.name, category: v.category as BrandRow["category"] })}
      onUpdate={(id, v) => updateMut.mutate({ id, patch: { name: v.name, category: v.category as BrandRow["category"] } })}
      onDelete={(id) => deleteMut.mutate(id)}
    />
  )
}
