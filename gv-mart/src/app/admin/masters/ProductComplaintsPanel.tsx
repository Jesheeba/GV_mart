import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Check, ClipboardList, Loader2, Pencil, Plus, Sparkles, Trash2, X } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card, CardAction, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { complaintTypesHooks } from "@/hooks/useMasters"
import type { ComplaintTypeRow } from "@/services/masters"
import type { Enums } from "@/types/database"

// Supabase/PostgREST rejections aren't `instanceof Error` — same shape as
// EntityCrudTable's extractErrorMessage, duplicated here rather than shared
// since it's a 6-line helper and EntityCrudTable isn't exported for reuse.
function extractErrorMessage(e: unknown): string {
  if (e instanceof Error) return e.message
  if (typeof e === "object" && e !== null && "message" in e && typeof (e as { message: unknown }).message === "string") {
    return (e as { message: string }).message
  }
  return String(e)
}

/**
 * Admin-side product↔complaints connector. Opened from a row action in
 * Masters > Products (ProductsTab.tsx) and from the Inventory > Products
 * table (InventoryTable.tsx) — both pass a productId/category/name and get
 * the same panel. Not a bulk migration tool: "start from defaults" only ever
 * touches the one product currently open here.
 *
 * Shell choice: this app has no Dialog/Sheet primitive yet (checked
 * components/ui/) — other admin overlays (StuckJobsPanel.tsx) use a plain
 * `fixed inset-0` backdrop + Card, so this follows the same pattern rather
 * than introducing a new one.
 */
