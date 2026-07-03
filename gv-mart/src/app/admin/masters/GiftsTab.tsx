import { useTranslation } from "react-i18next"
import { EntityCrudTable, type CrudFieldDef } from "@/components/shared/EntityCrudTable"
import { giftsHooks } from "@/hooks/useMasters"
import type { GiftRow } from "@/services/masters"
import { useProfile } from "@/hooks/useProfile"

export function GiftsTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: rows, isLoading, isError, refetch } = giftsHooks.useList(orgId)
  const createMut = giftsHooks.useCreate()
  const updateMut = giftsHooks.useUpdate()
  const deleteMut = giftsHooks.useDelete()

  const fields: CrudFieldDef[] = [
    { key: "name", label: t("masters.gifts.name"), type: "text" },
    { key: "threshold_amount", label: t("masters.gifts.threshold"), type: "number", step: "1" },
  ]

  return (
    <EntityCrudTable<GiftRow>
      fields={fields}
      rows={rows ?? []}
      getId={(r) => r.id}
      loading={isLoading}
      error={isError ? t("masters.loadFailed") : null}
      onRetry={() => refetch()}
      isMutating={createMut.isPending || updateMut.isPending}
      addLabel={t("masters.gifts.add")}
      emptyMessage={t("masters.gifts.empty")}
      toFormValues={(r) => ({ name: r.name, threshold_amount: String(r.threshold_amount) })}
      columns={[
        { key: "name", header: t("masters.gifts.name"), render: (r) => <span className="font-medium text-text">{r.name}</span> },
        { key: "threshold", header: t("masters.gifts.threshold"), render: (r) => `₹${r.threshold_amount}+` },
      ]}
      onCreate={(v) => createMut.mutate({ org_id: orgId!, name: v.name, threshold_amount: Number(v.threshold_amount) || 0 })}
      onUpdate={(id, v) => updateMut.mutate({ id, patch: { name: v.name, threshold_amount: Number(v.threshold_amount) || 0 } })}
      onDelete={(id) => deleteMut.mutate(id)}
    />
  )
}
