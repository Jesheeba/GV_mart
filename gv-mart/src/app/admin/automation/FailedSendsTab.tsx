import { useEffect, useState } from "react"
import { useTranslation } from "react-i18next"
import { AlertTriangle } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { useToast } from "@/components/ui/toast-context"
import { useSettings, useUpdateSettings } from "@/hooks/useMasters"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { useFailedWhatsappOutbox, useWaDispatchAlertCounts } from "@/hooks/useAutomation"
import { useProfile } from "@/hooks/useProfile"
import type { WhatsappOutboxRow } from "@/services/automation"

/** Why a row is on this list, in words ops can act on (dispatcher v2 states). */
function stateLabelKey(r: WhatsappOutboxRow): string {
  if (r.status === "skipped_no_template") return "automation.failedSends.stateSkipped"
  if (r.status === "pending") return "automation.failedSends.stateStuck"
  if (r.delivery_status === "failed") return "automation.failedSends.stateDeliveryFailed"
  return "automation.failedSends.stateFailed"
}

/** Read-only — retries themselves happen automatically in the daily
 * wa-scheduled-tasks pass (see its runFailedSendRetries), not from a
 * button here. This view exists so ops can see what's currently stuck,
 * not to drive the retry directly. */
export function FailedSendsTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: rows, isLoading, isError, refetch } = useFailedWhatsappOutbox(orgId)
  const { toast } = useToast()
  const { data: counts } = useWaDispatchAlertCounts(orgId)
  const { data: settings } = useSettings(orgId)
  const updateMut = useUpdateSettings(orgId)
  const isMaster = profile?.role === "master"
  const [thresholdText, setThresholdText] = useState("")
  useEffect(() => {
    if (settings) setThresholdText(String(settings.wa_skipped_alert_threshold ?? 10))
  }, [settings])
  const threshold = counts?.threshold ?? 10
  const stuckAlert = (counts?.stuck ?? 0) > 0
  const skippedAlert = threshold > 0 && (counts?.skippedToday ?? 0) > threshold
  const thresholdValid = /^\d{1,4}$/.test(thresholdText.trim())

  const columns: DataTableColumn<WhatsappOutboxRow>[] = [
    { key: "time", header: t("automation.failedSends.time"), render: (r) => new Date(r.created_at).toLocaleString("en-IN") },
    { key: "to", header: t("automation.failedSends.contact"), render: (r) => r.to_mobile ?? "—" },
    { key: "template", header: t("automation.failedSends.template"), render: (r) => <span className="font-mono text-xs">{r.template}</span> },
    { key: "body", header: t("automation.failedSends.body"), render: (r) => <span className="line-clamp-1 max-w-70 text-xs text-text-muted">{(r.payload as { body?: string })?.body ?? "—"}</span> },
    { key: "state", header: t("automation.failedSends.state"), render: (r) => <span className="text-xs">{t(stateLabelKey(r))}</span> },
    { key: "error", header: t("automation.failedSends.error"), render: (r) => <span className="text-xs text-danger">{r.error ?? "—"}</span> },
  ]

  return (
    <div className="space-y-3">
      {stuckAlert && (
        <div role="alert" className="flex items-start gap-2 rounded-xl border border-danger/30 bg-danger/10 p-3 text-sm text-danger">
          <AlertTriangle className="mt-0.5 size-4 shrink-0" />
          <span>{t("automation.failedSends.alertStuck", { count: counts?.stuck ?? 0 })}</span>
        </div>
      )}
      {skippedAlert && (
        <div role="alert" className="flex items-start gap-2 rounded-xl border border-warning/30 bg-warning/10 p-3 text-sm text-warning">
          <AlertTriangle className="mt-0.5 size-4 shrink-0" />
          <span>{t("automation.failedSends.alertSkipped", { count: counts?.skippedToday ?? 0, threshold })}</span>
        </div>
      )}
      {isMaster && settings && (
        <div className="flex flex-wrap items-end gap-2">
          <label className="space-y-1 text-xs text-text-muted">
            <span className="block">{t("automation.failedSends.thresholdLabel")}</span>
            <Input inputMode="numeric" value={thresholdText} onChange={(e) => setThresholdText(e.target.value)} className="h-9 w-28" />
          </label>
          <Button
            size="sm"
            variant="outline"
            disabled={!thresholdValid || updateMut.isPending || Number(thresholdText) === (settings.wa_skipped_alert_threshold ?? 10)}
            onClick={() =>
              updateMut.mutate(
                { wa_skipped_alert_threshold: Number(thresholdText) },
                { onSuccess: () => toast.success(t("automation.failedSends.thresholdSaved")), onError: (e) => toast.error(e instanceof Error ? e.message : t("automation.failedSends.thresholdFailed")) }
              )
            }
          >
            {t("common.save")}
          </Button>
          <span className="pb-2 text-xs text-text-muted">{t("automation.failedSends.thresholdHint")}</span>
        </div>
      )}
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
