import { useTranslation } from "react-i18next"
import { EntityCrudTable, type CrudFieldDef } from "@/components/shared/EntityCrudTable"
import { StatusDot } from "@/components/shared/StatusDot"
import { leadSourcesHooks } from "@/hooks/useMasters"
import { leadSourceInUse, type LeadSourceRow } from "@/services/masters"
import { useProfile } from "@/hooks/useProfile"
import { leadSourceKeyFromLabel, leadSourceLabel } from "@/lib/lead-sources"

/**
 * Lead sources master (2026-10-05): the options behind the Source dropdown
 * on Leads / New Lead / customer registration. The six built-ins are
 * is_system — code paths key off them — so they can be renamed or turned
 * off but not deleted. Custom sources get a key slugged from the label,
 * fixed at creation so renaming later never orphans existing leads.
 */
export function LeadSourcesTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: rows, isLoading, isError, refetch } = leadSourcesHooks.useList(orgId)
  const createMut = leadSourcesHooks.useCreate()
  const updateMut = leadSourcesHooks.useUpdate()
  const deleteMut = leadSourcesHooks.useDelete()

  const fields: CrudFieldDef[] = [
    { key: "label", label: t("masters.leadSources.label"), type: "text", placeholder: t("masters.leadSources.labelPlaceholder"), required: true },
    {
      key: "is_active",
      label: t("masters.leadSources.status"),
      type: "select",
      options: [
        { value: "true", label: t("masters.leadSources.active") },
        { value: "false", label: t("masters.leadSources.inactive") },
      ],
    },
  ]

  const existing = rows ?? []

  return (
    <div className="space-y-3">
      <p className="px-1 text-xs text-text-muted">{t("masters.leadSources.hint")}</p>
      <EntityCrudTable<LeadSourceRow>
        fields={fields}
        rows={existing}
        getId={(r) => r.id}
        loading={isLoading}
        error={isError ? t("masters.loadFailed") : null}
        onRetry={() => refetch()}
        isMutating={createMut.isPending || updateMut.isPending}
        addLabel={t("masters.leadSources.add")}
        emptyMessage={t("masters.leadSources.empty")}
        toFormValues={(r) => ({ label: leadSourceLabel(r.key, existing, t), is_active: String(r.is_active) })}
        columns={[
          { key: "label", header: t("masters.leadSources.label"), render: (r) => <span className="font-medium text-text">{leadSourceLabel(r.key, existing, t)}</span> },
          {
            key: "type",
            header: t("masters.leadSources.type"),
            render: (r) => (r.is_system ? t("masters.leadSources.builtIn") : t("masters.leadSources.custom")),
          },
          {
            key: "status",
            header: t("masters.leadSources.status"),
            render: (r) => <StatusDot tone={r.is_active ? "success" : "neutral"} label={r.is_active ? t("masters.leadSources.active") : t("masters.leadSources.inactive")} />,
          },
        ]}
        onCreate={async (v) => {
          const key = leadSourceKeyFromLabel(v.label)
          if (!key) throw new Error(t("masters.leadSources.invalidLabel"))
          if (existing.some((r) => r.key === key)) throw new Error(t("masters.leadSources.duplicate"))
          return createMut.mutateAsync({ org_id: orgId!, key, label: v.label.trim(), is_active: v.is_active !== "false" })
        }}
        onUpdate={(id, v) => updateMut.mutateAsync({ id, patch: { ...(existing.find((r) => r.id === id)?.is_system ? {} : { label: v.label.trim() }), is_active: v.is_active !== "false" } })}
        onDelete={(id) => deleteMut.mutateAsync(id)}
        checkCanDelete={async (id) => {
          const row = existing.find((r) => r.id === id)
          if (!row || row.is_system) return false
          return !(await leadSourceInUse(orgId!, row.key))
        }}
        cannotDeleteMessage={t("masters.leadSources.cannotDelete")}
      />
    </div>
  )
}
