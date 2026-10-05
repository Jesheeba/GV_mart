import { useTranslation } from "react-i18next"
import { EntityCrudTable, type CrudFieldDef } from "@/components/shared/EntityCrudTable"
import { installationRatesHooks, productsHooks } from "@/hooks/useMasters"
import type { InstallationRateRow } from "@/services/masters"
import { useProfile } from "@/hooks/useProfile"
import { formatCurrency } from "@/lib/sale-calc"
import { FlatInstallationBonusCard } from "./FlatInstallationBonusCard"

const CATEGORIES = ["ro", "ac", "inverter", "battery"] as const

/** Per-unit installation incentive rates — entirely master-set, no hardcoded
 * ₹ anywhere, nothing seeded. Read by compute_incentives alongside (not
 * instead of) the flat-threshold 'installation' rule under Masters >
 * Incentives. */
export function InstallationRatesTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: rows, isLoading, isError, refetch } = installationRatesHooks.useList(orgId)
  const { data: products } = productsHooks.useList(orgId)
  const createMut = installationRatesHooks.useCreate()
  const updateMut = installationRatesHooks.useUpdate()
  const deleteMut = installationRatesHooks.useDelete()

  const productName = (id: string | null) => (id ? ((products ?? []).find((p) => p.id === id)?.name ?? "—") : t("masters.installationRates.anyProduct"))
  const categoryLabel = (c: string | null) => (c ? t(`masters.categories.${c}`) : t("masters.installationRates.anyCategory"))

  const fields: CrudFieldDef[] = [
    {
      key: "product_id",
      label: t("masters.installationRates.product"),
      type: "select",
      options: [{ value: "", label: t("masters.installationRates.anyProduct") }, ...(products ?? []).map((p) => ({ value: p.id, label: p.name }))],
    },
    {
      key: "category",
      label: t("masters.installationRates.category"),
      type: "select",
      options: [{ value: "", label: t("masters.installationRates.anyCategory") }, ...CATEGORIES.map((c) => ({ value: c, label: t(`masters.categories.${c}`) }))],
    },
    { key: "capacity", label: t("masters.installationRates.capacity"), type: "text" },
    { key: "configuration", label: t("masters.installationRates.configuration"), type: "text" },
    { key: "flat_amount", label: t("masters.installationRates.flatAmount"), type: "number", step: "0.01", required: true, min: 0 },
    {
      key: "is_active",
      label: t("masters.installationRates.status"),
      type: "select",
      options: [
        { value: "true", label: t("masters.installationRates.active") },
        { value: "false", label: t("masters.installationRates.inactive") },
      ],
    },
  ]

  function toPayload(v: Record<string, string>) {
    if (!v.product_id && !v.category) throw new Error(t("masters.installationRates.needScope"))
    return {
      product_id: v.product_id || null,
      category: (v.category || null) as InstallationRateRow["category"],
      capacity: v.capacity.trim() || null,
      configuration: v.configuration.trim() || null,
      flat_amount: Number(v.flat_amount) || 0,
      is_active: v.is_active !== "false",
    }
  }

  return (
    <div className="space-y-3">
      <FlatInstallationBonusCard orgId={orgId} />
      <p className="text-xs text-text-muted">{t("masters.installationRates.subtitle")}</p>
      <p className="text-xs text-text-muted">{t("masters.installationRates.matchHint")}</p>
      <EntityCrudTable<InstallationRateRow>
        fields={fields}
        rows={rows ?? []}
        getId={(r) => r.id}
        loading={isLoading}
        error={isError ? t("masters.loadFailed") : null}
        onRetry={() => refetch()}
        isMutating={createMut.isPending || updateMut.isPending}
        addLabel={t("masters.installationRates.add")}
        emptyMessage={t("masters.installationRates.empty")}
        toFormValues={(r) => ({
          product_id: r.product_id ?? "",
          category: r.category ?? "",
          capacity: r.capacity ?? "",
          configuration: r.configuration ?? "",
          flat_amount: String(r.flat_amount),
          is_active: String(r.is_active),
        })}
        columns={[
          { key: "product", header: t("masters.installationRates.product"), render: (r) => productName(r.product_id) },
          { key: "category", header: t("masters.installationRates.category"), render: (r) => categoryLabel(r.category) },
          { key: "capacity", header: t("masters.installationRates.capacity"), render: (r) => r.capacity ?? "—" },
          { key: "configuration", header: t("masters.installationRates.configuration"), render: (r) => r.configuration ?? "—" },
          { key: "flat_amount", header: t("masters.installationRates.flatAmount"), render: (r) => formatCurrency(r.flat_amount) },
          { key: "status", header: t("masters.installationRates.status"), render: (r) => (r.is_active ? t("masters.installationRates.active") : t("masters.installationRates.inactive")) },
        ]}
        onCreate={(v) => createMut.mutateAsync({ org_id: orgId!, ...toPayload(v) })}
        onUpdate={(id, v) => updateMut.mutateAsync({ id, patch: toPayload(v) })}
        onDelete={(id) => deleteMut.mutateAsync(id)}
      />
    </div>
  )
}
