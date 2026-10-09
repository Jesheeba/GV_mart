import { useTranslation } from "react-i18next"
import { EntityCrudTable, type CrudFieldDef } from "@/components/shared/EntityCrudTable"
import { StatusDot } from "@/components/shared/StatusDot"
import { leadKindsHooks } from "@/hooks/useMasters"
import { leadKindInUse, type LeadKindRow } from "@/services/masters"
import { useProfile } from "@/hooks/useProfile"
import { leadSourceKeyFromLabel } from "@/lib/lead-sources"
import { leadKindLabel } from "@/lib/lead-lists"

/**
 * Lead kinds master (batch 17): the options behind the Kind dropdown on New
 * Lead and the Kind filters on Leads / Daily Follow Up. Service, Spare, Product
 * and AMC are built-in (code keys off them) so they can be turned off but not
 * deleted; anything else (e.g. Warranty) is custom, label-only, and can be
 * deleted only while no lead uses it — otherwise mark it Inactive. The key is
 * slugged from the English label at creation and never changes.
 */
export function LeadKindsTab() {
  const { t, i18n } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: rows, isLoading, isError, refetch } = leadKindsHooks.useList(orgId)
  const createMut = leadKindsHooks.useCreate()
  const updateMut = leadKindsHooks.useUpdate()
  const deleteMut = leadKindsHooks.useDelete()

  const fields: CrudFieldDef[] = [
    { key: "label", label: t("masters.leadKinds.label"), type: "text", placeholder: t("masters.leadKinds.labelPlaceholder"), required: true },
    { key: "label_ta", label: t("masters.leadKinds.labelTa"), type: "text", placeholder: t("masters.leadKinds.labelTaPlaceholder") },
    {
      key: "is_active",
      label: t("masters.leadKinds.status"),
      type: "select",
      options: [
        { value: "true", label: t("masters.leadKinds.active") },
        { value: "false", label: t("masters.leadKinds.inactive") },
      ],
    },
  ]

  const existing = rows ?? []

  return (
    <div className="space-y-3">
      <p className="px-1 text-xs text-text-muted">{t("masters.leadKinds.hint")}</p>
      <EntityCrudTable<LeadKindRow>
        fields={fields}
        rows={existing}
        getId={(r) => r.id}
        loading={isLoading}
        error={isError ? t("masters.loadFailed") : null}
        onRetry={() => refetch()}
        isMutating={createMut.isPending || updateMut.isPending}
        addLabel={t("masters.leadKinds.add")}
        emptyMessage={t("masters.leadKinds.empty")}
        toFormValues={(r) => ({ label: leadKindLabel(r.key, existing, t, i18n.language), label_ta: r.label_ta ?? "", is_active: String(r.is_active) })}
        columns={[
          { key: "label", header: t("masters.leadKinds.label"), render: (r) => <span className="font-medium text-text">{leadKindLabel(r.key, existing, t, i18n.language)}</span> },
          { key: "type", header: t("masters.leadKinds.type"), render: (r) => (r.is_system ? t("masters.leadKinds.builtIn") : t("masters.leadKinds.custom")) },
          {
            key: "status",
            header: t("masters.leadKinds.status"),
            render: (r) => <StatusDot tone={r.is_active ? "success" : "neutral"} label={r.is_active ? t("masters.leadKinds.active") : t("masters.leadKinds.inactive")} />,
          },
        ]}
        onCreate={async (v) => {
          const key = leadSourceKeyFromLabel(v.label)
          if (!key) throw new Error(t("masters.leadKinds.invalidLabel"))
          if (existing.some((r) => r.key === key)) throw new Error(t("masters.leadKinds.duplicate"))
          return createMut.mutateAsync({ org_id: orgId!, key, label: v.label.trim(), label_ta: v.label_ta?.trim() || null, is_active: v.is_active !== "false" })
        }}
        onUpdate={(id, v) =>
          updateMut.mutateAsync({
            id,
            patch: {
              ...(existing.find((r) => r.id === id)?.is_system ? {} : { label: v.label.trim(), label_ta: v.label_ta?.trim() || null }),
              is_active: v.is_active !== "false",
            },
          })
        }
        onDelete={(id) => deleteMut.mutateAsync(id)}
        checkCanDelete={async (id) => {
          const row = existing.find((r) => r.id === id)
          if (!row || row.is_system) return false
          return !(await leadKindInUse(orgId!, row.key))
        }}
        cannotDeleteMessage={t("masters.leadKinds.cannotDelete")}
      />
    </div>
  )
}
