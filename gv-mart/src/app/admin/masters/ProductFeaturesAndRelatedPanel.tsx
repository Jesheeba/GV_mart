import { useState } from "react"
import { useTranslation } from "react-i18next"
import { ArrowDown, ArrowUp, Link2, Loader2, Plus, Trash2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogTitle } from "@/components/ui/dialog"
import { productsHooks, useAddProductRelated, useProductRelated, useRemoveProductRelated, useSetProductFeatureBullets } from "@/hooks/useMasters"
import type { Tables, TablesInsert } from "@/types/database"

function extractErrorMessage(e: unknown): string {
  if (e instanceof Error) return e.message
  if (typeof e === "object" && e !== null && "message" in e && typeof (e as { message: unknown }).message === "string") {
    return (e as { message: string }).message
  }
  return String(e)
}

const RELATION_TYPES: TablesInsert<"product_related">["relation_type"][] = ["related", "accessory", "frequently_bought_with"]

/**
 * Product Enquiry rebuild (2026-08-04), Phase 1 — feature bullets (a plain
 * jsonb string array on products, whole-array PATCH on every change, same
 * precedent as service_visits.evidence_photo_urls) and related-products
 * mapping (modeled on ProductSparesPanel's picker pattern).
 */
export function ProductFeaturesAndRelatedPanel({
  orgId,
  productId,
  productName,
  featureBullets,
  onClose,
}: {
  orgId: string | undefined
  productId: string
  productName: string
  featureBullets: string[]
  onClose: () => void
}) {
  const { t } = useTranslation()
  const setBulletsMut = useSetProductFeatureBullets()
  const [newBullet, setNewBullet] = useState("")
  const [error, setError] = useState<string | null>(null)

  const { data: allProducts } = productsHooks.useList(orgId)
  const { data: related } = useProductRelated(productId)
  const addRelatedMut = useAddProductRelated(productId)
  const removeRelatedMut = useRemoveProductRelated(productId)
  const [pickerProductId, setPickerProductId] = useState("")
  const [relationType, setRelationType] = useState<TablesInsert<"product_related">["relation_type"]>("related")

  const relatedRows = (related ?? []) as (Tables<"product_related"> & { related: { id: string; name: string; is_active: boolean } | null })[]
  const relatedIds = new Set(relatedRows.map((r) => r.related_product_id))
  const availableToAdd = (allProducts ?? []).filter((p) => p.id !== productId && !relatedIds.has(p.id))

  async function addBullet() {
    if (!newBullet.trim()) return
    setError(null)
    try {
      await setBulletsMut.mutateAsync({ productId, bullets: [...featureBullets, newBullet.trim()] })
      setNewBullet("")
    } catch (e) {
      setError(extractErrorMessage(e))
    }
  }
  async function removeBullet(index: number) {
    setError(null)
    try {
      await setBulletsMut.mutateAsync({ productId, bullets: featureBullets.filter((_, i) => i !== index) })
    } catch (e) {
      setError(extractErrorMessage(e))
    }
  }
  async function moveBullet(index: number, direction: -1 | 1) {
    const target = index + direction
    if (target < 0 || target >= featureBullets.length) return
    const next = [...featureBullets]
    ;[next[index], next[target]] = [next[target], next[index]]
    setError(null)
    try {
      await setBulletsMut.mutateAsync({ productId, bullets: next })
    } catch (e) {
      setError(extractErrorMessage(e))
    }
  }

  async function handleAddRelated() {
    if (!pickerProductId || !orgId) return
    setError(null)
    try {
      await addRelatedMut.mutateAsync({ orgId, relatedProductId: pickerProductId, relationType })
      setPickerProductId("")
    } catch (e) {
      setError(extractErrorMessage(e))
    }
  }

  return (
    <Dialog
      open
      onOpenChange={(next) => {
        if (!next) onClose()
      }}
    >
      <DialogContent className="max-w-lg">
        <DialogTitle className="flex items-center gap-1.5">
          <Link2 className="size-4 text-accent" />
          {t("masters.productFeatures.title")} — {productName}
        </DialogTitle>

        <div className="space-y-1.5">
          <h3 className="px-0.5 text-xs font-semibold text-text-muted">{t("masters.productFeatures.bulletsTitle")}</h3>
          {featureBullets.length === 0 ? (
            <p className="rounded-xl border border-dashed border-border px-3 py-2.5 text-xs text-text-muted">{t("masters.productFeatures.bulletsEmpty")}</p>
          ) : (
            <ul className="space-y-1">
              {featureBullets.map((b, i) => (
                <li key={i} className="flex items-center justify-between gap-2 rounded-xl border border-border px-3 py-1.5">
                  <span className="text-sm text-text">{b}</span>
                  <div className="flex shrink-0 items-center gap-0.5">
                    <Button size="icon-xs" variant="ghost" onClick={() => moveBullet(i, -1)}>
                      <ArrowUp className="size-3" />
                    </Button>
                    <Button size="icon-xs" variant="ghost" onClick={() => moveBullet(i, 1)}>
                      <ArrowDown className="size-3" />
                    </Button>
                    <Button size="icon-xs" variant="ghost" onClick={() => removeBullet(i)}>
                      <Trash2 className="size-3 text-danger" />
                    </Button>
                  </div>
                </li>
              ))}
            </ul>
          )}
          <div className="flex items-center gap-1.5">
            <input
              value={newBullet}
              onChange={(e) => setNewBullet(e.target.value)}
              placeholder={t("masters.productFeatures.bulletPlaceholder")}
              className="h-9 flex-1 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
            />
            <Button size="sm" className="gap-1" disabled={!newBullet.trim() || setBulletsMut.isPending} onClick={addBullet}>
              {setBulletsMut.isPending ? <Loader2 className="size-3.5 animate-spin" /> : <Plus className="size-3.5" />}
              {t("masters.productFeatures.add")}
            </Button>
          </div>
        </div>

        <div className="space-y-1.5">
          <h3 className="px-0.5 text-xs font-semibold text-text-muted">{t("masters.productFeatures.relatedTitle")}</h3>
          {relatedRows.length === 0 ? (
            <p className="rounded-xl border border-dashed border-border px-3 py-2.5 text-xs text-text-muted">{t("masters.productFeatures.relatedEmpty")}</p>
          ) : (
            <ul className="space-y-1">
              {relatedRows.map((r) => (
                <li key={r.id} className="flex items-center justify-between gap-2 rounded-xl border border-border px-3 py-2">
                  <span className="text-sm text-text">
                    {r.related?.name ?? "—"}
                    <span className="ml-1.5 text-xs text-text-muted">({t(`masters.productFeatures.relationType.${r.relation_type}`)})</span>
                  </span>
                  <Button size="icon-xs" variant="ghost" onClick={() => removeRelatedMut.mutate(r.id)}>
                    <Trash2 className="size-3.5 text-danger" />
                  </Button>
                </li>
              ))}
            </ul>
          )}
          <div className="flex items-center gap-1.5">
            <select
              value={pickerProductId}
              onChange={(e) => setPickerProductId(e.target.value)}
              disabled={availableToAdd.length === 0}
              className="h-9 flex-1 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none disabled:opacity-50"
            >
              <option value="">{availableToAdd.length === 0 ? t("masters.productFeatures.noneToAdd") : t("masters.productFeatures.pickPlaceholder")}</option>
              {availableToAdd.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.name}
                </option>
              ))}
            </select>
            <select
              value={relationType}
              onChange={(e) => setRelationType(e.target.value as TablesInsert<"product_related">["relation_type"])}
              className="h-9 w-40 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
            >
              {RELATION_TYPES.map((rt) => (
                <option key={rt} value={rt}>
                  {t(`masters.productFeatures.relationType.${rt}`)}
                </option>
              ))}
            </select>
            <Button size="sm" className="gap-1" disabled={!pickerProductId || addRelatedMut.isPending} onClick={handleAddRelated}>
              {addRelatedMut.isPending ? <Loader2 className="size-3.5 animate-spin" /> : <Plus className="size-3.5" />}
              {t("masters.productFeatures.add")}
            </Button>
          </div>
        </div>
        {error ? <p className="text-xs text-danger">{error}</p> : null}
      </DialogContent>
    </Dialog>
  )
}
