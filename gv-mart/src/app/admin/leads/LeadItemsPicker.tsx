import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { Search } from "lucide-react"
import { Input } from "@/components/ui/input"
import { Skeleton } from "@/components/ui/skeleton"
import { useInventoryList } from "@/hooks/useInventory"
import { productsHooks, sparesHooks } from "@/hooks/useMasters"
import { cn } from "@/lib/utils"

export type LeadItemSelection = Record<string, number>

type PickerRow = { id: string; name: string; brand: string | null; stock: number }

/**
 * Full-catalogue picker for a product/spare lead: every product (or spare)
 * the business stocks, with live stock, so the admin can tick what the
 * enquiry is for instead of typing it. Items with no inventory row yet
 * still appear (stock 0) — the list is the whole catalogue, not just
 * what happens to be in the warehouse.
 */
export function LeadItemsPicker({
  orgId,
  kind,
  value,
  onChange,
}: {
  orgId: string | undefined
  kind: "product" | "spare"
  value: LeadItemSelection
  onChange: (next: LeadItemSelection) => void
}) {
  const { t } = useTranslation()
  const [search, setSearch] = useState("")

  const inventory = useInventoryList(orgId, kind)
  const products = productsHooks.useList(kind === "product" ? orgId : undefined)
  const spares = sparesHooks.useList(kind === "spare" ? orgId : undefined)
  const catalogue = kind === "product" ? products : spares

  const rows = useMemo<PickerRow[]>(() => {
    const stock = new Map<string, number>()
    for (const r of inventory.data ?? []) stock.set(r.item_id, (stock.get(r.item_id) ?? 0) + r.stock_qty)
    const byId = new Map<string, PickerRow>()
    for (const c of catalogue.data ?? []) {
      const brand = "brands" in c ? ((c as { brands: { name: string } | null }).brands?.name ?? null) : null
      byId.set(c.id, { id: c.id, name: c.name, brand, stock: stock.get(c.id) ?? 0 })
    }
    // Inventory rows whose item is missing from the catalogue list (e.g. inactive) still show.
    for (const r of inventory.data ?? []) {
      if (!byId.has(r.item_id)) byId.set(r.item_id, { id: r.item_id, name: r.itemName, brand: r.itemBrand, stock: stock.get(r.item_id) ?? 0 })
    }
    return [...byId.values()].sort((a, b) => a.name.localeCompare(b.name))
  }, [inventory.data, catalogue.data])

  const term = search.trim().toLowerCase()
  const visible = rows.filter((r) => !term || r.name.toLowerCase().includes(term) || (r.brand ?? "").toLowerCase().includes(term))
  const loading = inventory.isLoading || catalogue.isLoading
  const selectedCount = Object.keys(value).length

  function toggle(id: string) {
    const next = { ...value }
    if (id in next) delete next[id]
    else next[id] = 1
    onChange(next)
  }

  return (
    <div className="space-y-2 sm:col-span-2">
      <div className="flex items-center justify-between gap-3">
        <span className="text-sm font-medium text-text">{t(kind === "product" ? "leads.new.pickProducts" : "leads.new.pickSpares")}</span>
        <span className="text-xs text-text-muted">{t("leads.new.selectedCount", { count: selectedCount })}</span>
      </div>
      <div className="flex w-full items-center gap-2 rounded-full border border-border bg-surface-alt px-3.5 py-2">
        <Search className="size-3.75 shrink-0 text-text-muted" />
        <input
          type="text"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder={t("leads.new.searchInventory")}
          className="w-full bg-transparent text-xs font-medium text-text outline-none placeholder:text-text-muted"
        />
      </div>
      <div className="max-h-64 overflow-y-auto rounded-xl border border-border">
        {loading ? (
          <div className="space-y-2 p-3">
            {Array.from({ length: 4 }).map((_, i) => (
              <Skeleton key={i} className="h-5 w-full" />
            ))}
          </div>
        ) : visible.length === 0 ? (
          <p className="p-4 text-center text-sm text-text-muted">{t("leads.new.noInventoryMatch")}</p>
        ) : (
          visible.map((r) => {
            const checked = r.id in value
            return (
              <div key={r.id} className={cn("flex items-center gap-3 border-b border-border px-3 py-2 last:border-b-0", checked && "bg-accent-soft/40")}>
                <input type="checkbox" checked={checked} onChange={() => toggle(r.id)} aria-label={r.name} className="size-4 shrink-0" />
                <div className="min-w-0 flex-1">
                  <p className="truncate text-[13px] font-semibold text-text">{r.name}</p>
                  {r.brand ? <p className="truncate text-[11px] text-text-muted">{r.brand}</p> : null}
                </div>
                <span className={cn("shrink-0 text-xs font-semibold", r.stock > 0 ? "text-success" : "text-danger")}>
                  {t("leads.new.inStock", { count: r.stock })}
                </span>
                {checked ? (
                  <Input
                    type="number"
                    min={1}
                    step={1}
                    value={value[r.id]}
                    onChange={(e) => onChange({ ...value, [r.id]: Math.max(1, Math.floor(Number(e.target.value)) || 1) })}
                    aria-label={t("leads.new.qty")}
                    className="h-8 w-16 shrink-0"
                  />
                ) : null}
              </div>
            )
          })
        )}
      </div>
    </div>
  )
}
