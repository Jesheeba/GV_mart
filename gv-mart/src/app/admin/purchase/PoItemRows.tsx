import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Plus, Trash2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Autocomplete } from "@/components/shared/Autocomplete"
import { productsHooks, sparesHooks } from "@/hooks/useMasters"
import { productMatchesQuery, productSearchLabel } from "@/lib/productSearch"
import type { PoItemInput } from "@/lib/validation/automation"

/** Shared "line items" editor for both Purchase Order creation and Bill
 * Entry — same shape (item type/id/qty/price), matching how the sales cart
 * (src/app/admin/sales/ItemsStep.tsx) builds product/spare rows. */
export function PoItemRows({ orgId, items, onChange }: { orgId: string | undefined; items: PoItemInput[]; onChange: (items: PoItemInput[]) => void }) {
  const { t } = useTranslation()
  const { data: products } = productsHooks.useList(orgId)
  const { data: spares } = sparesHooks.useList(orgId)
  // Per-row in-progress product search text, keyed by row index — only
  // needed until a product is picked (after that the row's own itemId
  // resolves back to a label, see productLabelFor below).
  const [productQueries, setProductQueries] = useState<Record<number, string>>({})

  function update(i: number, patch: Partial<PoItemInput>) {
    onChange(items.map((row, idx) => (idx === i ? { ...row, ...patch } : row)))
  }
  function remove(i: number) {
    onChange(items.filter((_, idx) => idx !== i))
  }
  function add() {
    onChange([...items, { itemType: "spare", itemId: "", qty: 1, price: 0 }])
  }

  // Active-only for products, same as the sales cart's own picker
  // (ItemsStep.tsx) — a PO/bill shouldn't let anyone restock a discontinued
  // product. Spares have no equivalent archive flow yet, so left as-is.
  const activeProducts = (products ?? []).filter((p) => p.is_active)
  const spareOptions = spares ?? []
  function productSuggestionsFor(i: number) {
    return activeProducts.filter((p) => productMatchesQuery(p, productQueries[i] ?? ""))
  }

  return (
    <div className="space-y-2">
      {items.map((row, i) => (
        <div key={i} className="grid grid-cols-1 gap-2 rounded-xl border border-border p-2.5 sm:grid-cols-[auto_1fr_auto_auto_auto]">
          <select
            value={row.itemType}
            onChange={(e) => update(i, { itemType: e.target.value as "product" | "spare", itemId: "" })}
            className="h-10 rounded-xl border border-border bg-surface px-2 text-sm text-text outline-none transition-colors focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"
          >
            <option value="spare">{t("masters.tabs.spares")}</option>
            <option value="product">{t("masters.tabs.products")}</option>
          </select>
          {row.itemType === "product" ? (
            <Autocomplete
              value={row.itemId ? productSearchLabel(activeProducts.find((p) => p.id === row.itemId) ?? { name: "" }) : (productQueries[i] ?? "")}
              onChange={(v) => {
                setProductQueries((q) => ({ ...q, [i]: v }))
                update(i, { itemId: "" })
              }}
              onSelect={(p) => {
                update(i, { itemId: p.id })
                setProductQueries((q) => ({ ...q, [i]: "" }))
              }}
              suggestions={productSuggestionsFor(i)}
              openOnFocus
              placeholder={t("purchase.items.selectItem")}
              emptyMessage={t("common.noData")}
              getKey={(p) => p.id}
              getLabel={(p) => productSearchLabel(p)}
              inputClassName="h-10"
            />
          ) : (
            <select
              value={row.itemId}
              onChange={(e) => update(i, { itemId: e.target.value })}
              className="h-10 rounded-xl border border-border bg-surface px-2 text-sm text-text outline-none transition-colors focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"
            >
              <option value="">{t("purchase.items.selectItem")}</option>
              {spareOptions.map((o) => (
                <option key={o.id} value={o.id}>
                  {o.name}
                </option>
              ))}
            </select>
          )}
          <Input
            type="number"
            min={1}
            step={1}
            className="w-20"
            placeholder={t("purchase.items.qty")}
            value={row.qty}
            onChange={(e) => update(i, { qty: Math.max(1, Math.floor(Number(e.target.value) || 1)) })}
          />
          <Input
            type="number"
            min={0}
            step="0.01"
            className="w-24"
            placeholder={t("purchase.items.price")}
            value={row.price}
            onChange={(e) => update(i, { price: Number(e.target.value) || 0 })}
          />
          <Button size="icon-xs" variant="ghost" onClick={() => remove(i)} aria-label={t("common.remove")}>
            <Trash2 className="size-3.5 text-danger" />
          </Button>
        </div>
      ))}
      <Button size="sm" variant="outline" onClick={add}>
        <Plus className="size-3.5" />
        {t("purchase.items.addRow")}
      </Button>
    </div>
  )
}
