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
    { key: "name", label: t("masters.gifts.name"), type: "text", required: true },
    { key: "threshold_amount", label: t("masters.gifts.threshold"), type: "number", step: "1", required: true, min: 0 },
    { key: "cost_price", label: t("masters.gifts.costPrice"), type: "number", step: "0.01", placeholder: t("masters.costPriceNotSet"), min: 0 },
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
      toFormValues={(r) => ({
        name: r.name,
        threshold_amount: String(r.threshold_amount),
        cost_price: r.cost_price != null ? String(r.cost_price) : "",
      })}
      columns={[
        { key: "name", header: t("masters.gifts.name"), render: (r) => <span className="font-medium text-text">{r.name}</span> },
        { key: "threshold", header: t("masters.gifts.threshold"), render: (r) => `₹${r.threshold_amount}+` },
        { key: "cost_price", header: t("masters.gifts.costPrice"), render: (r) => (r.cost_price != null ? `₹${r.cost_price}` : t("masters.costPriceNotSet")) },
      ]}
      onCreate={(v) =>
        createMut.mutateAsync({
          org_id: orgId!,
          name: v.name,
          threshold_amount: Number(v.threshold_amount) || 0,
          cost_price: v.cost_price ? Number(v.cost_price) : null,
        })
      }
      onUpdate={(id, v) =>
        updateMut.mutateAsync({
          id,
          patch: {
            name: v.name,
            threshold_amount: Number(v.threshold_amount) || 0,
            cost_price: v.cost_price ? Number(v.cost_price) : null,
          },
        })
      }
      onDelete={(id) => deleteMut.mutateAsync(id)}
    />
  )
}
