import { useMemo } from "react"
import { useTranslation } from "react-i18next"
import { EntityCrudTable, type CrudFieldDef } from "@/components/shared/EntityCrudTable"
import { brandsHooks, modelsHooks } from "@/hooks/useMasters"
import { useProfile } from "@/hooks/useProfile"

type ModelWithBrand = {
  id: string
  org_id: string
  brand_id: string
  name: string
  type: string | null
  created_at: string
  updated_at: string
  brands: { name: string } | null
}

export function ModelsTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: brands } = brandsHooks.useList(orgId)
  const { data: rows, isLoading, isError, refetch } = modelsHooks.useList(orgId)
  const createMut = modelsHooks.useCreate()
  const updateMut = modelsHooks.useUpdate()
  const deleteMut = modelsHooks.useDelete()

  const brandOptions = useMemo(() => (brands ?? []).map((b) => ({ value: b.id, label: b.name })), [brands])

  const fields: CrudFieldDef[] = [
    { key: "brand_id", label: t("masters.models.brand"), type: "select", options: brandOptions },
    { key: "name", label: t("masters.models.name"), type: "text" },
    { key: "type", label: t("masters.models.type"), type: "text", placeholder: t("masters.models.typePlaceholder") },
  ]

  if (!brands?.length) {
    return <p className="px-1 text-sm text-text-muted">{t("masters.models.needsBrandFirst")}</p>
  }

  return (
    <EntityCrudTable<ModelWithBrand>
      fields={fields}
      rows={(rows ?? []) as ModelWithBrand[]}
      getId={(r) => r.id}
      loading={isLoading}
      error={isError ? t("masters.loadFailed") : null}
      onRetry={() => refetch()}
      isMutating={createMut.isPending || updateMut.isPending}
      addLabel={t("masters.models.add")}
      emptyMessage={t("masters.models.empty")}
      toFormValues={(r) => ({ brand_id: r.brand_id, name: r.name, type: r.type ?? "" })}
      columns={[
        { key: "name", header: t("masters.models.name"), render: (r) => <span className="font-medium text-text">{r.name}</span> },
        { key: "brand", header: t("masters.models.brand"), render: (r) => r.brands?.name ?? "—" },
        { key: "type", header: t("masters.models.type"), render: (r) => r.type || "—" },
      ]}
      onCreate={(v) => createMut.mutateAsync({ org_id: orgId!, brand_id: v.brand_id, name: v.name, type: v.type || null })}
      onUpdate={(id, v) => updateMut.mutateAsync({ id, patch: { brand_id: v.brand_id, name: v.name, type: v.type || null } })}
      onDelete={(id) => deleteMut.mutateAsync(id)}
    />
  )
}
