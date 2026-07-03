import { useTranslation } from "react-i18next"
import { Check, X } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { StatusDot, type StatusTone } from "@/components/shared/StatusDot"
import { useResolveApprovalRef } from "@/hooks/useSystemPages"
import type { ApprovalListItem } from "@/services/systemPages"

const STATUS_TONE: Record<string, StatusTone> = { pending: "warning", approved: "success", rejected: "danger" }

export function ApprovalRow({
  approval,
  onApprove,
  onReject,
  isMutating,
}: {
  approval: ApprovalListItem
  onApprove: () => void
  onReject: () => void
  isMutating: boolean
}) {
  const { t } = useTranslation()
  const ref = useResolveApprovalRef(approval.type, approval.ref_id)

  return (
    <Card size="sm" className="flex-row flex-wrap items-center justify-between gap-3">
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2">
          <span className="rounded-full bg-surface-alt px-2 py-0.5 text-xs font-medium text-text">{t(`approvals.type.${approval.type}`)}</span>
          <StatusDot tone={STATUS_TONE[approval.status]} label={t(`approvals.status.${approval.status}`)} />
        </div>
        <p className="mt-1 text-sm text-text">{ref.data ?? approval.ref_id}</p>
        <p className="text-xs text-text-muted">
          {t("approvals.requestedBy")}: {approval.requester?.full_name ?? "—"} · {new Date(approval.created_at).toLocaleString()}
          {approval.approver ? ` · ${t("approvals.decidedBy")}: ${approval.approver.full_name}` : ""}
        </p>
      </div>
      {approval.status === "pending" ? (
        <div className="flex shrink-0 gap-2">
          <Button type="button" size="sm" variant="outline" disabled={isMutating} onClick={onReject}>
            <X className="size-3.5 text-danger" />
            {t("approvals.reject")}
          </Button>
          <Button type="button" size="sm" disabled={isMutating} onClick={onApprove}>
            <Check className="size-3.5" />
            {t("approvals.approve")}
          </Button>
        </div>
      ) : null}
    </Card>
  )
}
