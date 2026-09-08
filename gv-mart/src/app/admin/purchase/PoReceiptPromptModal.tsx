import { useEffect, useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { useQueryClient } from "@tanstack/react-query"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import { supabase } from "@/lib/supabase"
import { useAllMyNotifications, useMarkAllNotificationsRead } from "@/hooks/useSystemPages"
import { PoReceiptForm, usePurchaseOrderById } from "./PoReceiptForm"

type NotificationRow = { type: string; role: string | null }
type ApprovalRole = "master" | "operation_admin"

/**
 * Receipt-confirmation red popup (Supplier Monthly RFQ pipeline, Phase 4).
 * Same shape as PoApprovalPromptModal: realtime + on-load fallback,
 * blocking (showClose={false}). Visibility is gated on BOTH the
 * notification's unread state AND `purchase_orders.status === 'sent'` —
 * the PO status is the real source of truth (resolved through ANY path,
 * including the pre-existing manual Bill Entry flow, closes this), the
 * notification is just what triggers the on-load/realtime check. "Not yet"
 * hides this viewer's copy for the rest of the session without touching
 * anything server-side — it reopens on the next matching realtime signal
 * or via the manual "Confirm Receipt" button in PurchaseOrdersTab.
 */
export function PoReceiptPromptModal({
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

  const notifs = useAllMyNotifications(isEligibleRole ? orgId : undefined, userId, isEligibleRole ? role : undefined, {
    type: "po_receipt_check_prompt",
    readStatus: "unread",
  })
  const markAllRead = useMarkAllNotificationsRead()
  const [dismissedIds, setDismissedIds] = useState<Set<string>>(new Set())

  const candidates = useMemo(() => (notifs.data ?? []).filter((n) => !dismissedIds.has(n.id)), [notifs.data, dismissedIds])
  const current = useMemo(() => {
    if (candidates.length === 0) return null
    return [...candidates].sort((a, b) => new Date(a.created_at).getTime() - new Date(b.created_at).getTime())[0]
  }, [candidates])

  const { data: po } = usePurchaseOrderById(orgId, current?.ref_id ?? undefined)

  useEffect(() => {
    if (!orgId || !isEligibleRole) return
    const channel = supabase
      .channel(`po-receipt-prompt-${role}-${orgId}`)
      .on(
        "postgres_changes",
        { event: "INSERT", schema: "public", table: "notifications", filter: `role=eq.${role}` },
        (payload) => {
          const row = payload.new as NotificationRow
          if (row.type !== "po_receipt_check_prompt") return
          qc.invalidateQueries({ queryKey: ["notifications"] })
        }
      )
      .on("postgres_changes", { event: "UPDATE", schema: "public", table: "purchase_orders", filter: `org_id=eq.${orgId}` }, () => {
        qc.invalidateQueries({ queryKey: ["purchaseOrders"] })
      })
      .subscribe()

    return () => {
      supabase.removeChannel(channel)
    }
  }, [orgId, role, isEligibleRole, qc])

  // The PO already flipped away from 'sent' (this viewer confirmed it, another
  // admin did, or it was resolved through the pre-existing manual Bill Entry
  // flow) — nothing left to ask about, regardless of this notification's own
  // read-state (see migration comment on why the other role's copy of the
  // notification can't always be marked read from here).
  if (!isEligibleRole || !current || !po || po.status !== "sent") return null

  function handleNotYet() {
    setDismissedIds((prev) => new Set(prev).add(current!.id))
  }

  async function handleDone() {
    // Mark every unread po_receipt_check_prompt row for this PO, not just
    // this viewer's own — 20260804190000's RLS lets a master clear both
    // roles' copies (operation_admin can only ever clear their own; the
    // master row stays unread for them, a pre-existing asymmetry this
    // reuses rather than works around). purchase_orders.status flipping is
    // still the real "resolved" signal either way (see component comment).
    const { data: rows } = await supabase.from("notifications").select("id").eq("org_id", orgId!).eq("type", "po_receipt_check_prompt").eq("ref_id", po!.id).eq("is_read", false)
    if (rows?.length) markAllRead.mutate(rows.map((r) => r.id))
  }

  return (
    <Dialog open onOpenChange={() => {}}>
      <DialogContent showClose={false} className="max-w-lg">
        <DialogTitle>{t("purchase.receiptPrompt.title")}</DialogTitle>
        <DialogDescription>{t("purchase.receiptPrompt.body", { supplier: po.suppliers?.name ?? "—" })}</DialogDescription>

        <PoReceiptForm po={po} onDone={handleDone} />

        <Button type="button" variant="ghost" size="sm" onClick={handleNotYet}>
          {t("purchase.receiptPrompt.notYet")}
        </Button>
      </DialogContent>
    </Dialog>
  )
}
