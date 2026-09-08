import { useEffect, useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { useQueryClient } from "@tanstack/react-query"
import { Loader2 } from "lucide-react"
import { supabase } from "@/lib/supabase"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import { useApprovals, useDecideApproval } from "@/hooks/useSystemPages"
import { usePoItems, usePurchaseOrders, useUpdatePoItemsAndApprove } from "@/hooks/useAutomation"

type NotificationRow = { type: string; role: string | null }
type ApprovalRole = "master" | "operation_admin"

/**
 * PO approval red popup (Supplier Monthly RFQ pipeline, Phase 3). Same
 * pattern as ShiftEndPromptModal: realtime + on-load fallback, blocking
 * (showClose={false}, onOpenChange no-op) — but simpler than that one,
 * because a pending `approvals` row's mere existence IS the "still needs a
 * decision" signal (unlike shift_end_prompt_pending, a flag on a row that
 * can persist independent of the notification). So there's no separate
 * `visible` state to track: `visible = current != null`, and the realtime
 * subscription below exists only to make react-query refetch promptly
 * rather than waiting for its own polling.
 *
 * Approval itself stays master-only (approve_purchase_order's existing
 * gate, unchanged — see update_po_items_and_approve's is_master() check).
 * operation_admin still sees this popup (per the approved design: "both
 * can view") but read-only — no qty inputs, no Approve/Reject buttons,
 * just the same PO details and a note that a master needs to act. Their
 * copy closes on its own once anyone resolves it, via the approvals-table
 * realtime subscription below (not something they can dismiss themselves).
 */
export function PoApprovalPromptModal({
  orgId,
  userId,
  role,
}: {
  orgId: string | undefined
  userId: string | undefined
  role: ApprovalRole | "sales_admin" | "technician" | "customer" | undefined
}) {
  const { t } = useTranslation()
  const qc = useQueryClient()
  const isEligibleRole = role === "master" || role === "operation_admin"

  const pending = useApprovals(isEligibleRole ? orgId : undefined, { type: "po", status: "pending" })
  const purchaseOrders = usePurchaseOrders(isEligibleRole ? orgId : undefined)
  const decide = useDecideApproval()
  const approve = useUpdatePoItemsAndApprove()

  // Oldest first (FIFO) — listApprovals itself orders newest-first, which
  // suits the Approvals list page but not "which one do we ask about now".
  const current = useMemo(() => {
    const rows = pending.data ?? []
    if (rows.length === 0) return null
    return [...rows].sort((a, b) => new Date(a.created_at).getTime() - new Date(b.created_at).getTime())[0]
  }, [pending.data])

  const currentPo = useMemo(() => (purchaseOrders.data ?? []).find((po) => po.id === current?.ref_id) ?? null, [purchaseOrders.data, current])
  const poItems = usePoItems(currentPo?.id)

  const [qtyById, setQtyById] = useState<Record<string, string>>({})
  useEffect(() => {
    const next: Record<string, string> = {}
    for (const item of poItems.data ?? []) next[item.id] = String(item.qty)
    setQtyById(next)
  }, [poItems.data])

  // Realtime: both the new po_approval_pending notification (a fresh PO
  // landed) and any approvals UPDATE org-wide (someone — possibly on
  // another device — just decided one) invalidate the same query, so an
  // operation_admin's read-only copy closes itself the moment a master
  // acts, and a master sees a newly-drafted PO without waiting on a poll.
  useEffect(() => {
    if (!orgId || !isEligibleRole) return
    const channel = supabase
      .channel(`po-approval-prompt-${role}-${orgId}`)
      .on(
        "postgres_changes",
        { event: "INSERT", schema: "public", table: "notifications", filter: `role=eq.${role}` },
        (payload) => {
          const row = payload.new as NotificationRow
          if (row.type !== "po_approval_pending") return
          qc.invalidateQueries({ queryKey: ["approvals", "list", orgId, { type: "po", status: "pending" }] })
        }
      )
      .on("postgres_changes", { event: "UPDATE", schema: "public", table: "approvals", filter: `org_id=eq.${orgId}` }, () => {
        qc.invalidateQueries({ queryKey: ["approvals", "list", orgId, { type: "po", status: "pending" }] })
      })
      .subscribe()

    return () => {
      supabase.removeChannel(channel)
    }
  }, [orgId, role, isEligibleRole, qc])

  if (!isEligibleRole || !current || !currentPo) return null

  const grandTotal = (poItems.data ?? []).reduce((sum, item) => {
    const qty = Number(qtyById[item.id] ?? item.qty)
    return sum + (Number.isFinite(qty) ? qty : 0) * Number(item.price)
  }, 0)

  const isMaster = role === "master"
  const busy = approve.isPending || decide.isPending || poItems.isLoading

  function handleApprove() {
    if (!current) return
    const items = Object.entries(qtyById)
      .map(([id, qty]) => ({ id, qty: Number(qty) }))
      .filter((i) => Number.isFinite(i.qty) && i.qty > 0)
    approve.mutate({ approvalId: current.id, items })
  }

  function handleReject() {
    if (!current || !userId) return
    decide.mutate({ id: current.id, approverId: userId, status: "rejected" })
  }

  return (
    <Dialog open onOpenChange={() => {}}>
      <DialogContent showClose={false} className="max-w-lg">
        <DialogTitle>{t("purchase.approvalPrompt.title")}</DialogTitle>
        <DialogDescription>
          {t("purchase.approvalPrompt.body", { supplier: currentPo.suppliers?.name ?? "—" })}
        </DialogDescription>

        {!isMaster ? <p className="rounded-xl bg-warning/10 px-3 py-2 text-sm text-warning">{t("purchase.approvalPrompt.waitingOnMaster")}</p> : null}

        <div className="max-h-64 overflow-y-auto rounded-xl border border-border">
          <table className="w-full text-sm text-text">
            <thead className="bg-surface-alt text-xs uppercase text-text-muted">
              <tr>
                <th className="px-3 py-2 text-left font-medium">{t("purchase.items.item")}</th>
                <th className="px-3 py-2 text-right font-medium">{t("purchase.po.qty")}</th>
                <th className="px-3 py-2 text-right font-medium">{t("purchase.items.price")}</th>
                <th className="px-3 py-2 text-right font-medium">{t("purchase.po.lineTotal")}</th>
              </tr>
            </thead>
            <tbody>
              {poItems.isLoading ? (
                <tr>
                  <td colSpan={4} className="px-3 py-4 text-center text-xs text-text-muted">
                    {t("common.loading")}
                  </td>
                </tr>
              ) : null}
              {(poItems.data ?? []).map((item) => {
                const qty = Number(qtyById[item.id] ?? item.qty)
                const lineTotal = (Number.isFinite(qty) ? qty : 0) * Number(item.price)
                return (
                  <tr key={item.id} className="border-t border-border">
                    <td className="px-3 py-2">{item.products?.name ?? item.spares?.name ?? item.gifts?.name ?? "—"}</td>
                    <td className="px-3 py-2 text-right">
                      {isMaster ? (
                        <Input
                          type="number"
                          min={1}
                          step="1"
                          className="ml-auto h-8 w-20 text-right"
                          value={qtyById[item.id] ?? ""}
                          onChange={(e) => setQtyById((prev) => ({ ...prev, [item.id]: e.target.value }))}
                        />
                      ) : (
                        item.qty
                      )}
                    </td>
                    <td className="px-3 py-2 text-right text-text-muted">₹{Number(item.price).toLocaleString("en-IN")}</td>
                    <td className="px-3 py-2 text-right font-medium">₹{lineTotal.toLocaleString("en-IN")}</td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>

        <div className="flex items-center justify-between px-1 text-sm font-semibold text-text">
          <span>{t("purchase.approvalPrompt.grandTotal")}</span>
          <span>₹{grandTotal.toLocaleString("en-IN")}</span>
        </div>

        {approve.isError ? <p className="text-xs text-danger">{(approve.error as Error).message}</p> : null}
        {decide.isError ? <p className="text-xs text-danger">{(decide.error as Error).message}</p> : null}

        {isMaster ? (
          <div className="mt-1 flex gap-2">
            <Button type="button" variant="outline" className="flex-1" disabled={busy} onClick={handleReject}>
              {decide.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("purchase.approvalPrompt.reject")}
            </Button>
            <Button type="button" className="flex-1" disabled={busy} onClick={handleApprove}>
              {approve.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("purchase.approvalPrompt.approve")}
            </Button>
          </div>
        ) : null}
      </DialogContent>
    </Dialog>
  )
}
