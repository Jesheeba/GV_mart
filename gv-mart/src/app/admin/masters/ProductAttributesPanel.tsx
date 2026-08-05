import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2, Plus, Sparkles, Trash2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogTitle } from "@/components/ui/dialog"
import { Label } from "@/components/ui/label"
import { productAttributeKeysHooks, useSetProductCustomAttribute } from "@/hooks/useMasters"
import type { Json } from "@/types/database"

function extractErrorMessage(e: unknown): string {
  if (e instanceof Error) return e.message
  if (typeof e === "object" && e !== null && "message" in e && typeof (e as { message: unknown }).message === "string") {
    return (e as { message: string }).message
  }
  return String(e)
}

/**
 * Product Enquiry rebuild (2026-08-04), Phase 1 — per-product custom
 * attribute editor. Values live in products.custom_attributes (a jsonb map
 * keyed by product_attribute_keys.id) — this panel is the only place
 * values get written; product_attribute_keys.key_name/label/data_type is
 * the stable catalog new keys get created from, so filters/comparisons
 * (Phase 2) never see typo-drifted free-text keys.
 */
export function ProductAttributesPanel({
  orgId,
  productId,
  productName,
  customAttributes,
  onClose,
}: {
  orgId: string | undefined
  productId: string
  productName: string
  customAttributes: Json
  onClose: () => void
}) {
  const { t } = useTranslation()
  const { data: keys, isLoading } = productAttributeKeysHooks.useList(orgId)
  const createKeyMut = productAttributeKeysHooks.useCreate()
  const setAttrMut = useSetProductCustomAttribute()

  const [pickerKeyId, setPickerKeyId] = useState("")
  const [valueInput, setValueInput] = useState("")
  const [newKeyName, setNewKeyName] = useState("")
  const [newKeyLabel, setNewKeyLabel] = useState("")
  const [newKeyDataType, setNewKeyDataType] = useState<"text" | "number" | "boolean">("text")
  const [showAddKey, setShowAddKey] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const activeKeys = (keys ?? []).filter((k) => k.is_active)
  const values = (customAttributes as Record<string, unknown>) ?? {}
  const assignedKeys = activeKeys.filter((k) => values[k.id] !== undefined)
  const pickerOptions = activeKeys.filter((k) => values[k.id] === undefined)
  const pickedKey = activeKeys.find((k) => k.id === pickerKeyId)

  async function handleAddValue() {
    if (!pickerKeyId || !valueInput.trim()) return
    setError(null)
    try {
      const parsedValue = pickedKey?.data_type === "number" ? Number(valueInput) : pickedKey?.data_type === "boolean" ? valueInput === "true" : valueInput
      await setAttrMut.mutateAsync({ productId, current: customAttributes, keyId: pickerKeyId, value: parsedValue })
      setPickerKeyId("")
      setValueInput("")
    } catch (e) {
      setError(extractErrorMessage(e))
    }
  }

  async function handleRemoveValue(keyId: string) {
    setError(null)
    try {
      await setAttrMut.mutateAsync({ productId, current: customAttributes, keyId, value: null })
    } catch (e) {
      setError(extractErrorMessage(e))
    }
  }

  async function handleCreateKey() {
    if (!orgId || !newKeyName.trim() || !newKeyLabel.trim()) return
    setError(null)
    try {
      await createKeyMut.mutateAsync({ org_id: orgId, key_name: newKeyName.trim(), label: newKeyLabel.trim(), data_type: newKeyDataType })
      setNewKeyName("")
      setNewKeyLabel("")
      setNewKeyDataType("text")
      setShowAddKey(false)
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
      <DialogContent>
        <DialogTitle className="flex items-center gap-1.5">
          <Sparkles className="size-4 text-accent" />
          {t("masters.productAttributes.title")} — {productName}
        </DialogTitle>

        {isLoading ? (
          <p className="py-4 text-center text-sm text-text-muted">{t("common.loading")}</p>
        ) : (
          <>
            {assignedKeys.length === 0 ? (
              <p className="rounded-xl border border-dashed border-border px-3 py-2.5 text-xs text-text-muted">{t("masters.productAttributes.empty")}</p>
            ) : (
              <ul className="space-y-1">
                {assignedKeys.map((k) => (
                  <li key={k.id} className="flex items-center justify-between gap-2 rounded-xl border border-border px-3 py-2">
                    <span className="text-sm text-text">
                      <span className="font-medium">{k.label}</span>
                      <span className="ml-1.5 text-text-muted">{String(values[k.id])}</span>
                    </span>
                    <Button size="icon-xs" variant="ghost" onClick={() => handleRemoveValue(k.id)} title={t("masters.delete")}>
                      <Trash2 className="size-3.5 text-danger" />
                    </Button>
                  </li>
                ))}
              </ul>
            )}

            <div className="flex items-center gap-1.5">
              <select
                value={pickerKeyId}
                onChange={(e) => {
                  setPickerKeyId(e.target.value)
                  setValueInput("")
                }}
                disabled={pickerOptions.length === 0}
                className="h-9 w-2/5 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none disabled:opacity-50"
              >
                <option value="">
                  {pickerOptions.length === 0 ? t("masters.productAttributes.noneToAdd") : t("masters.productAttributes.pickPlaceholder")}
                </option>
                {pickerOptions.map((k) => (
                  <option key={k.id} value={k.id}>
                    {k.label}
                  </option>
                ))}
              </select>
              {pickedKey?.data_type === "boolean" ? (
                <select value={valueInput} onChange={(e) => setValueInput(e.target.value)} className="h-9 flex-1 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none">
                  <option value="">{t("masters.productAttributes.valuePlaceholder")}</option>
                  <option value="true">{t("common.yes")}</option>
                  <option value="false">{t("common.no")}</option>
                </select>
              ) : (
                <input
                  type={pickedKey?.data_type === "number" ? "number" : "text"}
                  value={valueInput}
                  onChange={(e) => setValueInput(e.target.value)}
                  disabled={!pickerKeyId}
                  placeholder={t("masters.productAttributes.valuePlaceholder")}
                  className="h-9 flex-1 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none disabled:opacity-50"
                />
              )}
              <Button size="sm" className="gap-1" disabled={!pickerKeyId || !valueInput.trim() || setAttrMut.isPending} onClick={handleAddValue}>
                {setAttrMut.isPending ? <Loader2 className="size-3.5 animate-spin" /> : <Plus className="size-3.5" />}
                {t("masters.productAttributes.add")}
              </Button>
            </div>

            {showAddKey ? (
              <div className="space-y-1.5 rounded-xl border border-border p-3">
                <Label>{t("masters.productAttributes.newKeyLabel")}</Label>
                <input
                  value={newKeyLabel}
                  onChange={(e) => setNewKeyLabel(e.target.value)}
                  placeholder={t("masters.productAttributes.newKeyLabelPlaceholder")}
                  className="h-9 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
                />
                <input
                  value={newKeyName}
                  onChange={(e) => setNewKeyName(e.target.value.toLowerCase().replace(/[^a-z0-9_]/g, "_"))}
                  placeholder={t("masters.productAttributes.newKeyNamePlaceholder")}
                  className="h-9 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
                />
                <select
                  value={newKeyDataType}
                  onChange={(e) => setNewKeyDataType(e.target.value as "text" | "number" | "boolean")}
                  className="h-9 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
                >
                  <option value="text">{t("masters.productAttributes.dataType.text")}</option>
                  <option value="number">{t("masters.productAttributes.dataType.number")}</option>
                  <option value="boolean">{t("masters.productAttributes.dataType.boolean")}</option>
                </select>
                <div className="flex justify-end gap-1.5">
                  <Button size="sm" variant="ghost" onClick={() => setShowAddKey(false)}>
                    {t("common.cancel")}
                  </Button>
                  <Button size="sm" disabled={!newKeyName.trim() || !newKeyLabel.trim() || createKeyMut.isPending} onClick={handleCreateKey}>
                    {createKeyMut.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("masters.productAttributes.createKey")}
                  </Button>
                </div>
              </div>
            ) : (
              <button type="button" className="text-xs font-medium text-accent hover:underline" onClick={() => setShowAddKey(true)}>
                + {t("masters.productAttributes.addNewKey")}
              </button>
            )}
            {error ? <p className="text-xs text-danger">{error}</p> : null}
          </>
        )}
      </DialogContent>
    </Dialog>
  )
}
