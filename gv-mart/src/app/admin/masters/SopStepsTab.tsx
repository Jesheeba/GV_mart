import { useMemo } from "react"
import { useTranslation } from "react-i18next"
import { EntityCrudTable, type CrudFieldDef } from "@/components/shared/EntityCrudTable"
import { productsHooks, sopStepTemplatesHooks } from "@/hooks/useMasters"
import type { SopStepTemplateRow } from "@/services/masters"
import { useProfile } from "@/hooks/useProfile"

const GENERIC_PRODUCT_VALUE = ""

export function SopStepsTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: products } = productsHooks.useList(orgId)
  const { data: rows, isLoading, isError, refetch } = sopStepTemplatesHooks.useList(orgId)
  const createMut = sopStepTemplatesHooks.useCreate()
  const updateMut = sopStepTemplatesHooks.useUpdate()
  const deleteMut = sopStepTemplatesHooks.useDelete()

  const productOptions = useMemo(
    () => [{ value: GENERIC_PRODUCT_VALUE, label: t("masters.sopSteps.genericProduct") }, ...(products ?? []).map((p) => ({ value: p.id, label: p.name }))],
    [products, t]
  )

  const fields: CrudFieldDef[] = [
    { key: "name", label: t("masters.sopSteps.name"), type: "text", required: true },
    { key: "default_expected_minutes", label: t("masters.sopSteps.expectedMinutes"), type: "number", step: "1", min: 1 },
    { key: "product_id", label: t("masters.sopSteps.product"), type: "select", options: productOptions },
  ]

  return (
    <EntityCrudTable<SopStepTemplateRow>
      fields={fields}
      rows={rows ?? []}
      getId={(r) => r.id}
      loading={isLoading}
      error={isError ? t("masters.loadFailed") : null}
      onRetry={() => refetch()}
      isMutating={createMut.isPending || updateMut.isPending}
      addLabel={t("masters.sopSteps.add")}
      emptyMessage={t("masters.sopSteps.empty")}
      toFormValues={(r) => ({
        name: r.name,
        default_expected_minutes: String(r.default_expected_minutes),
        product_id: r.product_id ?? GENERIC_PRODUCT_VALUE,
      })}
      columns={[
        { key: "name", header: t("masters.sopSteps.name"), render: (r) => <span className="font-medium text-text">{r.name}</span> },
        { key: "product", header: t("masters.sopSteps.product"), render: (r) => r.products?.name ?? t("masters.sopSteps.genericProduct") },
        { key: "minutes", header: t("masters.sopSteps.expectedMinutes"), render: (r) => t("masters.sopSteps.minutesValue", { count: r.default_expected_minutes }) },
      ]}
      onCreate={(v) =>
        createMut.mutateAsync({
          org_id: orgId!,
          name: v.name,
          default_expected_minutes: Math.max(1, Number(v.default_expected_minutes) || 10),
          product_id: v.product_id || null,
        })
      }
      onUpdate={(id, v) =>
        updateMut.mutateAsync({
          id,
          patch: {
            name: v.name,
            default_expected_minutes: Math.max(1, Number(v.default_expected_minutes) || 10),
            product_id: v.product_id || null,
          },
        })
      }
      onDelete={(id) => deleteMut.mutateAsync(id)}
    />
  )
}
