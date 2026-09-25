import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { Banknote, Loader2, PackageCheck, Plus, Search } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { StatusDot, type StatusTone } from "@/components/shared/StatusDot"
import { useProfile } from "@/hooks/useProfile"
import { useSuppliersList } from "@/hooks/useSuppliers"
import { useCreatePurchaseOrder, useMarkPoPaid, usePoItems, usePurchaseOrders } from "@/hooks/useAutomation"
import { PoItemRows } from "./PoItemRows"
import { PoReceiptForm } from "./PoReceiptForm"
import type { PoItemInput } from "@/lib/validation/automation"
import type { PurchaseOrderListItem } from "@/services/automation"

// money-flow-audit item 2 — 'paid' is a real, queryable settlement state
// now (20260925100000_po_paid_status_enum.sql), not just the cosmetic
// payment-reminder task.
const STATUS_TONE: Record<string, StatusTone> = { draft: "neutral", sent: "warning", received: "success", paid: "success" }

export function PurchaseOrdersTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const pos = usePurchaseOrders(orgId)
  const { data: suppliers } = useSuppliersList(orgId)
  const createPo = useCreatePurchaseOrder()
  const markPaid = useMarkPoPaid()
  const isMaster = profile?.role === "master"

  const [showNew, setShowNew] = useState(false)
  const [supplierId, setSupplierId] = useState("")
  const [items, setItems] = useState<PoItemInput[]>([{ itemType: "spare", itemId: "", qty: 1, price: 0 }])
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
    await createPo.mutateAsync({ orgId: orgId!, supplierId, items: items.filter((i) => i.itemId && i.qty > 0) })
    setShowNew(false)
    setSupplierId("")
    setItems([{ itemType: "spare", itemId: "", qty: 1, price: 0 }])
  }

  const columns: DataTableColumn<PurchaseOrderListItem>[] = [
    { key: "supplier", header: t("purchase.po.supplier"), render: (r) => r.suppliers?.name ?? "—" },
    { key: "total", header: t("purchase.po.total"), render: (r) => `₹${r.total.toLocaleString("en-IN")}` },
    { key: "channel", header: t("purchase.po.channel"), render: (r) => r.sent_channel ?? "—" },
    { key: "status", header: t("purchase.po.status"), render: (r) => <StatusDot tone={STATUS_TONE[r.status] ?? "neutral"} label={t(`purchase.po.statuses.${r.status}`)} /> },
    { key: "created", header: t("purchase.po.created"), render: (r) => new Date(r.created_at).toLocaleDateString("en-IN") },
    {
      key: "actions",
      header: "",
      className: "text-right",
      render: (r) => (
        <div className="flex justify-end gap-2">
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
          {isMaster && (r.status === "sent" || r.status === "received") ? (
            <Button
              size="sm"
              variant="outline"
              disabled={markPaid.isPending}
              onClick={(e) => {
                e.stopPropagation()
                markPaid.mutate({ poId: r.id })
              }}
            >
              {markPaid.isPending ? <Loader2 className="size-3.5 animate-spin" /> : <Banknote className="size-3.5" />}
              {t("purchase.po.markPaid")}
            </Button>
          ) : null}
        </div>
      ),
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
              {(suppliers ?? []).map((s) => (
                <option key={s.id} value={s.id}>
                  {s.name}
                </option>
              ))}
            </select>
          </div>
          <PoItemRows orgId={orgId} items={items} onChange={setItems} />
          {createPo.error ? <p className="rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{(createPo.error as Error).message}</p> : null}
          <div className="flex justify-end">
            <Button onClick={submit} disabled={!supplierId || items.every((i) => !i.itemId) || createPo.isPending}>
              {createPo.isPending ? <Loader2 className="size-4 animate-spin" /> : t("purchase.po.send")}
            </Button>
          </div>
        </Card>
      ) : null}

      {markPaid.error ? <p className="rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{(markPaid.error as Error).message}</p> : null}

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
