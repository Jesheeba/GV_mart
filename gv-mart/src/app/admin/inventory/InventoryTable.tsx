import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { Check, Inbox, Loader2, Minus, Pencil, Plus, TriangleAlert, X } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Skeleton } from "@/components/ui/skeleton"
import { useAdjustStock, useInventoryList, useUpdateThresholds } from "@/hooks/useInventory"
import { useProfile } from "@/hooks/useProfile"
import { cn } from "@/lib/utils"
import type { InventoryListItem, ItemType } from "@/services/inventory"

// Bespoke CSS-grid table (not the shared <DataTable>) — the design's column
// widths are fractional grid tracks (design-template-decoded.html line
// 1179: Item/Brand/Stock/Min/Level/Status), which a real <table> can't
// express; mirrors the grid-div pattern TicketsListPage/SalesListPage use.
const TABLE_GRID_COLS = "grid-cols-[2fr_1fr_0.9fr_0.9fr_1.4fr_1fr]"

type StatusKey = "in" | "low" | "out"

// Colors matched to the design (line 1194 it.stColor/it.stBg). "In stock"
// reuses the same dedicated green SalesBadges.tsx/TicketBadges.tsx already
// use for their "paid"/"warranty" pills (#16855B/#E2F3EA — distinct from the
// --success token, kept literal to stay pixel-faithful); Low/Out reuse the
// --warning/--danger tokens on their established soft literal backgrounds.
const STATUS_STYLE: Record<StatusKey, { text: string; bg: string; bar: string }> = {
  in: { text: "text-[#16855B]", bg: "bg-[#E2F3EA]", bar: "bg-[#16855B]" },
  low: { text: "text-warning", bg: "bg-[#FCF1DF]", bar: "bg-warning" },
  out: { text: "text-danger", bg: "bg-[#FCEAEA]", bar: "bg-danger" },
}

function stockStatus(row: InventoryListItem): StatusKey {
  if (row.stock_qty <= 0) return "out"
  if (row.stock_qty <= row.min_stock) return "low"
  return "in"
}

/**
 * Level-bar fill %: real stock_qty measured against this row's own
 * replenishment target (min_stock + reorder_qty — the level a restock is
 * meant to bring it back up to). The design mock used arbitrary per-row
 * numbers for a static screenshot with no real formula behind them; this is
 * a genuine derivation from real fields so the bar means something instead
 * of being invented.
 */
function stockLevelPct(row: InventoryListItem): number {
  // Build Order C1: max_stock (once set) is the real replenishment ceiling —
  // the same figure the reorder formula now targets — falling back to the
  // old min+reorder approximation for any row without one set yet.
  const target = row.max_stock ?? row.min_stock + row.reorder_qty
  if (target <= 0) return row.stock_qty > 0 ? 100 : 0
  return Math.max(0, Math.min(100, Math.round((row.stock_qty / target) * 100)))
}

