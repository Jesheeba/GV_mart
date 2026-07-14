import { useMemo } from "react"
import { useTranslation } from "react-i18next"
import { EntityCrudTable, type CrudFieldDef } from "@/components/shared/EntityCrudTable"
import { amcPlansHooks, giftsHooks } from "@/hooks/useMasters"
import type { AmcPlanRow } from "@/services/masters"
import { useProfile } from "@/hooks/useProfile"

const NO_GIFT = "__none__"

/** inclusions is jsonb — represented in the form as a comma-separated list. */
function inclusionsToText(inclusions: unknown): string {
  return Array.isArray(inclusions) ? inclusions.filter((x) => typeof x === "string").join(", ") : ""
}
function textToInclusions(text: string): string[] {
  return text
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean)
}

export function AmcPlansTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: gifts } = giftsHooks.useList(orgId)
  const { data: rows, isLoading, isError, refetch } = amcPlansHooks.useList(orgId)
  const createMut = amcPlansHooks.useCreate()
  const updateMut = amcPlansHooks.useUpdate()
  const deleteMut = amcPlansHooks.useDelete()

  const giftOptions = useMemo(
    () => [{ value: NO_GIFT, label: t("masters.amcPlans.noGift") }, ...(gifts ?? []).map((g) => ({ value: g.id, label: g.name }))],
    [gifts, t]
  )

  const fields: CrudFieldDef[] = [
    { key: "name", label: t("masters.amcPlans.name"), type: "text", placeholder: t("masters.amcPlans.namePlaceholder") },
    { key: "years", label: t("masters.amcPlans.years"), type: "number", step: "1" },
    { key: "price", label: t("masters.amcPlans.price"), type: "number", step: "0.01" },
    { key: "visits_per_year", label: t("masters.amcPlans.visitsPerYear"), type: "number", step: "1" },
    { key: "gift_id", label: t("masters.amcPlans.gift"), type: "select", options: giftOptions },
    { key: "inclusions", label: t("masters.amcPlans.inclusions"), type: "text", placeholder: t("masters.amcPlans.inclusionsPlaceholder") },
  ]

  return (
    <EntityCrudTable<AmcPlanRow>
      fields={fields}
      rows={rows ?? []}
      getId={(r) => r.id}
      loading={isLoading}
      error={isError ? t("masters.loadFailed") : null}
      onRetry={() => refetch()}
      isMutating={createMut.isPending || updateMut.isPending}
      addLabel={t("masters.amcPlans.add")}
      emptyMessage={t("masters.amcPlans.empty")}
      toFormValues={(r) => ({
        name: r.name,
        years: String(r.years),
        price: String(r.price),
        visits_per_year: String(r.visits_per_year),
        gift_id: r.gift_id ?? NO_GIFT,
        inclusions: inclusionsToText(r.inclusions),
      })}
      columns={[
        { key: "name", header: t("masters.amcPlans.name"), render: (r) => <span className="font-medium text-text">{r.name}</span> },
        { key: "years", header: t("masters.amcPlans.years"), render: (r) => r.years },
        { key: "price", header: t("masters.amcPlans.price"), render: (r) => `₹${r.price}` },
        { key: "visits", header: t("masters.amcPlans.visitsPerYear"), render: (r) => r.visits_per_year },
      ]}
      onCreate={(v) =>
        createMut.mutateAsync({
          org_id: orgId!,
          name: v.name,
          years: Number(v.years) || 1,
          price: Number(v.price) || 0,
          visits_per_year: Number(v.visits_per_year) || 4,
          gift_id: v.gift_id === NO_GIFT ? null : v.gift_id,
          inclusions: textToInclusions(v.inclusions),
        })
      }
      onUpdate={(id, v) =>
        updateMut.mutateAsync({
          id,
          patch: {
            name: v.name,
            years: Number(v.years) || 1,
            price: Number(v.price) || 0,
            visits_per_year: Number(v.visits_per_year) || 4,
            gift_id: v.gift_id === NO_GIFT ? null : v.gift_id,
            inclusions: textToInclusions(v.inclusions),
          },
        })
      }
      onDelete={(id) => deleteMut.mutateAsync(id)}
    />
  )
}
