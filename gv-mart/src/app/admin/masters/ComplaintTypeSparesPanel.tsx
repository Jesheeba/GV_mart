import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2, Plus, Trash2, Wrench } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogTitle } from "@/components/ui/dialog"
import { sparesHooks, useAddComplaintTypeSpare, useComplaintTypeSpares, useRemoveComplaintTypeSpare } from "@/hooks/useMasters"

// Supabase/PostgREST rejections aren't `instanceof Error` — same helper as
// EntityCrudTable/ProductSparesPanel, duplicated for the same reason (small,
// not worth exporting a shared utility for).
function extractErrorMessage(e: unknown): string {
  if (e instanceof Error) return e.message
  if (typeof e === "object" && e !== null && "message" in e && typeof (e as { message: unknown }).message === "string") {
    return (e as { message: string }).message
  }
  return String(e)
}

/**
 * Issue-based spare suggestions (2026-08-06) — admin-side complaint_type
 * <-> spare mapping ("which spares fix this issue"), replacing the on-site
 * technician flow's dependence on product_spares. Straight port of
 * ProductSparesPanel.tsx's shape, keyed by complaint_type_id instead of
 * product_id. Opened from a row action in Masters > Complaint Types
 * (ComplaintTypesTab.tsx) — the single admin surface for this mapping,
 * covering both category-wide issues and any product-specific overrides
 * (both are rows in the same complaint_types table).
 */
export function ComplaintTypeSparesPanel({
  orgId,
  complaintTypeId,
  complaintTypeLabel,
  onClose,
}: {
  orgId: string | undefined
  complaintTypeId: string
  complaintTypeLabel: string
  onClose: () => void
}) {
  const { t } = useTranslation()
  const { data: mappings, isLoading, isError, refetch } = useComplaintTypeSpares(complaintTypeId)
  const { data: allSpares } = sparesHooks.useList(orgId)
  const addMut = useAddComplaintTypeSpare()
  const removeMut = useRemoveComplaintTypeSpare(complaintTypeId)

  const [pickerSpareId, setPickerSpareId] = useState("")
  const [error, setError] = useState<string | null>(null)
  const [confirmingRemoveId, setConfirmingRemoveId] = useState<string | null>(null)

  const mappedSpareIds = new Set((mappings ?? []).map((m) => m.spare_id))
  const availableToAdd = (allSpares ?? []).filter((s) => !mappedSpareIds.has(s.id))

  async function handleAdd() {
    if (!pickerSpareId || !orgId) return
    setError(null)
    try {
      await addMut.mutateAsync({ orgId, complaintTypeId, spareId: pickerSpareId })
      setPickerSpareId("")
    } catch (e) {
      setError(extractErrorMessage(e))
    }
  }
  async function handleRemove(id: string) {
    setError(null)
    try {
      await removeMut.mutateAsync(id)
      setConfirmingRemoveId(null)
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
          <Wrench className="size-4 text-accent" />
          {t("masters.complaintTypeSpares.title")} — {complaintTypeLabel}
        </DialogTitle>

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
            {(mappings ?? []).length === 0 ? (
              <p className="rounded-xl border border-dashed border-border px-3 py-2.5 text-xs text-text-muted">
                {t("masters.complaintTypeSpares.empty")}
              </p>
            ) : (
              <ul className="space-y-1">
                {(mappings ?? []).map((m) => (
                  <li key={m.id} className="flex items-center justify-between gap-2 rounded-xl border border-border px-3 py-2">
                    <span className="text-sm text-text">
                      {m.spares?.name ?? "—"}
                      {m.spares?.sku ? <span className="ml-1.5 text-xs text-text-muted">({m.spares.sku})</span> : null}
                      {m.spares && !m.spares.is_active ? (
                        <span className="ml-1.5 rounded-full bg-danger/10 px-1.5 py-0.5 text-[10px] font-semibold text-danger">
                          {t("masters.inactive")}
                        </span>
                      ) : null}
                    </span>
                    {confirmingRemoveId === m.id ? (
                      <span className="flex shrink-0 items-center gap-1.5 text-xs">
                        <button
                          type="button"
                          className="text-danger hover:underline disabled:opacity-50"
                          disabled={removeMut.isPending}
                          onClick={() => handleRemove(m.id)}
                        >
                          {removeMut.isPending ? <Loader2 className="size-3 animate-spin" /> : t("masters.confirmDelete")}
                        </button>
                        <button type="button" className="text-text-muted hover:underline" onClick={() => setConfirmingRemoveId(null)}>
                          {t("common.cancel")}
                        </button>
                      </span>
                    ) : (
                      <Button
                        size="icon-xs"
                        variant="ghost"
                        title={t("masters.delete")}
                        disabled={removeMut.isPending}
                        onClick={() => setConfirmingRemoveId(m.id)}
                      >
                        <Trash2 className="size-3.5 text-danger" />
                      </Button>
                    )}
                  </li>
                ))}
              </ul>
            )}

            <div className="flex items-center gap-1.5">
              <select
                value={pickerSpareId}
                onChange={(e) => setPickerSpareId(e.target.value)}
                disabled={availableToAdd.length === 0}
                className="h-9 flex-1 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none disabled:opacity-50"
              >
                <option value="">
                  {availableToAdd.length === 0 ? t("masters.complaintTypeSpares.noneToAdd") : t("masters.complaintTypeSpares.pickPlaceholder")}
                </option>
                {availableToAdd.map((s) => (
                  <option key={s.id} value={s.id}>
                    {s.name}
                    {s.sku ? ` (${s.sku})` : ""}
                  </option>
                ))}
              </select>
              <Button size="sm" className="gap-1" disabled={!pickerSpareId || addMut.isPending} onClick={handleAdd}>
                {addMut.isPending ? <Loader2 className="size-3.5 animate-spin" /> : <Plus className="size-3.5" />}
                {t("masters.complaintTypeSpares.add")}
              </Button>
            </div>
            {error ? <p className="text-xs text-danger">{error}</p> : null}
          </>
        )}
      </DialogContent>
    </Dialog>
  )
}