export function InventoryTable({ itemType, search }: { itemType: ItemType; search: string }) {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: rows, isLoading, isError, refetch } = useInventoryList(orgId, itemType)
  const updateThresholds = useUpdateThresholds()
  const adjustStock = useAdjustStock()

  const [editingId, setEditingId] = useState<string | null>(null)
  const [minStock, setMinStock] = useState("")
  const [maxStock, setMaxStock] = useState("")
  const [reorderQty, setReorderQty] = useState("")
  const [adjustingId, setAdjustingId] = useState<string | null>(null)
  const [adjustDelta, setAdjustDelta] = useState("")

  const visibleRows = useMemo(() => {
    const q = search.trim().toLowerCase()
    if (!q) return rows ?? []
    return (rows ?? []).filter(
      (r) => r.itemName.toLowerCase().includes(q) || (r.itemBrand ?? "").toLowerCase().includes(q)
    )
  }, [rows, search])

  function startEdit(row: InventoryListItem) {
    setEditingId(row.id)
    setMinStock(String(row.min_stock))
    setMaxStock(row.max_stock != null ? String(row.max_stock) : "")
    setReorderQty(String(row.reorder_qty))
  }
  function saveEdit(id: string) {
    updateThresholds.mutate(
      {
        id,
        patch: {
          min_stock: Number(minStock) || 0,
          // Build Order C1: reorder qty = max_stock − current stock, so an
          // explicit max is what actually drives ordering now — blank clears
          // it back to the min_stock+reorder_qty fallback the trigger uses.
          max_stock: maxStock.trim() === "" ? null : Number(maxStock) || 0,
          reorder_qty: Number(reorderQty) || 0,
        },
      },
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

  const headers = [
    t("inventory.item"),
    t("inventory.brand"),
    t("inventory.stock"),
    t("inventory.min"),
    t("inventory.level"),
    t("inventory.status.label"),
  ]

  return (
    <div>
      <div className={cn("grid items-center border-t border-b border-border bg-surface-alt px-5.5 py-2.5", TABLE_GRID_COLS)}>
        {headers.map((h) => (
          <span key={h} className="text-[11px] font-semibold uppercase tracking-wide text-text-muted">
            {h}
          </span>
        ))}
      </div>

      {isError ? (
        <div className="flex flex-col items-center gap-3 py-12 text-center">
          <TriangleAlert className="size-6 text-danger" />
          <p className="text-sm text-text-muted">{t("inventory.loadFailed")}</p>
          <Button variant="outline" size="sm" onClick={() => refetch()}>
            {t("common.retry")}
          </Button>
        </div>
      ) : isLoading ? (
        Array.from({ length: 6 }).map((_, i) => (
          <div key={i} className={cn("grid items-center border-b border-[#F1EDE6] px-5.5 py-3.5", TABLE_GRID_COLS)}>
            {headers.map((h) => (
              <Skeleton key={h} className="h-4 w-3/4 max-w-32" />
            ))}
          </div>
        ))
      ) : visibleRows.length === 0 ? (
        <div className="flex flex-col items-center gap-2 py-12 text-center">
          <Inbox className="size-6 text-text-muted" />
          <p className="text-sm text-text-muted">{t("inventory.empty")}</p>
        </div>
      ) : (
        visibleRows.map((r) => {
          const status = stockStatus(r)
          const style = STATUS_STYLE[status]
          const pct = stockLevelPct(r)
          return (
            <div
              key={r.id}
              className={cn("grid items-center border-b border-[#F1EDE6] px-5.5 py-3.5 last:border-b-0 hover:bg-[#FAF8F4]", TABLE_GRID_COLS)}
            >
              <span className="truncate pr-2 text-[13px] font-semibold text-text">{r.itemName}</span>
              <span className="truncate pr-2 text-[13px] font-medium text-[#3A3A36]">{r.itemBrand ?? "—"}</span>

              {adjustingId === r.id ? (
                <div className="flex flex-wrap items-center gap-1">
                  <span className="text-[13px] font-bold tabular-nums text-text">{r.stock_qty}</span>
                  <Input
                    className="h-7 w-12 px-1.5 text-xs"
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
                <div className="flex items-center gap-1">
                  <span className="text-[13px] font-bold tabular-nums text-text">{r.stock_qty}</span>
                  <Button size="icon-xs" variant="ghost" title={t("inventory.adjustStock")} onClick={() => setAdjustingId(r.id)}>
                    <Plus className="size-3 text-text-muted" />
                    <Minus className="-ml-1.5 size-3 text-text-muted" />
                  </Button>
                </div>
              )}

              {editingId === r.id ? (
                // Spans the Min + Level tracks (col 4-5) — the level bar isn't
                // meaningful mid-edit, so it's suppressed below for this row
                // to give the two threshold inputs room without wrapping.
                <div className="col-span-2 flex items-center gap-1 pr-4">
                  <Input className="h-7 w-11 px-1 text-xs" type="number" value={minStock} onChange={(e) => setMinStock(e.target.value)} title={t("inventory.min")} />
                  <span className="text-xs text-text-muted">/</span>
                  <Input className="h-7 w-11 px-1 text-xs" type="number" value={maxStock} onChange={(e) => setMaxStock(e.target.value)} title={t("inventory.max")} placeholder={t("inventory.max")} />
                  <span className="text-xs text-text-muted">/</span>
                  <Input className="h-7 w-11 px-1 text-xs" type="number" value={reorderQty} onChange={(e) => setReorderQty(e.target.value)} title={t("inventory.thresholds")} />
                  <Button size="icon-xs" variant="ghost" onClick={() => saveEdit(r.id)} disabled={updateThresholds.isPending}>
                    {updateThresholds.isPending ? <Loader2 className="size-3 animate-spin" /> : <Check className="size-3.5 text-success" />}
                  </Button>
                  <Button size="icon-xs" variant="ghost" onClick={() => setEditingId(null)}>
                    <X className="size-3.5 text-text-muted" />
                  </Button>
                </div>
              ) : (
                <>
                  <div className="flex items-center gap-1">
                    <span className="text-[13px] font-medium tabular-nums text-text-muted">
                      {r.min_stock}
                      {r.max_stock != null ? <span className="text-text-muted/60">/{r.max_stock}</span> : null}
                    </span>
                    <Button size="icon-xs" variant="ghost" title={t("inventory.thresholds")} onClick={() => startEdit(r)}>
                      <Pencil className="size-3" />
                    </Button>
                  </div>

                  <span className="pr-4.5">
                    <span className="block h-1.5 overflow-hidden rounded-full bg-[#F0EBE3]">
                      <span className={cn("block h-full rounded-full", style.bar)} style={{ width: `${pct}%` }} />
                    </span>
                  </span>
                </>
              )}

              <span>
                <span className={cn("w-fit rounded-full px-2.5 py-1 text-[11px] font-bold", style.text, style.bg)}>
                  {t(`inventory.status.${status}`)}
                </span>
              </span>
            </div>
          )
        })
      )}
    </div>
  )
}
