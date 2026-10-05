import { useTranslation } from "react-i18next"
import { EntityCrudTable, type CrudFieldDef } from "@/components/shared/EntityCrudTable"
import { incentiveRulesHooks } from "@/hooks/useMasters"
import type { IncentiveRuleRow, IncentiveRuleWithActive } from "@/services/masters"
import { useProfile } from "@/hooks/useProfile"

const TYPES = ["service_income", "sales_income", "review", "finder_credit", "installation"] as const

/**
 * v2.2 (Design Deltas #42): incentive rates are entirely admin-set here —
 * no hardcoded % or ₹ default anywhere in the app.
 */
export function IncentiveRulesTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: rows, isLoading, isError, refetch } = incentiveRulesHooks.useList(orgId)
  const createMut = incentiveRulesHooks.useCreate()
  const updateMut = incentiveRulesHooks.useUpdate()
  const deleteMut = incentiveRulesHooks.useDelete()

  const fields: CrudFieldDef[] = [
    {
      key: "type",
      label: t("masters.incentives.type"),
      type: "select",
      options: TYPES.map((v) => ({ value: v, label: t(`masters.incentives.types.${v}`) })),
    },
    { key: "threshold", label: t("masters.incentives.threshold"), type: "number", step: "0.01", required: true, min: 0 },
    { key: "amount", label: t("masters.incentives.amount"), type: "number", step: "0.01", required: true, min: 0 },
    {
      key: "is_active",
      label: t("masters.incentives.status"),
      type: "select",
      options: [
        { value: "true", label: t("masters.incentives.active") },
        { value: "false", label: t("masters.incentives.inactive") },
      ],
    },
  ]

  return (
    <EntityCrudTable<IncentiveRuleRow>
      fields={fields}
      rows={rows ?? []}
      getId={(r) => r.id}
      loading={isLoading}
      error={isError ? t("masters.loadFailed") : null}
      onRetry={() => refetch()}
      isMutating={createMut.isPending || updateMut.isPending}
      addLabel={t("masters.incentives.add")}
      emptyMessage={t("masters.incentives.empty")}
      toFormValues={(r) => ({ type: r.type, threshold: String(r.threshold), amount: String(r.amount), is_active: String((r as IncentiveRuleWithActive).is_active ?? true) })}
      columns={[
        { key: "type", header: t("masters.incentives.type"), render: (r) => t(`masters.incentives.types.${r.type}`) },
        { key: "threshold", header: t("masters.incentives.threshold"), render: (r) => `₹${r.threshold}` },
        { key: "amount", header: t("masters.incentives.amount"), render: (r) => `₹${r.amount}` },
        { key: "status", header: t("masters.incentives.status"), render: (r) => ((r as IncentiveRuleWithActive).is_active === false ? t("masters.incentives.inactive") : t("masters.incentives.active")) },
      ]}
      onCreate={(v) =>
        createMut.mutateAsync({
          org_id: orgId!,
          type: v.type as IncentiveRuleRow["type"],
          threshold: Number(v.threshold) || 0,
          amount: Number(v.amount) || 0,
          is_active: v.is_active !== "false",
        } as never)
      }
      onUpdate={(id, v) =>
        updateMut.mutateAsync({
          id,
          patch: { type: v.type as IncentiveRuleRow["type"], threshold: Number(v.threshold) || 0, amount: Number(v.amount) || 0, is_active: v.is_active !== "false" } as never,
        })
      }
      onDelete={(id) => deleteMut.mutateAsync(id)}
    />
  )
}
