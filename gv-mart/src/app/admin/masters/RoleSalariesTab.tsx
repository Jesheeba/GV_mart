import { useTranslation } from "react-i18next"
import { EntityCrudTable, type CrudFieldDef } from "@/components/shared/EntityCrudTable"
import { roleBaseSalariesHooks } from "@/hooks/useMasters"
import type { RoleBaseSalaryRow } from "@/services/masters"
import { useProfile } from "@/hooks/useProfile"
import { formatCurrency } from "@/lib/sale-calc"

/** Base salary per non-technician staff role — entirely master-set, no
 * hardcoded ₹ anywhere. Technicians are deliberately not here:
 * technician_tiers stays their sole source of base pay. Staff are linked to a
 * row via profiles.staff_role_key (set on the HR > Staff Salary tab). */
export function RoleSalariesTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: rows, isLoading, isError, refetch } = roleBaseSalariesHooks.useList(orgId)
  const createMut = roleBaseSalariesHooks.useCreate()
  const updateMut = roleBaseSalariesHooks.useUpdate()
  const deleteMut = roleBaseSalariesHooks.useDelete()

  const fields: CrudFieldDef[] = [
    { key: "label", label: t("masters.roleSalaries.label"), type: "text", required: true },
    { key: "role_key", label: t("masters.roleSalaries.roleKey"), type: "text", required: true },
    { key: "monthly_base", label: t("masters.roleSalaries.monthlyBase"), type: "number", step: "0.01", required: true, min: 0 },
  ]

  const norm = (v: string) => v.trim().toLowerCase().replace(/[\s-]+/g, "_")

  return (
    <div className="space-y-3">
      <p className="text-xs text-text-muted">{t("masters.roleSalaries.subtitle")}</p>
      <EntityCrudTable<RoleBaseSalaryRow>
        fields={fields}
        rows={rows ?? []}
        getId={(r) => r.id}
        loading={isLoading}
        error={isError ? t("masters.loadFailed") : null}
        onRetry={() => refetch()}
        isMutating={createMut.isPending || updateMut.isPending}
        addLabel={t("masters.roleSalaries.add")}
        emptyMessage={t("masters.roleSalaries.empty")}
        toFormValues={(r) => ({ label: r.label, role_key: r.role_key, monthly_base: String(r.monthly_base) })}
        columns={[
          { key: "label", header: t("masters.roleSalaries.label"), render: (r) => r.label },
          { key: "role_key", header: t("masters.roleSalaries.roleKey"), render: (r) => r.role_key },
          { key: "monthly_base", header: t("masters.roleSalaries.monthlyBase"), render: (r) => formatCurrency(r.monthly_base) },
        ]}
        onCreate={(v) =>
          createMut.mutateAsync({
            org_id: orgId!,
            label: v.label.trim(),
            role_key: norm(v.role_key),
            monthly_base: Number(v.monthly_base) || 0,
          })
        }
        onUpdate={(id, v) =>
          updateMut.mutateAsync({
            id,
            patch: { label: v.label.trim(), role_key: norm(v.role_key), monthly_base: Number(v.monthly_base) || 0 },
          })
        }
        onDelete={(id) => deleteMut.mutateAsync(id)}
      />
    </div>
  )
}
