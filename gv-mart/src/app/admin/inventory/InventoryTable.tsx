import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { Check, ClipboardList, Inbox, Loader2, Minus, Pencil, Plus, TriangleAlert, X } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Skeleton } from "@/components/ui/skeleton"
import { useAdjustStock, useInventoryList, useSetItemStandardTime, useUpdateThresholds } from "@/hooks/useInventory"
import { productsHooks } from "@/hooks/useMasters"
import { useProfile } from "@/hooks/useProfile"
import { cn } from "@/lib/utils"
import { ProductComplaintsPanel } from "@/app/admin/masters/ProductComplaintsPanel"
import type { Enums } from "@/types/database"
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
 * replenishment target (max_stock — the level a restock is meant to bring it
 * back up to; also exactly what the auto-PO formula orders up to). The
 * design mock used arbitrary per-row numbers for a static screenshot with no
 * real formula behind them; this is a genuine derivation from real fields so
 * the bar means something instead of being invented.
 */
function stockLevelPct(row: InventoryListItem): number {
  const target = row.max_stock
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
  const setStandardTime = useSetItemStandardTime()

  // Product↔complaints connector (ProductComplaintsPanel.tsx) — only
  // meaningful for itemType === "product" (spares/gifts have no complaint
  // list). InventoryListItem doesn't carry category, so it's resolved here
  // via productsHooks (cheap: same queryKey as ProductsTab.tsx, so it dedupes
  // against that fetch when both are mounted, and is a small table either
  // way) — only fetched at all while the Products tab is active.
  const { data: productsForCategory } = productsHooks.useList(itemType === "product" ? orgId : undefined)
  const categoryById = useMemo(
    () => new Map((productsForCategory ?? []).map((p) => [p.id, p.category as Enums<"brand_category">])),
    [productsForCategory]
  )
  const [complaintsItem, setComplaintsItem] = useState<{ productId: string; category: Enums<"brand_category">; name: string } | null>(null)

  const [editingId, setEditingId] = useState<string | null>(null)
  const [minStock, setMinStock] = useState("")
  const [maxStock, setMaxStock] = useState("")
  const [adjustingId, setAdjustingId] = useState<string | null>(null)
  const [adjustDelta, setAdjustDelta] = useState("")
  // GV.md 1.1: standard time is edited separately from the min/max/reorder
  // thresholds above — different underlying table (products/spares, via the
  // set_item_standard_time RPC) and the only edit path open to
  // operation_admin (ProductsTab/SparesTab under Masters are master-only).
  const [editingTimeId, setEditingTimeId] = useState<string | null>(null)
  const [stdTimeInput, setStdTimeInput] = useState("")

  const visibleRows = useMemo(() => {
    const q = search.trim().toLowerCase()
    if (!q) return rows ?? []
    return (rows ?? []).filter(
      (r) => r.itemName.toLowerCase().includes(q) || (r.itemBrand ?? "").toLowerCase().includes(q)
    )
  }, [rows, search])

  // Out-of-stock gifts never block a sale (see gift_logs_decrement_stock
  // trigger) — this banner is the "flag it to the admin" half of that
  // decision. Derived live from `rows` (unfiltered by search) every render,
  // so — unlike a dismissible notification — it keeps showing for as long
  // as the gift is actually at 0, and clears itself the moment it's
  // restocked, with no separate "seen/dismissed" state to track.
  const outOfStockGifts = itemType === "gift" ? (rows ?? []).filter((r) => r.stock_qty <= 0) : []

  function startEdit(row: InventoryListItem) {
    setEditingId(row.id)
    setMinStock(String(row.min_stock))
    setMaxStock(String(row.max_stock))
  }
  const minStockNum = Number(minStock)
  const maxStockNum = Number(maxStock)
  const thresholdsValid =
    minStock.trim() !== "" &&
    maxStock.trim() !== "" &&
    Number.isFinite(minStockNum) &&
    Number.isFinite(maxStockNum) &&
    minStockNum >= 0 &&
    maxStockNum >= 0

  function saveEdit(id: string) {
    if (!thresholdsValid) return
    updateThresholds.mutate(
      {
        id,
        patch: {
          min_stock: minStockNum,
          // Order qty = max_stock − current stock — max_stock is now the
          // sole, required replenishment target (no more reorder_qty fallback).
          max_stock: maxStockNum,
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

  function startEditTime(row: InventoryListItem) {
    setEditingTimeId(row.id)
    setStdTimeInput(row.standardTimeMinutes != null ? String(row.standardTimeMinutes) : "")
  }
  function saveStandardTime(row: InventoryListItem) {
    const trimmed = stdTimeInput.trim()
    const minutes = trimmed === "" ? null : Number(trimmed)
    if (minutes != null && (!Number.isFinite(minutes) || minutes <= 0)) return
    setStandardTime.mutate(
      { orgId: orgId!, itemType: row.item_type, itemId: row.item_id, minutes },
      { onSuccess: () => setEditingTimeId(null) }
    )
  }

  const headers = [
    t("inventory.item"),
    t("inventory.brand"),
    t("inventory.stock"),
    t("inventory.thresholds"),
    t("inventory.level"),
    t("inventory.status.label"),
  ]

  return (
    <div>
      {outOfStockGifts.length > 0 ? (
        <div className="flex items-center gap-2.5 border-b border-danger/40 bg-danger/5 px-5.5 py-3">
          <TriangleAlert className="size-4 shrink-0 text-danger" />
          <p className="text-xs font-medium text-danger">
            {t("inventory.giftOutOfStockBanner", { names: outOfStockGifts.map((r) => r.itemName).join(", ") })}
          </p>
        </div>
      ) : null}

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
          <div key={i} className={cn("grid items-center border-b border-border px-5.5 py-3.5", TABLE_GRID_COLS)}>
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
              className={cn("grid items-center border-b border-border px-5.5 py-3.5 last:border-b-0 hover:bg-surface-alt", TABLE_GRID_COLS)}
            >
              <div className="min-w-0 pr-2">
                <div className="flex items-center gap-1">
                  <span className="block truncate text-[13px] font-semibold text-text">{r.itemName}</span>
                  {/* Product↔complaints connector (ProductComplaintsPanel.tsx) — products only, spares/gifts have no complaint list. */}
                  {itemType === "product" ? (
                    <Button
                      size="icon-xs"
                      variant="ghost"
                      className="shrink-0"
                      title={t("masters.productComplaints.manage")}
                      disabled={!categoryById.has(r.item_id)}
                      onClick={() => {
                        const category = categoryById.get(r.item_id)
                        if (!category) return
                        setComplaintsItem({ productId: r.item_id, category, name: r.itemName })
                      }}
                    >
                      <ClipboardList className="size-3" />
                    </Button>
                  ) : null}
                </div>
                {/* GV.md 1.1: standard service time, editable here by master AND operation_admin (unlike Masters > Products/Spares, which is master-only) — see set_item_standard_time RPC. Gifts have no service duration of their own (set_item_standard_time only covers products/spares) so this control is skipped entirely for them. */}
                {itemType === "gift" ? null : editingTimeId === r.id ? (
                  <div className="mt-0.5 flex items-center gap-1">
                    <Input
                      className="h-6 w-14 px-1.5 text-[11px]"
                      type="number"
                      min={1}
                      placeholder={t("inventory.standardTimePlaceholder")}
                      value={stdTimeInput}
                      onChange={(e) => setStdTimeInput(e.target.value)}
                    />
                    <span className="text-[10px] text-text-muted">{t("inventory.min")}</span>
                    <Button size="icon-xs" variant="ghost" title={t("common.save")} onClick={() => saveStandardTime(r)} disabled={setStandardTime.isPending}>
                      {setStandardTime.isPending ? <Loader2 className="size-3 animate-spin" /> : <Check className="size-3 text-success" />}
                    </Button>
                    <Button size="icon-xs" variant="ghost" title={t("common.cancel")} onClick={() => setEditingTimeId(null)}>
                      <X className="size-3 text-text-muted" />
                    </Button>
                  </div>
                ) : (
                  <button type="button" onClick={() => startEditTime(r)} className="mt-0.5 flex items-center gap-1 text-[11px] text-text-muted hover:text-accent">
                    {r.standardTimeMinutes != null ? t("inventory.standardTimeValue", { minutes: r.standardTimeMinutes }) : t("inventory.standardTimeNotSet")}
                    <Pencil className="size-2.5" />
                  </button>
                )}
              </div>
              <span className="truncate pr-2 text-[13px] font-medium text-text-muted">{r.itemBrand ?? "—"}</span>

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
                  <Button size="icon-xs" variant="ghost" title={t("common.save")} onClick={() => applyAdjust(r)} disabled={adjustStock.isPending}>
                    {adjustStock.isPending ? <Loader2 className="size-3 animate-spin" /> : <Check className="size-3.5 text-success" />}
                  </Button>
                  <Button size="icon-xs" variant="ghost" title={t("common.cancel")} onClick={() => { setAdjustingId(null); setAdjustDelta("") }}>
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
                <div className="col-span-2 flex flex-col gap-0.5 pr-4">
                  <div className="flex items-center gap-1">
                    <Input className="h-7 w-11 px-1 text-xs" type="number" min={0} step="1" value={minStock} onChange={(e) => setMinStock(e.target.value)} title={t("inventory.min")} />
                    <span className="text-xs text-text-muted">/</span>
                    <Input className="h-7 w-11 px-1 text-xs" type="number" min={0} step="1" value={maxStock} onChange={(e) => setMaxStock(e.target.value)} title={t("inventory.max")} placeholder={t("inventory.max")} />
                    <Button size="icon-xs" variant="ghost" title={t("common.save")} onClick={() => saveEdit(r.id)} disabled={updateThresholds.isPending || !thresholdsValid}>
                      {updateThresholds.isPending ? <Loader2 className="size-3 animate-spin" /> : <Check className="size-3.5 text-success" />}
                    </Button>
                    <Button size="icon-xs" variant="ghost" title={t("common.cancel")} onClick={() => setEditingId(null)}>
                      <X className="size-3.5 text-text-muted" />
                    </Button>
                  </div>
                  {updateThresholds.isError && editingId === r.id ? (
                    <p className="text-[10px] text-danger">{(updateThresholds.error as Error).message}</p>
                  ) : null}
                </div>
              ) : (
                <>
                  <div className="flex items-center gap-1">
                    <span className="text-[13px] font-medium tabular-nums text-text-muted">
                      {r.min_stock}
                      <span className="text-text-muted/60">/{r.max_stock}</span>
                    </span>
                    <Button size="icon-xs" variant="ghost" title={t("inventory.thresholds")} onClick={() => startEdit(r)}>
                      <Pencil className="size-3" />
                    </Button>
                  </div>

                  <span className="pr-4.5">
                    <span className="block h-1.5 overflow-hidden rounded-full bg-surface-alt">
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

      {complaintsItem ? (
        <ProductComplaintsPanel
          key={complaintsItem.productId}
          orgId={orgId}
          productId={complaintsItem.productId}
          productCategory={complaintsItem.category}
          productName={complaintsItem.name}
          onClose={() => setComplaintsItem(null)}
        />
      ) : null}
    </div>
  )
}
