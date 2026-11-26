import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { Banknote, Loader2, PackageCheck, Plus, Search, Undo2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { StatusDot, type StatusTone } from "@/components/shared/StatusDot"
import { useProfile } from "@/hooks/useProfile"
import { useSuppliersList } from "@/hooks/useSuppliers"
import { useCreatePurchaseOrder, useMarkPoPaid, usePoItems, usePurchaseOrders, useUnmarkPoPaid } from "@/hooks/useAutomation"
import { PoItemRows } from "./PoItemRows"
import { SupplierQuickAdd } from "./SupplierQuickAdd"
import { PoReceiptForm } from "./PoReceiptForm"
import { createPurchaseOrderSchema, emptyPoItem, isCompletePoItem, type PoItemDraft } from "@/lib/validation/automation"
import { lineShortfall, poPaymentActions } from "@/lib/purchase"
import type { PurchaseOrderListItem } from "@/services/automation"
import { formatDate } from "@/lib/formatDate"

// Status is delivery only; payment is paid_at (20261231100000_vendor_flow_fixes.sql). Legacy
// "paid" rows were backfilled to sent/received + paid_at, the key stays for safety.
const STATUS_TONE: Record<string, StatusTone> = { draft: "neutral", sent: "warning", received: "success", paid: "success", cancelled: "danger" }

export function PurchaseOrdersTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const pos = usePurchaseOrders(orgId)
  const { data: suppliers } = useSuppliersList(orgId)
  const createPo = useCreatePurchaseOrder()
  const markPaid = useMarkPoPaid()
  const unmarkPaid = useUnmarkPoPaid()
  const [confirmPayId, setConfirmPayId] = useState<string | null>(null)
  const [formError, setFormError] = useState<string | null>(null)
  const activeSuppliers = (suppliers ?? []).filter((s) => s.is_active)
  const isMaster = profile?.role === "master"

  const [showNew, setShowNew] = useState(false)
  const [supplierId, setSupplierId] = useState("")
  const [items, setItems] = useState<PoItemDraft[]>([emptyPoItem()])
  const [expandedId, setExpandedId] = useState<string | null>(null)
  const poItems = usePoItems(expandedId ?? undefined)
  const [receiptPo, setReceiptPo] = useState<PurchaseOrderListItem | null>(null)
  const [search, setSearch] = useState("")
  const searchTerm = search.trim().toLowerCase()
  const filteredPos = useMemo(
    () => (pos.data ?? []).filter((r) => !searchTerm || (r.suppliers?.name ?? "").toLowerCase().includes(searchTerm)),
    [pos.data, searchTerm]
  )

  async function submit() {
    const parsed = createPurchaseOrderSchema.safeParse({ supplierId, items: items.filter(isCompletePoItem) })
    if (!parsed.success) {
      setFormError(t(parsed.error.issues[0].message))
      return
    }
    setFormError(null)
    await createPo.mutateAsync({ orgId: orgId!, supplierId, items: parsed.data.items })
    setShowNew(false)
    setSupplierId("")
    setItems([emptyPoItem()])
  }

  const columns: DataTableColumn<PurchaseOrderListItem>[] = [
    { key: "supplier", header: t("purchase.po.supplier"), render: (r) => r.suppliers?.name ?? "—" },
    { key: "total", header: t("purchase.po.total"), render: (r) => `₹${r.total.toLocaleString("en-IN")}` },
    { key: "channel", header: t("purchase.po.channel"), render: (r) => r.sent_channel ?? "—" },
    {
      key: "status",
      header: t("purchase.po.status"),
      render: (r) => (
        <div className="flex flex-col gap-0.5">
          <StatusDot tone={STATUS_TONE[r.status] ?? "neutral"} label={t(r.status === "draft" ? "purchase.po.awaitingApproval" : `purchase.po.statuses.${r.status}`)} />
          {r.paid_at ? <span className="text-xs text-success">{t("purchase.po.paidOn", { date: formatDate(r.paid_at) })}</span> : null}
        </div>
      ),
    },
    { key: "created", header: t("purchase.po.created"), render: (r) => formatDate(r.created_at) },
    {
      key: "actions",
      header: "",
      className: "text-right",
      render: (r) => {
        const pay = poPaymentActions(r, isMaster)
        return (
        <div className="flex flex-wrap justify-end gap-2">
          {r.status === "sent" ? (
            <Button
              size="sm"
              variant="outline"
              onClick={(e) => {
                e.stopPropagation()
                setReceiptPo(r)
              }}
            >
              <PackageCheck className="size-3.5" />
              {t("purchase.receiptPrompt.confirmReceiptButton")}
            </Button>
          ) : null}
          {pay.canMarkPaid && confirmPayId !== r.id ? (
            <Button
              size="sm"
              variant="outline"
              onClick={(e) => {
                e.stopPropagation()
                setConfirmPayId(r.id)
              }}
            >
              <Banknote className="size-3.5" />
              {t("purchase.po.markPaid")}
            </Button>
          ) : null}
          {pay.canMarkPaid && confirmPayId === r.id ? (
            <span className="flex items-center gap-2 text-xs" onClick={(e) => e.stopPropagation()}>
              {t("purchase.po.confirmPaid", { total: r.total.toLocaleString("en-IN") })}
              <Button
                size="sm"
                disabled={markPaid.isPending && markPaid.variables?.poId === r.id}
                onClick={() => markPaid.mutate({ poId: r.id }, { onSettled: () => setConfirmPayId(null) })}
              >
                {markPaid.isPending && markPaid.variables?.poId === r.id ? <Loader2 className="size-3.5 animate-spin" /> : t("purchase.po.confirmPaidYes")}
              </Button>
              <Button size="sm" variant="ghost" onClick={() => setConfirmPayId(null)}>
                {t("common.cancel")}
              </Button>
            </span>
          ) : null}
          {pay.canUndoPaid ? (
            <Button
              size="sm"
              variant="ghost"
              disabled={unmarkPaid.isPending && unmarkPaid.variables?.poId === r.id}
              onClick={(e) => {
                e.stopPropagation()
                unmarkPaid.mutate({ poId: r.id })
              }}
            >
              {unmarkPaid.isPending && unmarkPaid.variables?.poId === r.id ? <Loader2 className="size-3.5 animate-spin" /> : <Undo2 className="size-3.5" />}
              {t("purchase.po.undoPaid")}
            </Button>
          ) : null}
        </div>
        )
      },
    },
  ]

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex w-64 items-center gap-2.25 rounded-full border border-border bg-surface-alt px-3.5 py-2">
          <Search className="size-3.75 shrink-0 text-text-muted" />
          <input
            type="text"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder={t("purchase.po.search")}
            className="w-full bg-transparent text-xs font-medium text-text outline-none placeholder:text-text-muted"
          />
        </div>
        <Button variant="accent" size="sm" onClick={() => setShowNew((v) => !v)}>
          <Plus className="size-3.5" />
          {t("purchase.po.create")}
        </Button>
      </div>

      {showNew ? (
        <Card className="gap-3 px-5">
          <div className="space-y-1.5">
            <label className="text-sm font-medium text-text">{t("purchase.po.supplier")}</label>
            <select
              value={supplierId}
              onChange={(e) => setSupplierId(e.target.value)}
              className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
            >
              <option value="">{t("purchase.items.selectItem")}</option>
              {activeSuppliers.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.name}
                </option>
              ))}
            </select>
            <SupplierQuickAdd orgId={orgId} onAdded={setSupplierId} />
          </div>
          <PoItemRows orgId={orgId} items={items} onChange={setItems} />
          {formError ? <p className="rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{formError}</p> : null}
          {createPo.error ? <p className="rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{(createPo.error as Error).message}</p> : null}
          <div className="flex justify-end">
            <Button onClick={submit} disabled={!supplierId || items.every((i) => !i.itemId) || createPo.isPending}>
              {createPo.isPending ? <Loader2 className="size-4 animate-spin" /> : t("purchase.po.send")}
            </Button>
          </div>
        </Card>
      ) : null}

      {markPaid.error ? <p className="rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{(markPaid.error as Error).message}</p> : null}
      {unmarkPaid.error ? <p className="rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{(unmarkPaid.error as Error).message}</p> : null}

      <DataTable
        columns={columns}
        rows={filteredPos}
        rowKey={(r) => r.id}
        loading={pos.isLoading}
        error={pos.isError ? t("purchase.loadFailed") : null}
        onRetry={() => pos.refetch()}
        onRowClick={(r) => setExpandedId(expandedId === r.id ? null : r.id)}
        emptyMessage={t("purchase.po.empty")}
      />

      {expandedId ? (
        <Card className="gap-2 px-5">
          <h3 className="text-sm font-semibold text-text">{t("purchase.po.items")}</h3>
          {poItems.isLoading ? (
            <p className="text-xs text-text-muted">{t("common.loading")}</p>
          ) : (
            <ul className="space-y-1 text-sm text-text">
              {(poItems.data ?? []).map((i) => (
                <li key={i.id} className="flex justify-between border-b border-border py-1.5 last:border-0">
                  <span>{i.products?.name ?? i.spares?.name ?? i.gifts?.name ?? "—"}</span>
                  <span className="text-text-muted">
                    {i.qty} × ₹{i.price}
                    {i.received_qty != null ? (
                      <span className={lineShortfall(i) > 0 ? "ml-2 font-medium text-danger" : "ml-2 text-success"}>
                        {t("purchase.po.receivedOf", { received: i.received_qty, qty: i.qty })}
                      </span>
                    ) : null}
                  </span>
                </li>
              ))}
            </ul>
          )}
        </Card>
      ) : null}

      <Dialog open={!!receiptPo} onOpenChange={(open) => !open && setReceiptPo(null)}>
        <DialogContent className="max-w-lg">
          {receiptPo ? (
            <>
              <DialogTitle>{t("purchase.receiptPrompt.title")}</DialogTitle>
              <DialogDescription>{t("purchase.receiptPrompt.body", { supplier: receiptPo.suppliers?.name ?? "—" })}</DialogDescription>
              <PoReceiptForm po={receiptPo} onDone={() => setReceiptPo(null)} />
            </>
          ) : null}
        </DialogContent>
      </Dialog>
    </div>
  )
}
