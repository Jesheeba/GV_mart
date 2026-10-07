import { useTranslation } from "react-i18next"
import { Clock } from "lucide-react"
import { useProfile } from "@/hooks/useProfile"
import { useLeadAssignState } from "@/hooks/useLeadAssignment"

/** Master-only: a short count of leads saved unassigned because no sales person was available. Hidden when there are none. */
export function WaitingLeadsBanner() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const isMaster = profile?.role === "master"
  const { data: state } = useLeadAssignState(profile?.org_id, isMaster)
  if (!isMaster || !state || state.waiting === 0) return null
  return (
    <div className="flex items-start gap-2.5 rounded-xl border border-warning/40 bg-warning/10 px-3.5 py-2.5 text-sm text-text" role="status">
      <Clock className="mt-0.5 size-4 shrink-0 text-warning" />
      <span>
        <span className="font-medium">{t("leadAssign.waitingCount", { count: state.waiting })}</span>{" "}
        <span className="text-text-muted">{t("leadAssign.waitingHint")}</span>
      </span>
    </div>
  )
}
