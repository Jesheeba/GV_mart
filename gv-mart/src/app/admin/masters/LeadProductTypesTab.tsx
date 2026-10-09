import { useTranslation } from "react-i18next"
import { EntityCrudTable, type CrudFieldDef } from "@/components/shared/EntityCrudTable"
import { StatusDot } from "@/components/shared/StatusDot"
import { leadProductTypesHooks } from "@/hooks/useMasters"
import { leadProductTypeInUse, type LeadProductTypeRow } from "@/services/masters"
import { useProfile } from "@/hooks/useProfile"
import { leadSourceKeyFromLabel } from "@/lib/lead-sources"
import { leadProductTypeLabel } from "@/lib/lead-lists"

/**
 * Lead product types master (batch 17): the options behind the Product type dropdown on New
 * Lead. RO, AC, Inverter
 * and Battery are built-in (code keys off them) so they can be turned off but not
 * deleted; anything else (e.g. Multigrade) is custom, label-only, and can be
 * deleted only while no lead uses it — otherwise mark it Inactive. The key is
 * slugged from the English label at creation and never changes.
 */
export function LeadProductTypesTab() {
  const { t, i18n } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: rows, isLoading, isError, refetch } = leadProductTypesHooks.useList(orgId)
  const createMut = leadProductTypesHooks.useCreate()
  const updateMut = leadProductTypesHooks.useUpdate()
  const deleteMut = leadProductTypesHooks.useDelete()

  const fields: CrudFieldDef[] = [
    { key: "label", label: t("masters.leadProductTypes.label"), type: "text", placeholder: t("masters.leadProductTypes.labelPlaceholder"), required: true },
    { key: "label_ta", label: t("masters.leadProductTypes.labelTa"), type: "text", placeholder: t("masters.leadProductTypes.labelTaPlaceholder") },
    {
      key: "is_active",
      label: t("masters.leadProductTypes.status"),
      type: "select",
      options: [
        { value: "true", label: t("masters.leadProductTypes.active") },
        { value: "false", label: t("masters.leadProductTypes.inactive") },
      ],
    },
  ]

  const existing = rows ?? []

  return (
    <div className="space-y-3">
      <p className="px-1 text-xs text-text-muted">{t("masters.leadProductTypes.hint")}</p>
      <EntityCrudTable<LeadProductTypeRow>
        fields={fields}
        rows={existing}
        getId={(r) => r.id}
        loading={isLoading}
        error={isError ? t("masters.loadFailed") : null}
        onRetry={() => refetch()}
        isMutating={createMut.isPending || updateMut.isPending}
        addLabel={t("masters.leadProductTypes.add")}
        emptyMessage={t("masters.leadProductTypes.empty")}
        toFormValues={(r) => ({ label: leadProductTypeLabel(r.key, existing, t, i18n.language), label_ta: r.label_ta ?? "", is_active: String(r.is_active) })}
        columns={[
          { key: "label", header: t("masters.leadProductTypes.label"), render: (r) => <span className="font-medium text-text">{leadProductTypeLabel(r.key, existing, t, i18n.language)}</span> },
          { key: "type", header: t("masters.leadProductTypes.type"), render: (r) => (r.is_system ? t("masters.leadProductTypes.builtIn") : t("masters.leadProductTypes.custom")) },
          {
            key: "status",
            header: t("masters.leadProductTypes.status"),
            render: (r) => <StatusDot tone={r.is_active ? "success" : "neutral"} label={r.is_active ? t("masters.leadProductTypes.active") : t("masters.leadProductTypes.inactive")} />,
          },
        ]}
        onCreate={async (v) => {
          const key = leadSourceKeyFromLabel(v.label)
          if (!key) throw new Error(t("masters.leadProductTypes.invalidLabel"))
          if (existing.some((r) => r.key === key)) throw new Error(t("masters.leadProductTypes.duplicate"))
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
          return !(await leadProductTypeInUse(orgId!, row.key))
        }}
        cannotDeleteMessage={t("masters.leadProductTypes.cannotDelete")}
      />
    </div>
  )
}
