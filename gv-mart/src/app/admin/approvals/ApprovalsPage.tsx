import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { CheckSquare } from "lucide-react"
import { Card } from "@/components/ui/card"
import { useToast } from "@/components/ui/toast-context"
import { useProfile } from "@/hooks/useProfile"
import { useApprovals, useApprovePurchaseOrder, useDecideApproval } from "@/hooks/useSystemPages"
import type { ApprovalListItem } from "@/services/systemPages"
import { ApprovalRow } from "./ApprovalRow"

const TYPE_OPTIONS = ["discount", "po", "price_override", "leave"] as const
const STATUS_OPTIONS = ["pending", "approved", "rejected"] as const

export function ApprovalsPage() {
  const { t } = useTranslation()
  const { toast } = useToast()
  const { data: profile } = useProfile()
  const [type, setType] = useState("")
  const [status, setStatus] = useState("")

  const filters = useMemo(() => ({ type: type || undefined, status: status || undefined }), [type, status])
  const { data, isLoading, isError, refetch } = useApprovals(profile?.org_id, filters)
  const decide = useDecideApproval()
  const approvePo = useApprovePurchaseOrder()

  function handleDecide(approval: ApprovalListItem, next: "approved" | "rejected") {
    if (!profile) return
    // C2: approving a PO must actually release the draft purchase order —
    // the generic decideApproval is only a status flip with no side effects.
    // Rejecting a PO stays on the generic path: the PO simply stays 'draft'.
    if (approval.type === "po" && next === "approved") {
      approvePo.mutate(approval.id, { onError: () => toast.error(t("common.actionFailed")) })
      return
    }
    decide.mutate({ id: approval.id, approverId: profile.id, status: next }, { onError: () => toast.error(t("common.actionFailed")) })
  }

  return (
    <div className="space-y-4 pt-2">
      <div>
        <h1 className="text-2xl font-bold text-text">{t("nav.approvals")}</h1>
        <p className="text-sm text-text-muted">{t("approvals.subtitle")}</p>
      </div>

      <Card size="sm" className="flex-row flex-wrap items-center gap-2 px-4">
        <div className="space-y-1">
          <label className="block text-xs font-medium text-text-muted">{t("approvals.filters.type")}</label>
          <select value={type} onChange={(e) => setType(e.target.value)} className="h-9 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none">
            <option value="">{t("approvals.filters.all")}</option>
            {TYPE_OPTIONS.map((o) => (
              <option key={o} value={o}>
                {t(`approvals.type.${o}`)}
              </option>
            ))}
          </select>
        </div>
        <div className="space-y-1">
          <label className="block text-xs font-medium text-text-muted">{t("approvals.filters.status")}</label>
          <select value={status} onChange={(e) => setStatus(e.target.value)} className="h-9 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none">
            <option value="">{t("approvals.filters.all")}</option>
            {STATUS_OPTIONS.map((o) => (
              <option key={o} value={o}>
                {t(`approvals.status.${o}`)}
              </option>
            ))}
          </select>
        </div>
      </Card>

      {isError ? (
        <Card className="items-center gap-2 py-8 text-center">
          <p className="text-sm text-danger">{t("approvals.loadFailed")}</p>
          <button type="button" className="text-sm text-text underline" onClick={() => refetch()}>
            {t("common.retry")}
          </button>
        </Card>
      ) : isLoading ? (
        <Card className="items-center py-8 text-center">
          <p className="text-sm text-text-muted">{t("common.loading")}</p>
        </Card>
      ) : (data?.length ?? 0) === 0 ? (
        <Card className="items-center gap-2 py-10 text-center">
          <CheckSquare className="size-6 text-text-muted" />
          <p className="text-sm text-text-muted">{t("approvals.empty")}</p>
        </Card>
      ) : (
        <div className="space-y-2">
          {data!.map((a) => (
            <ApprovalRow
              key={a.id}
              approval={a}
              onApprove={() => handleDecide(a, "approved")}
              onReject={() => handleDecide(a, "rejected")}
              isMutating={decide.isPending || approvePo.isPending}
            />
          ))}
        </div>
      )}
    </div>
  )
}
