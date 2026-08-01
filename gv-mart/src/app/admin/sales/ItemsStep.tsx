import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { Plus, Trash2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { brandsHooks, modelsHooks, productsHooks, sparesHooks, amcPlansHooks } from "@/hooks/useMasters"
import { useInventoryList } from "@/hooks/useInventory"
import { formatCurrency } from "@/lib/sale-calc"
import type { CartAmc, CartProductLine, SaleCartState } from "./types"

const selectClass = "h-8 w-full rounded-xl border border-border bg-surface px-3.5 text-sm text-text outline-none disabled:opacity-50"

export function ItemsStep({ orgId, cart, setCart }: { orgId: string; cart: SaleCartState; setCart: (updater: (c: SaleCartState) => SaleCartState) => void }) {
  const { t } = useTranslation()

  const { data: brands } = brandsHooks.useList(orgId)
  const { data: models } = modelsHooks.useList(orgId)
  const { data: products } = productsHooks.useList(orgId)
  const { data: spares } = sparesHooks.useList(orgId)
  const { data: amcPlans } = amcPlansHooks.useList(orgId)
  const { data: productStock } = useInventoryList(orgId, "product")
  const { data: spareStock } = useInventoryList(orgId, "spare")

  const [brandId, setBrandId] = useState("")
  const [modelId, setModelId] = useState("")
  const [productId, setProductId] = useState("")
  const [productQty, setProductQty] = useState("1")

  const [spareId, setSpareId] = useState("")
  const [spareQty, setSpareQty] = useState("1")

  const [amcPlanId, setAmcPlanId] = useState("")

  const filteredModels = useMemo(() => (models ?? []).filter((m) => !brandId || m.brand_id === brandId), [models, brandId])
  const filteredProducts = useMemo(
    () => (products ?? []).filter((p) => (!brandId || p.brand_id === brandId) && (!modelId || p.model_id === modelId)),
    [products, brandId, modelId]
  )
  const selectedProduct = (products ?? []).find((p) => p.id === productId)
  const selectedSpare = (spares ?? []).find((s) => s.id === spareId)
  const roProductLine = cart.productLines.find((l) => l.category === "ro")

  function stockFor(itemId: string, list: typeof productStock) {
    return list?.find((r) => r.item_id === itemId)?.stock_qty
  }

  function addProduct() {
    if (!selectedProduct) return
    const brand = (brands ?? []).find((b) => b.id === selectedProduct.brand_id)
    const model = (models ?? []).find((m) => m.id === selectedProduct.model_id)
    const qty = Math.max(1, Math.floor(Number(productQty) || 1))
    const line: CartProductLine = {
      productId: selectedProduct.id,
      name: selectedProduct.name,
      brandName: brand?.name ?? "—",
      modelName: model?.name ?? "—",
      category: selectedProduct.category,
      price: Number(selectedProduct.price),
      qty,
      warranty: false,
      warrantyMonths: selectedProduct.warranty_months,
      installation: false,
    }
    setCart((c) => ({ ...c, productLines: [...c.productLines, line] }))
    setBrandId("")
    setModelId("")
    setProductId("")
    setProductQty("1")
  }

  function addSpare() {
    if (!selectedSpare) return
    const qty = Math.max(1, Math.floor(Number(spareQty) || 1))
    setCart((c) => ({
      ...c,
      spareLines: [...c.spareLines, { spareId: selectedSpare.id, name: selectedSpare.name, price: Number(selectedSpare.price), qty }],
    }))
    setSpareId("")
    setSpareQty("1")
  }

  function updateProductLine(index: number, patch: Partial<CartProductLine>) {
    setCart((c) => ({ ...c, productLines: c.productLines.map((l, i) => (i === index ? { ...l, ...patch } : l)) }))
  }
  function removeProductLine(index: number) {
    setCart((c) => ({ ...c, productLines: c.productLines.filter((_, i) => i !== index) }))
  }
  function updateSpareQty(index: number, qty: number) {
    setCart((c) => ({ ...c, spareLines: c.spareLines.map((l, i) => (i === index ? { ...l, qty } : l)) }))
  }
  function removeSpareLine(index: number) {
    setCart((c) => ({ ...c, spareLines: c.spareLines.filter((_, i) => i !== index) }))
  }

  function addAmc() {
    if (!roProductLine || !amcPlanId) return
    const plan = (amcPlans ?? []).find((p) => p.id === amcPlanId)
    if (!plan) return
    const amc: CartAmc = { productId: roProductLine.productId, productName: roProductLine.name, planId: plan.id, planName: plan.name, price: Number(plan.price) }
    setCart((c) => ({ ...c, amc }))
    setAmcPlanId("")
  }
  function removeAmc() {
    setCart((c) => ({ ...c, amc: null }))
  }

  return (
    <div className="space-y-4">
      <Card className="gap-3 px-5">
        <Tabs defaultValue="product">
          <TabsList>
            <TabsTrigger value="product">{t("sales.items.productTab")}</TabsTrigger>
            <TabsTrigger value="spare">{t("sales.items.spareTab")}</TabsTrigger>
          </TabsList>

          <TabsContent value="product">
            <div className="grid grid-cols-2 gap-2 px-1 pt-3 sm:grid-cols-4">
              <select
                className={selectClass}
                value={brandId}
                onChange={(e) => {
                  setBrandId(e.target.value)
                  setModelId("")
                  setProductId("")
                }}
              >
                <option value="">{t("sales.items.selectBrand")}</option>
                {(brands ?? []).map((b) => (
                  <option key={b.id} value={b.id}>
                    {b.name}
                  </option>
                ))}
              </select>
              <select
                className={selectClass}
                value={modelId}
                disabled={!brandId}
                onChange={(e) => {
                  setModelId(e.target.value)
                  setProductId("")
                }}
              >
                <option value="">{t("sales.items.selectModel")}</option>
                {filteredModels.map((m) => (
                  <option key={m.id} value={m.id}>
                    {m.name}
                  </option>
                ))}
              </select>
              <select className={selectClass} value={productId} disabled={!brandId} onChange={(e) => setProductId(e.target.value)}>
                <option value="">{t("sales.items.selectProduct")}</option>
                {filteredProducts.map((p) => (
                  <option key={p.id} value={p.id}>
                    {p.name} — {formatCurrency(Number(p.price))}
                  </option>
                ))}
              </select>
              <Input type="number" min={1} step={1} value={productQty} onChange={(e) => setProductQty(e.target.value)} placeholder={t("sales.items.qty")} className="h-8" />
            </div>
            <div className="flex items-center justify-between px-1 pt-2">
              <p className="text-xs text-text-muted">
                {selectedProduct
                  ? t("sales.items.stockHint", { count: stockFor(selectedProduct.id, productStock) ?? 0 })
                  : t("sales.items.pickProductHint")}
              </p>
              <Button type="button" size="sm" disabled={!selectedProduct} onClick={addProduct}>
                <Plus className="size-3.5" />
                {t("sales.items.add")}
              </Button>
            </div>
          </TabsContent>

          <TabsContent value="spare">
            <div className="grid grid-cols-2 gap-2 px-1 pt-3 sm:grid-cols-3">
              <select className={`${selectClass} sm:col-span-2`} value={spareId} onChange={(e) => setSpareId(e.target.value)}>
                <option value="">{t("sales.items.selectSpare")}</option>
                {(spares ?? []).map((s) => (
                  <option key={s.id} value={s.id}>
                    {s.name} — {formatCurrency(Number(s.price))} ({t("sales.items.stockShort", { count: stockFor(s.id, spareStock) ?? 0 })})
                  </option>
                ))}
              </select>
              <Input type="number" min={1} step={1} value={spareQty} onChange={(e) => setSpareQty(e.target.value)} placeholder={t("sales.items.qty")} className="h-8" />
            </div>
            <div className="flex justify-end px-1 pt-2">
              <Button type="button" size="sm" disabled={!selectedSpare} onClick={addSpare}>
                <Plus className="size-3.5" />
                {t("sales.items.add")}
              </Button>
            </div>
          </TabsContent>
        </Tabs>
      </Card>

      {cart.productLines.length === 0 && cart.spareLines.length === 0 ? (
        <p className="px-1 text-sm text-text-muted">{t("sales.items.emptyCart")}</p>
      ) : null}

      {cart.productLines.map((line, i) => (
        <Card key={`${line.productId}-${i}`} size="sm" className="gap-2 px-4">
          <div className="flex items-start justify-between px-1">
            <div>
              <p className="text-sm font-semibold text-text">{line.name}</p>
              <p className="text-xs text-text-muted">
                {line.brandName} · {line.modelName} · {t(`masters.categories.${line.category}`)}
              </p>
            </div>
            <Button type="button" size="icon-xs" variant="ghost" onClick={() => removeProductLine(i)}>
              <Trash2 className="size-3.5 text-danger" />
            </Button>
          </div>
          <div className="flex flex-wrap items-center gap-3 px-1">
            <Input
              type="number"
              min={1}
              step={1}
              value={line.qty}
              onChange={(e) => updateProductLine(i, { qty: Math.max(1, Math.floor(Number(e.target.value) || 1)) })}
              className="w-20"
            />
            <span className="text-sm text-text-muted">{formatCurrency(line.price)} × {line.qty} = {formatCurrency(line.price * line.qty)}</span>
          </div>
          <div className="flex flex-wrap items-center gap-4 border-t border-border px-1 pt-2">
            <label className="flex items-center gap-2 text-sm text-text">
              <input type="checkbox" checked={line.warranty} onChange={(e) => updateProductLine(i, { warranty: e.target.checked })} />
              {t("sales.items.warranty")}
            </label>
            {line.warranty ? (
              <span className="flex items-center gap-1.5 text-sm text-text-muted">
                {t("sales.items.warrantyMonths")}
                <Input
                  type="number"
                  min={1}
                  step={1}
                  value={line.warrantyMonths}
                  onChange={(e) => updateProductLine(i, { warrantyMonths: Math.max(1, Math.floor(Number(e.target.value) || 1)) })}
                  className="w-16"
                />
              </span>
            ) : null}
            <label className="flex items-center gap-2 text-sm text-text">
              <input type="checkbox" checked={line.installation} onChange={(e) => updateProductLine(i, { installation: e.target.checked })} />
              {t("sales.items.installation")}
            </label>
          </div>
          {line.installation ? <p className="px-1 text-xs text-info">{t("sales.items.installationNote")}</p> : null}
        </Card>
      ))}

      {cart.spareLines.map((line, i) => (
        <Card key={`${line.spareId}-${i}`} size="sm" className="gap-2 px-4">
          <div className="flex items-center justify-between px-1">
            <p className="text-sm font-semibold text-text">{line.name}</p>
            <Button type="button" size="icon-xs" variant="ghost" onClick={() => removeSpareLine(i)}>
              <Trash2 className="size-3.5 text-danger" />
            </Button>
          </div>
          <div className="flex flex-wrap items-center gap-3 px-1">
            <Input
              type="number"
              min={1}
              step={1}
              value={line.qty}
              onChange={(e) => updateSpareQty(i, Math.max(1, Math.floor(Number(e.target.value) || 1)))}
              className="w-20"
            />
            <span className="text-sm text-text-muted">{formatCurrency(line.price)} × {line.qty} = {formatCurrency(line.price * line.qty)}</span>
          </div>
        </Card>
      ))}

      {roProductLine ? (
        <Card size="sm" className="gap-2 px-4 border-accent/40">
          <p className="px-1 text-sm font-semibold text-text">{t("sales.items.amcAddonTitle", { product: roProductLine.name })}</p>
          {cart.amc ? (
            <div className="flex items-center justify-between px-1">
              <span className="text-sm text-text">
                {cart.amc.planName} — {formatCurrency(cart.amc.price)}
              </span>
              <Button type="button" size="sm" variant="outline" onClick={removeAmc}>
                {t("common.remove")}
              </Button>
            </div>
          ) : (
            <div className="flex flex-wrap items-center gap-2 px-1">
              <select className={`${selectClass} max-w-64`} value={amcPlanId} onChange={(e) => setAmcPlanId(e.target.value)}>
                <option value="">{t("sales.items.selectAmcPlan")}</option>
                {(amcPlans ?? []).map((p) => (
                  <option key={p.id} value={p.id}>
                    {p.name} ({p.years}y) — {formatCurrency(Number(p.price))}
                  </option>
                ))}
              </select>
              <Button type="button" size="sm" disabled={!amcPlanId} onClick={addAmc}>
                <Plus className="size-3.5" />
                {t("sales.items.add")}
              </Button>
            </div>
          )}
        </Card>
      ) : null}
    </div>
  )
}
