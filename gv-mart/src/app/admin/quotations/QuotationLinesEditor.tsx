import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { Plus, Trash2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Autocomplete } from "@/components/shared/Autocomplete"
import { SparePicker } from "@/components/shared/SparePicker"
import { productsHooks, sparesHooks } from "@/hooks/useMasters"
import { formatCurrency } from "@/lib/sale-calc"
import { productMatchesQuery, productSearchLabel } from "@/lib/productSearch"
import { FIELD_W } from "@/lib/fieldWidth"
import { cn } from "@/lib/utils"
import type { Enums } from "@/types/database"

export type QuoteLine = { itemType: Enums<"item_type">; itemId: string; name: string; price: number; qty: number }

const toQty = (v: string) => Math.max(1, Math.floor(Number(v) || 1))

/**
 * Product/spare pickers + the line list (qty editable, remove). Shared by New Quotation and the
 * Edit popup (quotation-edit-discount). New lines take today's price; lines already on a saved
 * quote come in with their quoted price and keep it (the RPC does the same).
 */
export function QuotationLinesEditor({ orgId, lines, onChange }: { orgId: string; lines: QuoteLine[]; onChange: (lines: QuoteLine[]) => void }) {
  const { t } = useTranslation()
  const { data: products } = productsHooks.useList(orgId)
  const { data: spares } = sparesHooks.useList(orgId)
  // New lines only ever pick an active item; an existing line for an archived one still shows.
  const activeProducts = useMemo(() => (products ?? []).filter((p) => p.is_active), [products])
  const activeSpares = useMemo(() => (spares ?? []).filter((s) => s.is_active), [spares])

  const [productId, setProductId] = useState("")
  const [productLabel, setProductLabel] = useState("")
  const [productQuery, setProductQuery] = useState("")
  const [productQty, setProductQty] = useState("1")
  const [spareId, setSpareId] = useState("")
  const [spareQty, setSpareQty] = useState("1")
  const productSuggestions = useMemo(() => activeProducts.filter((p) => productMatchesQuery(p, productQuery)), [activeProducts, productQuery])

  // Adding an item that's already a line bumps that line's qty, so the quote never has the same item twice.
  function addLine(line: QuoteLine) {
    const i = lines.findIndex((l) => l.itemType === line.itemType && l.itemId === line.itemId)
    onChange(i === -1 ? [...lines, line] : lines.map((l, idx) => (idx === i ? { ...l, qty: l.qty + line.qty } : l)))
  }
  function addProductLine() {
    const p = activeProducts.find((x) => x.id === productId)
    if (!p) return
    addLine({ itemType: "product", itemId: p.id, name: p.name, price: Number(p.price), qty: toQty(productQty) })
    setProductId("")
    setProductLabel("")
    setProductQuery("")
    setProductQty("1")
  }
  function addSpareLine() {
    const s = activeSpares.find((x) => x.id === spareId)
    if (!s) return
    addLine({ itemType: "spare", itemId: s.id, name: s.name, price: Number(s.price), qty: toQty(spareQty) })
    setSpareId("")
    setSpareQty("1")
  }

  return (
    <div className="space-y-3">
      <div className="grid grid-cols-2 gap-2 px-1 sm:grid-cols-4">
        <Autocomplete
          className="sm:col-span-2"
          value={productId ? productLabel : productQuery}
          onChange={(v) => {
            setProductQuery(v)
            setProductId("")
          }}
          onSelect={(p) => {
            setProductId(p.id)
            setProductLabel(productSearchLabel(p))
          }}
          suggestions={productSuggestions}
          openOnFocus
          placeholder={t("sales.items.selectProduct")}
          emptyMessage={t("common.noData")}
          getKey={(p) => p.id}
          getLabel={(p) => (
            <span>
              {productSearchLabel(p)} <span className="text-text-muted">— {formatCurrency(Number(p.price))}</span>
            </span>
          )}
          inputClassName="h-8"
        />
        <Input type="number" inputMode="numeric" min={1} step={1} value={productQty} onChange={(e) => setProductQty(e.target.value)} placeholder={t("sales.items.qty")} aria-label={t("sales.items.qty")} className={cn("h-8", FIELD_W.qty)} />
        <Button type="button" size="sm" variant="outline" disabled={!productId} onClick={addProductLine}>
          <Plus className="size-3.5" />
          {t("sales.items.add")}
        </Button>
      </div>
      <div className="grid grid-cols-2 gap-2 px-1 sm:grid-cols-4">
        <SparePicker
          className="sm:col-span-2"
          inputClassName="h-8"
          spares={activeSpares}
          value={spareId}
          onChange={setSpareId}
          placeholder={t("sales.items.selectSpare")}
          renderMeta={(s) => formatCurrency(Number(s.price))}
        />
        <Input type="number" inputMode="numeric" min={1} step={1} value={spareQty} onChange={(e) => setSpareQty(e.target.value)} placeholder={t("sales.items.qty")} aria-label={t("sales.items.qty")} className={cn("h-8", FIELD_W.qty)} />
        <Button type="button" size="sm" variant="outline" disabled={!spareId} onClick={addSpareLine}>
          <Plus className="size-3.5" />
          {t("sales.items.add")}
        </Button>
      </div>

      {lines.length === 0 ? (
        <p className="px-1 text-sm text-text-muted">{t("sales.items.emptyCart")}</p>
      ) : (
        <div className="space-y-2 px-1">
          {lines.map((l, i) => (
            <div key={`${l.itemType}-${l.itemId}`} className="flex items-center justify-between gap-3 rounded-xl border border-border px-3.5 py-2.5">
              <div className="min-w-0">
                <p className="truncate text-sm font-medium text-text">{l.name}</p>
                <p className="text-xs text-text-muted">
                  {formatCurrency(l.price)} × {l.qty} = {formatCurrency(l.qty * l.price)}
                </p>
              </div>
              <div className="flex shrink-0 items-center gap-1.5">
                <Input
                  type="number"
                  inputMode="numeric"
                  min={1}
                  step={1}
                  value={l.qty}
                  onChange={(e) => onChange(lines.map((x, idx) => (idx === i ? { ...x, qty: toQty(e.target.value) } : x)))}
                  aria-label={t("quotations.lines.qtyFor", { name: l.name })}
                  className={cn("h-8", FIELD_W.qty)}
                />
                <Button type="button" size="icon-xs" variant="ghost" aria-label={t("common.remove")} onClick={() => onChange(lines.filter((_, idx) => idx !== i))}>
                  <Trash2 className="size-3.5 text-danger" />
                </Button>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
