import { useEffect, useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useProfile } from "@/hooks/useProfile"
import { useConfirmPoReceipt, usePoItems, usePurchaseOrders } from "@/hooks/useAutomation"
import type { PurchaseOrderListItem } from "@/services/automation"

/**
 * Shared receipt-confirmation form — used both by the shell-mounted
 * PoReceiptPromptModal (notification-driven) and by the plain "Confirm
 * Receipt" button on any `status='sent'` row in PurchaseOrdersTab (admin-
 * initiated any time). Received qty defaults to ordered qty but is
 * editable per line, matching GV's "let the admin change the purchase
 * order quantity according to what they received" requirement.
 */
export function PoReceiptForm({ po, onDone }: { po: PurchaseOrderListItem; onDone: () => void }) {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const poItems = usePoItems(po.id)
  const confirmReceipt = useConfirmPoReceipt()

  const [receivedQty, setReceivedQty] = useState<Record<string, string>>({})
  const [gst, setGst] = useState("0")
  useEffect(() => {
    const next: Record<string, string> = {}
    for (const item of poItems.data ?? []) next[item.id] = String(item.qty)
    setReceivedQty(next)
  }, [poItems.data])

  async function submit() {
    if (!profile?.org_id) return
    const items = (poItems.data ?? [])
      .map((item) => ({ itemType: item.item_type, itemId: item.item_id, qty: Number(receivedQty[item.id] ?? item.qty), price: Number(item.price) }))
      .filter((i) => Number.isFinite(i.qty) && i.qty > 0)
    await confirmReceipt.mutateAsync({ orgId: profile.org_id, supplierId: po.supplier_id, poId: po.id, items, gst: Number(gst) || 0 })
    onDone()
  }

  const busy = confirmReceipt.isPending || poItems.isLoading

  return (
    <div className="space-y-3">
      <div className="max-h-64 overflow-y-auto rounded-xl border border-border">
        <table className="w-full text-sm text-text">
          <thead className="bg-surface-alt text-xs uppercase text-text-muted">
            <tr>
              <th className="px-3 py-2 text-left font-medium">{t("purchase.items.item")}</th>
              <th className="px-3 py-2 text-right font-medium">{t("purchase.receiptPrompt.ordered")}</th>
              <th className="px-3 py-2 text-right font-medium">{t("purchase.receiptPrompt.received")}</th>
            </tr>
          </thead>
          <tbody>
            {poItems.isLoading ? (
              <tr>
                <td colSpan={3} className="px-3 py-4 text-center text-xs text-text-muted">
                  {t("common.loading")}
                </td>
              </tr>
            ) : null}
            {(poItems.data ?? []).map((item) => (
              <tr key={item.id} className="border-t border-border">
                <td className="px-3 py-2">{item.products?.name ?? item.spares?.name ?? item.gifts?.name ?? "—"}</td>
                <td className="px-3 py-2 text-right text-text-muted">{item.qty}</td>
                <td className="px-3 py-2 text-right">
                  <Input
                    type="number"
                    min={0}
                    step="1"
                    className="ml-auto h-8 w-20 text-right"
                    value={receivedQty[item.id] ?? ""}
                    onChange={(e) => setReceivedQty((prev) => ({ ...prev, [item.id]: e.target.value }))}
                  />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="w-32 space-y-1.5">
        <Label>{t("purchase.bill.gst")}</Label>
        <Input type="number" min={0} step="0.01" value={gst} onChange={(e) => setGst(e.target.value)} />
      </div>

      {confirmReceipt.isError ? <p className="text-xs text-danger">{(confirmReceipt.error as Error).message}</p> : null}

      <div className="flex justify-end">
        <Button type="button" disabled={busy} onClick={submit}>
          {confirmReceipt.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("purchase.receiptPrompt.confirm")}
        </Button>
      </div>
    </div>
  )
}

/** Convenience for callers that only have a poId (the shell-mounted modal,
 * which learns about a PO via a notification's ref_id) — resolves it
 * against the already-fetched purchase orders list rather than adding a
 * single-PO fetch just for this. */
export function usePurchaseOrderById(orgId: string | undefined, poId: string | undefined) {
  const pos = usePurchaseOrders(orgId)
  return { data: (pos.data ?? []).find((p) => p.id === poId) ?? null, isLoading: pos.isLoading }
}
