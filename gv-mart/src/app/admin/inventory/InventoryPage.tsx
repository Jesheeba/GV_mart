import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { Receipt, Search, TriangleAlert } from "lucide-react"
import { Button } from "@/components/ui/button"
import { useInventoryList } from "@/hooks/useInventory"
import { useLinkedItemKeys } from "@/hooks/useSuppliers"
import { useProfile } from "@/hooks/useProfile"
import { cn } from "@/lib/utils"
import type { ItemType } from "@/services/inventory"
import { InventoryTable } from "./InventoryTable"

export function InventoryPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const [itemType, setItemType] = useState<ItemType>("product")
  const [search, setSearch] = useState("")

  // Fetched again here (queryKey-deduped against InventoryTable's own fetch,
  // same pattern OwnerDashboard.tsx uses for its "low stock" stat) purely to
  // compute the header counts across BOTH segments, since the design's
  // subtitle (line 1166) counts the whole catalog, not just the active tab.
  const { data: products } = useInventoryList(orgId, "product")
  const { data: spares } = useInventoryList(orgId, "spare")
  const { data: gifts } = useInventoryList(orgId, "gift")
  // Needed to tell "will actually auto-reorder" apart from "below min but no
  // supplier linked, so _auto_draft_purchase_order silently no-ops" — see
  // stats.autoPo/needsSupplier below.
  const { data: linkedItems } = useLinkedItemKeys(orgId)
  const linkedKeys = useMemo(
    () => new Set((linkedItems ?? []).map((l) => `${l.item_type}:${l.item_id}`)),
    [linkedItems]
  )

  // Real counts derived from stock_qty vs min_stock on the fetched rows.
  // The design's subtitle also shows a "₹8.4L stock value" figure — omitted
  // here on purpose: products/spares only carry a sale `price`
  // (types/database.ts), not a per-unit cost, so a ₹ stock-value total would
  // be fabricated rather than real.
  const stats = useMemo(() => {
    const all = [...(products ?? []), ...(spares ?? []), ...(gifts ?? [])]
    const belowMin = all.filter((r) => r.stock_qty > 0 && r.stock_qty <= r.min_stock)
    // "low" (the subtitle's plain low-stock count) stays every below-min
    // item — that's genuinely true regardless of supplier linkage. Only the
    // Auto-PO badge needs the supplier-link split, since that badge
    // specifically claims a reorder is in progress.
    return {
      total: all.length,
      low: belowMin.length,
      out: all.filter((r) => r.stock_qty <= 0).length,
      autoPo: belowMin.filter((r) => linkedKeys.has(`${r.item_type}:${r.item_id}`)).length,
      needsSupplier: belowMin.filter((r) => !linkedKeys.has(`${r.item_type}:${r.item_id}`)).length,
    }
  }, [products, spares, gifts, linkedKeys])

  const statsReady = !!products && !!spares && !!gifts

  return (
    <div className="space-y-4 pt-2">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <div className="mb-1.75 text-xs font-semibold tracking-wide text-text-muted">{t("inventory.eyebrow")}</div>
          <h1 className="mb-1.5 text-[28px] font-extrabold leading-[1.05] tracking-tight text-text">{t("inventory.pageTitle")}</h1>
          <p className="text-sm font-medium text-text-muted">
            {statsReady ? t("inventory.headerStats", stats) : t("inventory.subtitle")}
          </p>
        </div>
        <div className="flex items-center gap-2.5">
          {stats.needsSupplier > 0 ? (
            <Button
              variant="ghost"
              size="sm"
              className="gap-2 bg-warning/10 text-warning hover:bg-warning/15"
              onClick={() => navigate("/admin/suppliers")}
              title={t("inventory.needsSupplierLinkHint")}
            >
              <TriangleAlert className="size-3.5" />
              {t("inventory.needsSupplierLink", { count: stats.needsSupplier })}
            </Button>
          ) : null}
          <Button
            variant="ghost"
            size="sm"
            className="gap-2 bg-accent-soft text-accent hover:bg-accent-soft/80"
            onClick={() => navigate("/admin/purchase")}
          >
            <Receipt className="size-3.5" />
            {t("inventory.autoPo", { count: stats.autoPo })}
          </Button>
        </div>
      </div>

      <div className="overflow-hidden rounded-card border border-border bg-surface shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
        <div className="flex flex-wrap items-center justify-between gap-3 px-5.5 py-4">
          <div className="flex gap-1 rounded-full border border-border bg-surface-alt p-1">
            <button
              type="button"
              aria-pressed={itemType === "product"}
              onClick={() => setItemType("product")}
              className={cn(
                "rounded-full px-4 py-1.75 text-xs font-semibold transition-colors",
                itemType === "product" ? "bg-ink text-white" : "text-text-muted"
              )}
            >
              {t("masters.tabs.products")}
            </button>
            <button
              type="button"
              aria-pressed={itemType === "spare"}
              onClick={() => setItemType("spare")}
              className={cn(
                "rounded-full px-4 py-1.75 text-xs font-semibold transition-colors",
                itemType === "spare" ? "bg-ink text-white" : "text-text-muted"
              )}
            >
              {t("masters.tabs.spares")}
            </button>
            <button
              type="button"
              aria-pressed={itemType === "gift"}
              onClick={() => setItemType("gift")}
              className={cn(
                "rounded-full px-4 py-1.75 text-xs font-semibold transition-colors",
                itemType === "gift" ? "bg-ink text-white" : "text-text-muted"
              )}
            >
              {t("masters.tabs.gifts")}
            </button>
          </div>

          <div className="flex w-70 items-center gap-2.25 rounded-full border border-border bg-surface-alt px-3.5 py-2">
            <Search className="size-3.75 shrink-0 text-text-muted" />
            <input
              type="text"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder={
                itemType === "product"
                  ? t("inventory.searchProducts")
                  : itemType === "spare"
                    ? t("inventory.searchSpares")
                    : t("inventory.searchGifts")
              }
              className="w-full bg-transparent text-xs font-medium text-text outline-none placeholder:text-text-muted"
            />
          </div>
        </div>

        <InventoryTable itemType={itemType} search={search} />
      </div>
    </div>
  )
}
