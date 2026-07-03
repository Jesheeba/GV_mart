import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2, Plus } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { StatusDot, type StatusTone } from "@/components/shared/StatusDot"
import { useProfile } from "@/hooks/useProfile"
import { useSuppliersList } from "@/hooks/useSuppliers"
import { useCreatePurchaseOrder, usePoItems, usePurchaseOrders } from "@/hooks/useAutomation"
import { PoItemRows } from "./PoItemRows"
import type { PoItemInput } from "@/lib/validation/automation"
import type { PurchaseOrderListItem } from "@/services/automation"

const STATUS_TONE: Record<string, StatusTone> = { draft: "neutral", sent: "warning", received: "success" }

export function PurchaseOrdersTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const pos = usePurchaseOrders(orgId)
  const { data: suppliers } = useSuppliersList(orgId)
  const createPo = useCreatePurchaseOrder()

  const [showNew, setShowNew] = useState(false)
  const [supplierId, setSupplierId] = useState("")
  const [items, setItems] = useState<PoItemInput[]>([{ itemType: "spare", itemId: "", qty: 1, price: 0 }])
  const [expandedId, setExpandedId] = useState<string | null>(null)
  const poItems = usePoItems(expandedId ?? undefined)

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
  ]

  return (
    <div className="space-y-4">
      <div className="flex justify-end">
        <Button variant="accent" size="sm" onClick={() => setShowNew((v) => !v)}>
          <Plus className="size-3.5" />
          {t("purchase.po.create")}
        </Button>
      </div>

      {showNew ? (
        <Card className="gap-3">
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

      <DataTable
        columns={columns}
        rows={pos.data ?? []}
        rowKey={(r) => r.id}
        loading={pos.isLoading}
        error={pos.isError ? t("purchase.loadFailed") : null}
        onRetry={() => pos.refetch()}
        onRowClick={(r) => setExpandedId(expandedId === r.id ? null : r.id)}
        emptyMessage={t("purchase.po.empty")}
      />

      {expandedId ? (
        <Card className="gap-2">
          <h3 className="text-sm font-semibold text-text">{t("purchase.po.items")}</h3>
          {poItems.isLoading ? (
            <p className="text-xs text-text-muted">{t("common.loading")}</p>
          ) : (
            <ul className="space-y-1 text-sm text-text">
              {(poItems.data ?? []).map((i) => (
                <li key={i.id} className="flex justify-between border-b border-border py-1.5 last:border-0">
                  <span>{i.products?.name ?? i.spares?.name ?? "—"}</span>
                  <span className="text-text-muted">
                    {i.qty} × ₹{i.price}
                  </span>
                </li>
              ))}
            </ul>
          )}
        </Card>
      ) : null}
    </div>
  )
}
