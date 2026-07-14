import { useTranslation } from "react-i18next"
import { EntityCrudTable, type CrudFieldDef } from "@/components/shared/EntityCrudTable"
import { useAutomationFlows, useCreateAutomationFlow, useDeleteAutomationFlow, useUpdateAutomationFlow } from "@/hooks/useAutomation"
import { useProfile } from "@/hooks/useProfile"
import type { AutomationFlowRow } from "@/services/automation"

const TRIGGERS = ["online", "price", "quality", "customization", "water_premium", "budget"] as const
const ACTIONS = ["send_video", "quotation", "link"] as const

/** ADM-23 flow builder: trigger (enquiry_type) → action, mapped against the
 * video library. No drag-drop canvas — this codebase's CRUD-table pattern
 * (EntityCrudTable) covers the APPEARS-tier "visual rule builder" as a
 * simple rule list, matching how Incentive Rules/AMC Plans are edited. */
export function AutomationFlowsTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: rows, isLoading, isError, refetch } = useAutomationFlows(orgId)
  const createMut = useCreateAutomationFlow()
  const updateMut = useUpdateAutomationFlow()
  const deleteMut = useDeleteAutomationFlow()

  const fields: CrudFieldDef[] = [
    { key: "trigger", label: t("automation.flows.trigger"), type: "select", options: TRIGGERS.map((v) => ({ value: v, label: t(`leads.enquiryType.${v}`) })) },
    { key: "action", label: t("automation.flows.action"), type: "select", options: ACTIONS.map((v) => ({ value: v, label: t(`automation.flows.actions.${v}`) })) },
    { key: "asset_url", label: t("automation.flows.assetUrl"), type: "text" },
    { key: "is_active", label: t("automation.flows.active"), type: "select", options: [{ value: "true", label: t("common.yes") }, { value: "false", label: t("common.no") }] },
  ]

  return (
    <EntityCrudTable<AutomationFlowRow>
      fields={fields}
      rows={rows ?? []}
      getId={(r) => r.id}
      loading={isLoading}
      error={isError ? t("automation.loadFailed") : null}
      onRetry={() => refetch()}
      isMutating={createMut.isPending || updateMut.isPending}
      addLabel={t("automation.flows.add")}
      emptyMessage={t("automation.flows.empty")}
      toFormValues={(r) => ({ trigger: r.trigger, action: r.action, asset_url: r.asset_url ?? "", is_active: String(r.is_active) })}
      columns={[
        { key: "trigger", header: t("automation.flows.trigger"), render: (r) => t(`leads.enquiryType.${r.trigger}`) },
        { key: "action", header: t("automation.flows.action"), render: (r) => t(`automation.flows.actions.${r.action}`) },
        { key: "asset_url", header: t("automation.flows.assetUrl"), render: (r) => r.asset_url || "—" },
        { key: "is_active", header: t("automation.flows.active"), render: (r) => (r.is_active ? t("common.yes") : t("common.no")) },
      ]}
      onCreate={(v) =>
        createMut.mutateAsync({
          org_id: orgId!,
          trigger: v.trigger as AutomationFlowRow["trigger"],
          action: v.action as AutomationFlowRow["action"],
          asset_url: v.asset_url || null,
          is_active: v.is_active === "true",
        })
      }
      onUpdate={(id, v) =>
        updateMut.mutateAsync({
          id,
          patch: { trigger: v.trigger as AutomationFlowRow["trigger"], action: v.action as AutomationFlowRow["action"], asset_url: v.asset_url || null, is_active: v.is_active === "true" },
        })
      }
      onDelete={(id) => deleteMut.mutateAsync(id)}
    />
  )
}
