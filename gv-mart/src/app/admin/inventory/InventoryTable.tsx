import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Check, Loader2, Minus, Pencil, Plus, X } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { StatusDot, type StatusTone } from "@/components/shared/StatusDot"
import { useAdjustStock, useInventoryList, useUpdateThresholds } from "@/hooks/useInventory"
import { useProfile } from "@/hooks/useProfile"
import type { InventoryListItem, ItemType } from "@/services/inventory"

function stockStatus(row: InventoryListItem): { tone: StatusTone; labelKey: string } {
  if (row.stock_qty <= 0) return { tone: "danger", labelKey: "inventory.status.out" }
  if (row.stock_qty <= row.min_stock) return { tone: "warning", labelKey: "inventory.status.low" }
  return { tone: "success", labelKey: "inventory.status.in" }
}

export function InventoryTable({ itemType }: { itemType: ItemType }) {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: rows, isLoading, isError, refetch } = useInventoryList(orgId, itemType)
  const updateThresholds = useUpdateThresholds()
  const adjustStock = useAdjustStock()

  const [editingId, setEditingId] = useState<string | null>(null)
  const [minStock, setMinStock] = useState("")
  const [reorderQty, setReorderQty] = useState("")
  const [adjustingId, setAdjustingId] = useState<string | null>(null)
  const [adjustDelta, setAdjustDelta] = useState("")

  function startEdit(row: InventoryListItem) {
    setEditingId(row.id)
    setMinStock(String(row.min_stock))
    setReorderQty(String(row.reorder_qty))
  }
  function saveEdit(id: string) {
    updateThresholds.mutate(
      { id, patch: { min_stock: Number(minStock) || 0, reorder_qty: Number(reorderQty) || 0 } },
      { onSuccess: () => setEditingId(null) }
    )
  }

  function applyAdjust(row: InventoryListItem) {
    const delta = Number(adjustDelta)
    if (!delta) return
    adjustStock.mutate(
      { orgId: orgId!, inventoryId: row.id, itemType: row.item_type, itemId: row.item_id, delta, reason: "manual_adjustment" },
      { onSuccess: () => { setAdjustingId(null); setAdjustDelta("") } }
    )
  }

  const columns: DataTableColumn<InventoryListItem>[] = [
    {
      key: "item",
      header: t("inventory.item"),
      render: (r) => (
        <div>
          <div className="font-medium text-text">{r.itemName}</div>
          {r.itemBrand ? <div className="text-xs text-text-muted">{r.itemBrand}</div> : null}
        </div>
      ),
    },
    {
      key: "stock",
      header: t("inventory.stock"),
      render: (r) =>
        adjustingId === r.id ? (
          <div className="flex items-center gap-1">
            <span className="tabular-nums">{r.stock_qty}</span>
            <Input
              className="h-8 w-16"
              type="number"
              placeholder="±"
              value={adjustDelta}
              onChange={(e) => setAdjustDelta(e.target.value)}
            />
            <Button size="icon-xs" variant="ghost" onClick={() => applyAdjust(r)} disabled={adjustStock.isPending}>
              {adjustStock.isPending ? <Loader2 className="size-3 animate-spin" /> : <Check className="size-3.5 text-success" />}
            </Button>
            <Button size="icon-xs" variant="ghost" onClick={() => { setAdjustingId(null); setAdjustDelta("") }}>
              <X className="size-3.5 text-text-muted" />
            </Button>
          </div>
        ) : (
          <div className="flex items-center gap-1.5">
            <span className="tabular-nums">{r.stock_qty}</span>
            <Button size="icon-xs" variant="ghost" title={t("inventory.adjustStock")} onClick={() => setAdjustingId(r.id)}>
              <Plus className="size-3 text-text-muted" />
              <Minus className="-ml-1.5 size-3 text-text-muted" />
            </Button>
          </div>
        ),
    },
    {
      key: "thresholds",
      header: t("inventory.thresholds"),
      render: (r) =>
        editingId === r.id ? (
          <div className="flex items-center gap-1">
            <Input className="h-8 w-16" type="number" value={minStock} onChange={(e) => setMinStock(e.target.value)} />
            <span className="text-text-muted">/</span>
            <Input className="h-8 w-16" type="number" value={reorderQty} onChange={(e) => setReorderQty(e.target.value)} />
            <Button size="icon-xs" variant="ghost" onClick={() => saveEdit(r.id)} disabled={updateThresholds.isPending}>
              {updateThresholds.isPending ? <Loader2 className="size-3 animate-spin" /> : <Check className="size-3.5 text-success" />}
            </Button>
            <Button size="icon-xs" variant="ghost" onClick={() => setEditingId(null)}>
              <X className="size-3.5 text-text-muted" />
            </Button>
          </div>
        ) : (
          <div className="flex items-center gap-1.5">
            <span className="tabular-nums text-text-muted">
              {t("inventory.minReorder", { min: r.min_stock, reorder: r.reorder_qty })}
            </span>
            <Button size="icon-xs" variant="ghost" title={t("masters.edit")} onClick={() => startEdit(r)}>
              <Pencil className="size-3.5" />
            </Button>
          </div>
        ),
    },
    {
      key: "status",
      header: t("inventory.status.label"),
      render: (r) => {
        const s = stockStatus(r)
        return <StatusDot tone={s.tone} label={t(s.labelKey)} />
      },
    },
  ]

  return (
    <DataTable
      columns={columns}
      rows={rows ?? []}
      rowKey={(r) => r.id}
      loading={isLoading}
      error={isError ? t("inventory.loadFailed") : null}
      onRetry={() => refetch()}
      emptyMessage={t("inventory.empty")}
    />
  )
}
