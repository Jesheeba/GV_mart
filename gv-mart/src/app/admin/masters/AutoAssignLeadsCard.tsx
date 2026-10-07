import { useTranslation } from "react-i18next"
import { Loader2 } from "lucide-react"
import { Card } from "@/components/ui/card"
import { useToast } from "@/components/ui/toast-context"
import { useProfile } from "@/hooks/useProfile"
import { useLeadAssignState, useSetAutoAssignLeads } from "@/hooks/useLeadAssignment"

/** Master-only "Auto-assign new leads" switch (ships OFF) plus the waiting-leads count. */
export function AutoAssignLeadsCard() {
  const { t } = useTranslation()
  const { toast } = useToast()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id
  const isMaster = profile?.role === "master"
  const { data: state } = useLeadAssignState(orgId, isMaster)
  const setMut = useSetAutoAssignLeads(orgId)

  if (!isMaster || !state) return null

  return (
    <Card className="gap-3">
      <h3 className="px-1 text-sm font-semibold text-text">{t("leadAssign.title")}</h3>
      <label className="mx-1 flex items-center gap-2.5 rounded-xl border border-border bg-surface-alt px-3.5 py-2.5 text-sm text-text">
        <input
          type="checkbox"
          className="size-4 accent-accent"
          checked={state.enabled}
          disabled={setMut.isPending}
          onChange={(e) =>
            setMut.mutate(e.target.checked, { onError: (err) => toast.error(err instanceof Error ? err.message : t("leadAssign.saveFailed")) })
          }
        />
        <span className="flex-1">
          <span className="block font-medium">{state.enabled ? t("leadAssign.on") : t("leadAssign.off")}</span>
          <span className="block text-xs text-text-muted">{t("leadAssign.hint")}</span>
        </span>
        {setMut.isPending ? <Loader2 className="size-4 animate-spin text-text-muted" /> : null}
      </label>
      {!state.enabled ? <p className="px-1 text-xs text-text-muted">{t("leadAssign.offNote")}</p> : null}
      {state.enabled && state.receivers === 0 ? <p className="px-1 text-xs text-warning">{t("leadAssign.noReceivers")}</p> : null}
      {state.waiting > 0 ? (
        <p className="px-1 text-sm text-text">
          {t("leadAssign.waitingCount", { count: state.waiting })} <span className="text-xs text-text-muted">{t("leadAssign.waitingHint")}</span>
        </p>
      ) : null}
    </Card>
  )
}