export function ProductComplaintsPanel({
  orgId,
  productId,
  productCategory,
  productName,
  onClose,
}: {
  orgId: string | undefined
  productId: string
  productCategory: Enums<"brand_category">
  productName: string
  onClose: () => void
}) {
  const { t } = useTranslation()
  const { data: allRows, isLoading, isError, refetch } = complaintTypesHooks.useList(orgId)
  const createMut = complaintTypesHooks.useCreate()
  const updateMut = complaintTypesHooks.useUpdate()
  const deleteMut = complaintTypesHooks.useDelete()

  const [newLabel, setNewLabel] = useState("")
  const [addError, setAddError] = useState<string | null>(null)
  const [editingId, setEditingId] = useState<string | null>(null)
  const [editLabel, setEditLabel] = useState("")
  const [confirmingDeleteId, setConfirmingDeleteId] = useState<string | null>(null)
  const [isSeeding, setIsSeeding] = useState(false)
  const [seedError, setSeedError] = useState<string | null>(null)

  const categoryDefaults = (allRows ?? []).filter(
    (r) => r.product_category === productCategory && r.product_id === null
  )
  const ownComplaints = (allRows ?? []).filter((r) => r.product_id === productId)

  const ownLabelsLower = new Set(ownComplaints.map((r) => r.label.trim().toLowerCase()))
  const missingDefaults = categoryDefaults.filter((d) => !ownLabelsLower.has(d.label.trim().toLowerCase()))

  async function handleAdd() {
    const label = newLabel.trim()
    if (!label || !orgId) return
    setAddError(null)
    try {
      await createMut.mutateAsync({ org_id: orgId, product_category: productCategory, product_id: productId, label })
      setNewLabel("")
    } catch (e) {
      setAddError(extractErrorMessage(e))
    }
  }

  function startEdit(row: ComplaintTypeRow) {
    setEditingId(row.id)
    setEditLabel(row.label)
    setAddError(null)
  }
  async function saveEdit(id: string) {
    const label = editLabel.trim()
    if (!label) return
    try {
      await updateMut.mutateAsync({ id, patch: { label } })
      setEditingId(null)
    } catch (e) {
      setAddError(extractErrorMessage(e))
    }
  }
  async function handleDelete(id: string) {
    try {
      await deleteMut.mutateAsync(id)
      setConfirmingDeleteId(null)
    } catch (e) {
      setAddError(extractErrorMessage(e))
    }
  }

  async function startFromDefaults() {
    if (!orgId || missingDefaults.length === 0) return
    setIsSeeding(true)
    setSeedError(null)
    try {
      await Promise.all(
        missingDefaults.map((d) =>
          createMut.mutateAsync({ org_id: orgId, product_category: productCategory, product_id: productId, label: d.label })
        )
      )
    } catch (e) {
      setSeedError(extractErrorMessage(e))
    } finally {
      setIsSeeding(false)
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/30 px-4 py-10" role="presentation" onClick={onClose}>
      <div className="w-full max-w-lg" onClick={(e) => e.stopPropagation()}>
        <Card>
          <CardHeader className="border-b border-border pb-4">
            <CardTitle className="flex items-center gap-1.5">
              <ClipboardList className="size-4 text-accent" />
              {t("masters.productComplaints.title")} — {productName}
            </CardTitle>
            <CardAction>
              <Button type="button" variant="ghost" size="icon-sm" onClick={onClose} aria-label={t("masters.productComplaints.close")}>
                <X className="size-4" />
              </Button>
            </CardAction>
          </CardHeader>
          <CardContent className="flex max-h-[70vh] flex-col gap-5 overflow-y-auto pt-4">
            {isError ? (
              <div className="flex flex-col items-center gap-2 py-6 text-center">
                <p className="text-sm text-text-muted">{t("masters.loadFailed")}</p>
                <Button variant="outline" size="sm" onClick={() => refetch()}>
                  {t("common.retry")}
                </Button>
              </div>
            ) : isLoading ? (
              <p className="py-4 text-center text-sm text-text-muted">{t("common.loading")}</p>
            ) : (
              <>
                {/* Category defaults — read-only here, owned by ComplaintTypesTab. */}
                <section className="space-y-2">
                  <h3 className="text-xs font-semibold uppercase tracking-wide text-text-muted">
                    {t("masters.productComplaints.categoryDefaultsTitle")}
                  </h3>
                  <p className="text-xs text-text-muted">{t("masters.productComplaints.categoryDefaultsHint")}</p>
                  {categoryDefaults.length === 0 ? (
                    <p className="rounded-xl border border-dashed border-border px-3 py-2.5 text-xs text-text-muted">
                      {t("masters.productComplaints.categoryDefaultsEmpty")}
                    </p>
                  ) : (
                    <ul className="space-y-1">
                      {categoryDefaults.map((d) => (
                        <li key={d.id} className="flex items-center justify-between gap-2 rounded-xl border border-border px-3 py-2">
                          <span className="text-sm text-text">{d.label}</span>
                          <span className="shrink-0 rounded-full bg-surface-alt px-2 py-0.5 text-[10px] font-semibold text-text-muted">
                            {t("masters.productComplaints.categoryDefaultBadge")}
                          </span>
                        </li>
                      ))}
                    </ul>
                  )}
                  <Button
                    size="sm"
                    variant="outline"
                    className="gap-1.5"
                    disabled={isSeeding || missingDefaults.length === 0}
                    onClick={startFromDefaults}
                  >
                    {isSeeding ? <Loader2 className="size-3.5 animate-spin" /> : <Sparkles className="size-3.5" />}
                    {missingDefaults.length === 0
                      ? t("masters.productComplaints.startFromDefaultsDone")
                      : t("masters.productComplaints.startFromDefaults")}
                  </Button>
                  {seedError ? <p className="text-xs text-danger">{seedError}</p> : null}
                </section>

                <div className="border-t border-border" />

                {/* This product's own complaints — full add/edit/delete. */}
                <section className="space-y-2">
                  <h3 className="text-xs font-semibold uppercase tracking-wide text-text-muted">
                    {t("masters.productComplaints.ownTitle")}
                  </h3>
                  {ownComplaints.length === 0 ? (
                    <p className="rounded-xl border border-dashed border-border px-3 py-2.5 text-xs text-text-muted">
                      {t("masters.productComplaints.ownEmpty")}
                    </p>
                  ) : (
                    <ul className="space-y-1">
                      {ownComplaints.map((r) => (
                        <li key={r.id} className="flex items-center justify-between gap-2 rounded-xl border border-border px-3 py-2">
                          {editingId === r.id ? (
                            <div className="flex flex-1 items-center gap-1.5">
                              <Input
                                className="h-8 flex-1 text-sm"
                                value={editLabel}
                                onChange={(e) => setEditLabel(e.target.value)}
                                autoFocus
                              />
                              <Button size="icon-xs" variant="ghost" onClick={() => saveEdit(r.id)} disabled={updateMut.isPending}>
                                {updateMut.isPending ? <Loader2 className="size-3 animate-spin" /> : <Check className="size-3.5 text-success" />}
                              </Button>
                              <Button size="icon-xs" variant="ghost" onClick={() => setEditingId(null)}>
                                <X className="size-3.5 text-text-muted" />
                              </Button>
                            </div>
                          ) : (
                            <>
                              <span className="text-sm text-text">{r.label}</span>
                              {confirmingDeleteId === r.id ? (
                                <span className="flex shrink-0 items-center gap-1.5 text-xs">
                                  <button
                                    type="button"
                                    className="text-danger hover:underline disabled:opacity-50"
                                    disabled={deleteMut.isPending}
                                    onClick={() => handleDelete(r.id)}
                                  >
                                    {deleteMut.isPending ? <Loader2 className="size-3 animate-spin" /> : t("masters.confirmDelete")}
                                  </button>
                                  <button type="button" className="text-text-muted hover:underline" onClick={() => setConfirmingDeleteId(null)}>
                                    {t("common.cancel")}
                                  </button>
                                </span>
                              ) : (
                                <span className="flex shrink-0 items-center gap-1">
                                  <Button size="icon-xs" variant="ghost" title={t("masters.edit")} onClick={() => startEdit(r)}>
                                    <Pencil className="size-3.5" />
                                  </Button>
                                  <Button size="icon-xs" variant="ghost" title={t("masters.delete")} onClick={() => setConfirmingDeleteId(r.id)}>
                                    <Trash2 className="size-3.5 text-danger" />
                                  </Button>
                                </span>
                              )}
                            </>
                          )}
                        </li>
                      ))}
                    </ul>
                  )}

                  <div className="flex items-center gap-1.5">
                    <Input
                      className="h-9 flex-1"
                      placeholder={t("masters.productComplaints.addPlaceholder")}
                      value={newLabel}
                      onChange={(e) => setNewLabel(e.target.value)}
                      onKeyDown={(e) => {
                        if (e.key === "Enter") handleAdd()
                      }}
                    />
                    <Button size="sm" className="gap-1" disabled={!newLabel.trim() || createMut.isPending} onClick={handleAdd}>
                      {createMut.isPending ? <Loader2 className="size-3.5 animate-spin" /> : <Plus className="size-3.5" />}
                      {t("masters.productComplaints.add")}
                    </Button>
                  </div>
                  {addError ? <p className="text-xs text-danger">{addError}</p> : null}
                </section>
              </>
            )}
          </CardContent>
        </Card>
      </div>
    </div>
  )
}
