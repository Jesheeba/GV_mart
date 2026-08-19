import { useTranslation } from "react-i18next"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { useFailedWhatsappOutbox } from "@/hooks/useAutomation"
import { useProfile } from "@/hooks/useProfile"
import type { WhatsappOutboxRow } from "@/services/automation"

/** Read-only — retries themselves happen automatically in the daily
 * wa-scheduled-tasks pass (see its runFailedSendRetries), not from a
 * button here. This view exists so ops can see what's currently stuck,
 * not to drive the retry directly. */
export function FailedSendsTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: rows, isLoading, isError, refetch } = useFailedWhatsappOutbox(orgId)

  const columns: DataTableColumn<WhatsappOutboxRow>[] = [
    { key: "time", header: t("automation.failedSends.time"), render: (r) => new Date(r.created_at).toLocaleString("en-IN") },
    { key: "to", header: t("automation.failedSends.contact"), render: (r) => r.to_mobile ?? "—" },
    { key: "template", header: t("automation.failedSends.template"), render: (r) => <span className="font-mono text-xs">{r.template}</span> },
    { key: "body", header: t("automation.failedSends.body"), render: (r) => <span className="line-clamp-1 max-w-70 text-xs text-text-muted">{(r.payload as { body?: string })?.body ?? "—"}</span> },
    { key: "error", header: t("automation.failedSends.error"), render: (r) => <span className="text-xs text-danger">{r.error ?? "—"}</span> },
  ]

  return (
    <div className="space-y-3">
      <p className="text-xs text-text-muted">{t("automation.failedSends.hint")}</p>
      <DataTable
        columns={columns}
        rows={rows ?? []}
        rowKey={(r) => r.id}
        loading={isLoading}
        error={isError ? t("automation.loadFailed") : null}
        onRetry={() => refetch()}
        emptyMessage={t("automation.failedSends.empty")}
      />
    </div>
  )
}
