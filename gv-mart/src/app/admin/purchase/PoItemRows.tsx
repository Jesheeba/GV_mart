import { useTranslation } from "react-i18next"
import { Plus, Trash2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { productsHooks, sparesHooks } from "@/hooks/useMasters"
import type { PoItemInput } from "@/lib/validation/automation"

/** Shared "line items" editor for both Purchase Order creation and Bill
 * Entry — same shape (item type/id/qty/price), matching how the sales cart
 * (src/app/admin/sales/ItemsStep.tsx) builds product/spare rows. */
export function PoItemRows({ orgId, items, onChange }: { orgId: string | undefined; items: PoItemInput[]; onChange: (items: PoItemInput[]) => void }) {
  const { t } = useTranslation()
  const { data: products } = productsHooks.useList(orgId)
  const { data: spares } = sparesHooks.useList(orgId)

  function update(i: number, patch: Partial<PoItemInput>) {
    onChange(items.map((row, idx) => (idx === i ? { ...row, ...patch } : row)))
  }
  function remove(i: number) {
    onChange(items.filter((_, idx) => idx !== i))
  }
  function add() {
    onChange([...items, { itemType: "spare", itemId: "", qty: 1, price: 0 }])
  }

  const options = (type: "product" | "spare") => (type === "product" ? (products ?? []) : (spares ?? []))

  return (
    <div className="space-y-2">
      {items.map((row, i) => (
        <div key={i} className="grid grid-cols-1 gap-2 rounded-xl border border-border p-2.5 sm:grid-cols-[auto_1fr_auto_auto_auto]">
          <select
            value={row.itemType}
            onChange={(e) => update(i, { itemType: e.target.value as "product" | "spare", itemId: "" })}
            className="h-10 rounded-xl border border-border bg-surface px-2 text-sm text-text outline-none"
          >
            <option value="spare">{t("masters.tabs.spares")}</option>
            <option value="product">{t("masters.tabs.products")}</option>
          </select>
          <select
            value={row.itemId}
            onChange={(e) => update(i, { itemId: e.target.value })}
            className="h-10 rounded-xl border border-border bg-surface px-2 text-sm text-text outline-none"
          >
            <option value="">{t("purchase.items.selectItem")}</option>
            {options(row.itemType).map((o) => (
              <option key={o.id} value={o.id}>
                {o.name}
              </option>
            ))}
          </select>
          <Input
            type="number"
            min={1}
            className="w-20"
            placeholder={t("purchase.items.qty")}
            value={row.qty}
            onChange={(e) => update(i, { qty: Number(e.target.value) || 0 })}
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
          <Button size="icon-xs" variant="ghost" onClick={() => remove(i)}>
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
