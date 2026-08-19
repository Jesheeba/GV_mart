import { useTranslation } from "react-i18next"
import { EntityCrudTable, type CrudFieldDef } from "@/components/shared/EntityCrudTable"
import { Badge } from "@/components/ui/badge"
import { useCreateWhatsappTemplate, useDeleteWhatsappTemplate, useUpdateWhatsappTemplate, useWhatsappTemplates } from "@/hooks/useAutomation"
import { useProfile } from "@/hooks/useProfile"
import type { WhatsappTemplateRow } from "@/services/automation"

const CATEGORIES = ["utility", "marketing"] as const
const APPROVAL_STATUSES = ["pending", "approved", "rejected"] as const
const APPROVAL_BADGE_VARIANT: Record<string, "success" | "warning" | "danger"> = { approved: "success", pending: "warning", rejected: "danger" }

function safeParseVariableMap(raw: string): Record<string, string> {
  if (!raw.trim()) return {}
  try {
    const parsed = JSON.parse(raw)
    return typeof parsed === "object" && parsed !== null ? parsed : {}
  } catch {
    return {}
  }
}

/** Phase 3's whatsapp_templates manager — the body every milestone trigger
 * (_milestone_ticket_notify etc.) and the wa-scheduled-tasks reminders
 * render through when a row exists for their name (milestone.booked,
 * milestone.assigned, milestone.completed, milestone.on_the_way,
 * milestone.invoice, amc_reminder_30/15/7, feedback_request), falling back
 * to a placeholder when it doesn't — so this list can be built out
 * gradually as templates clear Meta's approval, not all at once. */
export function TemplatesTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: rows, isLoading, isError, refetch } = useWhatsappTemplates(orgId)
  const createMut = useCreateWhatsappTemplate()
  const updateMut = useUpdateWhatsappTemplate()
  const deleteMut = useDeleteWhatsappTemplate()

  const fields: CrudFieldDef[] = [
    { key: "name", label: t("automation.templates.name"), type: "text", required: true, placeholder: t("automation.templates.namePlaceholder") },
    { key: "category", label: t("automation.templates.category"), type: "select", options: CATEGORIES.map((v) => ({ value: v, label: t(`automation.templates.categories.${v}`) })) },
    { key: "approval_status", label: t("automation.templates.approvalStatus"), type: "select", options: APPROVAL_STATUSES.map((v) => ({ value: v, label: t(`automation.templates.approvalStatuses.${v}`) })) },
    { key: "body", label: t("automation.templates.body"), type: "textarea", required: true, placeholder: t("automation.templates.bodyPlaceholder") },
    { key: "variable_map", label: t("automation.templates.variableMap"), type: "textarea", placeholder: t("automation.templates.variableMapPlaceholder") },
  ]

  return (
    <div className="space-y-3">
      <p className="text-xs text-text-muted">{t("automation.templates.hint")}</p>
      <EntityCrudTable<WhatsappTemplateRow>
        fields={fields}
        rows={rows ?? []}
        getId={(r) => r.id}
        loading={isLoading}
        error={isError ? t("automation.loadFailed") : null}
        onRetry={() => refetch()}
        isMutating={createMut.isPending || updateMut.isPending}
        addLabel={t("automation.templates.add")}
        emptyMessage={t("automation.templates.empty")}
        toFormValues={(r) => ({
          name: r.name,
          category: r.category,
          approval_status: r.approval_status,
          body: r.body,
          variable_map: JSON.stringify(r.variable_map ?? {}),
        })}
        columns={[
          { key: "name", header: t("automation.templates.name"), render: (r) => <span className="font-mono text-xs">{r.name}</span> },
          { key: "category", header: t("automation.templates.category"), render: (r) => t(`automation.templates.categories.${r.category}`) },
          {
            key: "approval_status",
            header: t("automation.templates.approvalStatus"),
            render: (r) => (
              <Badge variant={APPROVAL_BADGE_VARIANT[r.approval_status] ?? "secondary"}>{t(`automation.templates.approvalStatuses.${r.approval_status}`)}</Badge>
            ),
          },
          { key: "body", header: t("automation.templates.body"), render: (r) => <span className="line-clamp-1 max-w-70 text-xs text-text-muted">{r.body}</span> },
        ]}
        onCreate={(v) =>
          createMut.mutateAsync({
            org_id: orgId!,
            name: v.name,
            category: v.category,
            approval_status: v.approval_status,
            body: v.body,
            variable_map: safeParseVariableMap(v.variable_map),
          })
        }
        onUpdate={(id, v) =>
          updateMut.mutateAsync({
            id,
            patch: { name: v.name, category: v.category, approval_status: v.approval_status, body: v.body, variable_map: safeParseVariableMap(v.variable_map) },
          })
        }
        onDelete={(id) => deleteMut.mutateAsync(id)}
      />
    </div>
  )
}
