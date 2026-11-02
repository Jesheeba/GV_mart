import { useEffect, useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2, Plus, Trash2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogTitle } from "@/components/ui/dialog"
import { Input } from "@/components/ui/input"
import { useToast } from "@/components/ui/toast-context"
import {
  useApplyUpdatedSchedule,
  useCreateProductSpareSchedule,
  useDeleteProductSpareSchedule,
  usePreviewApplyUpdatedSchedule,
  useProductLifecycleConfig,
  useProductSpareSchedules,
  useUpdateProductSpareSchedule,
  useUpsertProductLifecycleConfig,
} from "@/hooks/useProductLifecycle"
import { sparesHooks } from "@/hooks/useMasters"
import { useProfile } from "@/hooks/useProfile"
import type { ProductSpareScheduleRow } from "@/services/productLifecycle"
import type { LifetimeUnit } from "@/types/productLifecycle"
import { validateLifetime, validateSpareSchedules } from "@/types/productLifecycle"

// Same "Supabase/PostgREST rejections aren't `instanceof Error`" helper as
// ProductSparesPanel.tsx / ProductComplaintsPanel.tsx / EntityCrudTable —
// duplicated for the same reason (small, not worth a shared utility for).
function extractErrorMessage(e: unknown): string {
  if (e instanceof Error) return e.message
  if (typeof e === "object" && e !== null && "message" in e && typeof (e as { message: unknown }).message === "string") {
    return (e as { message: string }).message
  }
  return String(e)
}

type UnitSelectProps = { value: LifetimeUnit; onChange: (unit: LifetimeUnit) => void; disabled?: boolean }

function UnitSelect({ value, onChange, disabled }: UnitSelectProps) {
  const { t } = useTranslation()
  return (
    <select
      value={value}
      disabled={disabled}
      onChange={(e) => onChange(e.target.value as LifetimeUnit)}
      className="h-10 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none disabled:opacity-50"
    >
      <option value="months">{t("productLifecycle.lifetime.unit.months")}</option>
      <option value="years">{t("productLifecycle.lifetime.unit.years")}</option>
    </select>
  )
}

/**
 * New spare-schedule rows start here before they exist server-side — same
 * "local draft, explicit per-row Save" shape as the persisted rows below,
 * just without an `id` yet.
 */
type DraftRow = { key: string; spareId: string | null; label: string; intervalValue: string; intervalUnit: LifetimeUnit }

function emptyDraftRow(): DraftRow {
  return { key: `draft-${Math.random().toString(36).slice(2)}`, spareId: null, label: "", intervalValue: "", intervalUnit: "months" }
}

/**
 * Product Lifecycle & Automated Service Reminder System — W1 (masters form).
 * Opened from a row action in Masters > Products (ProductsTab.tsx), same
 * per-product-connector shape as ProductSparesPanel.tsx. The whole
 * /admin/masters route is already master-only (see nav.ts roles: ["master"]),
 * so the panel itself needs no extra role check — except the "apply to
 * existing installations" action below, which re-checks role defensively the
 * same way AutoAssignLeadsCard.tsx does for its own sensitive, DB-wide action.
 */
export function ProductLifecyclePanel({
  orgId,
  productId,
  productName,
  onClose,
}: {
  orgId: string | undefined
  productId: string
  productName: string
  onClose: () => void
}) {
  const { t } = useTranslation()
  const { toast } = useToast()
  const { data: profile } = useProfile()
  const isMaster = profile?.role === "master"

  const { data: config, isLoading: configLoading, isError: configError, refetch: refetchConfig } = useProductLifecycleConfig(productId)
  const { data: scheduleRows, isLoading: rowsLoading, isError: rowsError, refetch: refetchRows } = useProductSpareSchedules(productId)
  const { data: allSpares } = sparesHooks.useList(orgId)

  const upsertConfigMut = useUpsertProductLifecycleConfig(productId)
  const createRowMut = useCreateProductSpareSchedule(productId)
  const updateRowMut = useUpdateProductSpareSchedule(productId)
  const deleteRowMut = useDeleteProductSpareSchedule(productId)
  const previewMut = usePreviewApplyUpdatedSchedule()
  const applyMut = useApplyUpdatedSchedule()

  // ── Lifetime ────────────────────────────────────────────────────────────
  const [lifetimeValue, setLifetimeValue] = useState("")
  const [lifetimeUnit, setLifetimeUnit] = useState<LifetimeUnit>("months")
  const [lifetimeError, setLifetimeError] = useState<string | null>(null)

  useEffect(() => {
    if (config) {
      setLifetimeValue(String(config.lifetime_value))
      setLifetimeUnit(config.lifetime_unit)
    }
  }, [config])

  async function handleSaveLifetime() {
    if (!orgId) return
    setLifetimeError(null)
    const parsed = Number(lifetimeValue)
    const result = validateLifetime({ lifetimeValue: parsed, lifetimeUnit })
    if (!result.valid) {
      setLifetimeError(t("productLifecycle.lifetime.errors.valueInvalid"))
      return
    }
    try {
      await upsertConfigMut.mutateAsync({ orgId, lifetimeValue: parsed, lifetimeUnit })
      toast.success(t("productLifecycle.lifetime.saved"))
    } catch (e) {
      toast.error(extractErrorMessage(e) || t("productLifecycle.lifetime.saveFailed"))
    }
  }

  // ── Spare schedule rows ───────────────────────────────────────────────
  // Edit state for already-persisted rows, keyed by row id.
  const [rowEdits, setRowEdits] = useState<Record<string, { spareId: string | null; label: string; intervalValue: string; intervalUnit: LifetimeUnit }>>({})
  const [rowErrors, setRowErrors] = useState<Record<string, { label?: string; intervalValue?: string }>>({})
  const [confirmingRemoveId, setConfirmingRemoveId] = useState<string | null>(null)
  const [draftRows, setDraftRows] = useState<DraftRow[]>([])
  const [draftErrors, setDraftErrors] = useState<Record<string, { label?: string; intervalValue?: string }>>({})

  function editsFor(row: ProductSpareScheduleRow) {
    return (
      rowEdits[row.id] ?? {
        spareId: row.spare_id,
        label: row.label,
        intervalValue: String(row.interval_value),
        intervalUnit: row.interval_unit,
      }
    )
  }

  function patchRowEdit(row: ProductSpareScheduleRow, patch: Partial<{ spareId: string | null; label: string; intervalValue: string; intervalUnit: LifetimeUnit }>) {
    setRowEdits((prev) => ({ ...prev, [row.id]: { ...editsFor(row), ...patch } }))
  }

  async function handleSaveRow(row: ProductSpareScheduleRow) {
    const edits = editsFor(row)
    const parsedInterval = Number(edits.intervalValue)
    const check = validateSpareSchedules([{ spareId: edits.spareId, label: edits.label, intervalValue: parsedInterval, intervalUnit: edits.intervalUnit }])
    setRowErrors((prev) => ({ ...prev, [row.id]: check.rowErrors[0] }))
    if (!check.valid) return
    try {
      await updateRowMut.mutateAsync({
        id: row.id,
        patch: { spare_id: edits.spareId, label: edits.label.trim(), interval_value: parsedInterval, interval_unit: edits.intervalUnit },
      })
      setRowEdits((prev) => {
        const next = { ...prev }
        delete next[row.id]
        return next
      })
      toast.success(t("productLifecycle.spares.saved"))
    } catch (e) {
      toast.error(extractErrorMessage(e) || t("productLifecycle.spares.saveFailed"))
    }
  }

  async function handleRemoveRow(id: string) {
    try {
      await deleteRowMut.mutateAsync(id)
      setConfirmingRemoveId(null)
    } catch (e) {
      toast.error(extractErrorMessage(e) || t("productLifecycle.spares.removeFailed"))
    }
  }

  function handleAddDraftRow() {
    setDraftRows((prev) => [...prev, emptyDraftRow()])
  }

  function patchDraftRow(key: string, patch: Partial<DraftRow>) {
    setDraftRows((prev) => prev.map((r) => (r.key === key ? { ...r, ...patch } : r)))
  }

  function removeDraftRow(key: string) {
    setDraftRows((prev) => prev.filter((r) => r.key !== key))
    setDraftErrors((prev) => {
      const next = { ...prev }
      delete next[key]
      return next
    })
  }

  async function handleSaveDraftRow(draft: DraftRow) {
    if (!orgId) return
    const parsedInterval = Number(draft.intervalValue)
    const check = validateSpareSchedules([{ spareId: draft.spareId, label: draft.label, intervalValue: parsedInterval, intervalUnit: draft.intervalUnit }])
    setDraftErrors((prev) => ({ ...prev, [draft.key]: check.rowErrors[0] }))
    if (!check.valid) return
    try {
      await createRowMut.mutateAsync({
        org_id: orgId,
        spare_id: draft.spareId,
        label: draft.label.trim(),
        interval_value: parsedInterval,
        interval_unit: draft.intervalUnit,
      })
      removeDraftRow(draft.key)
      toast.success(t("productLifecycle.spares.saved"))
    } catch (e) {
      toast.error(extractErrorMessage(e) || t("productLifecycle.spares.saveFailed"))
    }
  }

  // ── Apply updated schedule to existing installations ───────────────────
  const [previewCount, setPreviewCount] = useState<{ units: number; parts: number } | null>(null)
  const [showApplyConfirm, setShowApplyConfirm] = useState(false)

  async function handlePreviewApply() {
    setShowApplyConfirm(false)
    setPreviewCount(null)
    try {
      const rows = await previewMut.mutateAsync(productId)
      const units = new Set(rows.map((r) => r.installed_product_id)).size
      const parts = rows.reduce((sum, r) => sum + (r.parts_to_add ?? 0), 0)
      setPreviewCount({ units, parts })
      setShowApplyConfirm(true)
    } catch (e) {
      toast.error(extractErrorMessage(e) || t("productLifecycle.apply.previewFailed"))
    }
  }

  async function handleConfirmApply() {
    try {
      const count = await applyMut.mutateAsync(productId)
      toast.success(t("productLifecycle.apply.applied", { count }))
      setShowApplyConfirm(false)
      setPreviewCount(null)
    } catch (e) {
      toast.error(extractErrorMessage(e) || t("productLifecycle.apply.applyFailed"))
    }
  }

  const loading = configLoading || rowsLoading
  const hasError = configError || rowsError
  const spareOptions = allSpares ?? []

  return (
    <Dialog
      open
      onOpenChange={(next) => {
        if (!next) onClose()
      }}
    >
      <DialogContent className="max-w-lg">
        <DialogTitle>
          {t("productLifecycle.title")} — {productName}
        </DialogTitle>

        {hasError ? (
          <div className="flex flex-col items-center gap-2 py-6 text-center">
            <p className="text-sm text-text-muted">{t("productLifecycle.loadFailed")}</p>
            <Button
              variant="outline"
              size="sm"
              onClick={() => {
                refetchConfig()
                refetchRows()
              }}
            >
              {t("common.retry")}
            </Button>
          </div>
        ) : loading ? (
          <p className="py-4 text-center text-sm text-text-muted">{t("common.loading")}</p>
        ) : (
          <>
            {/* Lifetime */}
            <section className="space-y-2 rounded-xl border border-border p-3">
              <h3 className="text-sm font-semibold text-text">{t("productLifecycle.lifetime.title")}</h3>
              <p className="text-xs text-text-muted">{t("productLifecycle.lifetime.hint")}</p>
              <div className="flex items-center gap-1.5">
                <Input
                  type="number"
                  min={1}
                  step={1}
                  value={lifetimeValue}
                  onChange={(e) => setLifetimeValue(e.target.value)}
                  placeholder={t("productLifecycle.lifetime.valueLabel")}
                  aria-label={t("productLifecycle.lifetime.valueLabel")}
                  className="flex-1"
                />
                <UnitSelect value={lifetimeUnit} onChange={setLifetimeUnit} />
                <Button size="sm" disabled={upsertConfigMut.isPending} onClick={handleSaveLifetime}>
                  {upsertConfigMut.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("productLifecycle.lifetime.save")}
                </Button>
              </div>
              {lifetimeError ? <p className="text-xs text-danger">{lifetimeError}</p> : null}
            </section>

            {/* Spare schedule repeater */}
            <section className="space-y-2 rounded-xl border border-border p-3">
              <h3 className="text-sm font-semibold text-text">{t("productLifecycle.spares.title")}</h3>

              {(scheduleRows ?? []).length === 0 && draftRows.length === 0 ? (
                <p className="rounded-xl border border-dashed border-border px-3 py-2.5 text-xs text-text-muted">
                  {t("productLifecycle.spares.empty")}
                </p>
              ) : null}

              <ul className="space-y-2">
                {(scheduleRows ?? []).map((row) => {
                  const edits = editsFor(row)
                  const errors = rowErrors[row.id] ?? {}
                  return (
                    <li key={row.id} className="space-y-1.5 rounded-xl border border-border p-2.5">
                      <div className="flex items-center gap-1.5">
                        <select
                          value={edits.spareId ?? ""}
                          onChange={(e) => {
                            const spareId = e.target.value || null
                            const picked = spareOptions.find((s) => s.id === spareId)
                            patchRowEdit(row, { spareId, label: !edits.label && picked ? picked.name : edits.label })
                          }}
                          className="h-9 flex-1 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
                        >
                          <option value="">{t("productLifecycle.spares.noSparePicked")}</option>
                          {spareOptions.map((s) => (
                            <option key={s.id} value={s.id}>
                              {s.name}
                              {s.sku ? ` (${s.sku})` : ""}
                            </option>
                          ))}
                        </select>
                        {confirmingRemoveId === row.id ? (
                          <span className="flex shrink-0 items-center gap-1.5 text-xs">
                            <button
                              type="button"
                              className="text-danger hover:underline disabled:opacity-50"
                              disabled={deleteRowMut.isPending}
                              onClick={() => handleRemoveRow(row.id)}
                            >
                              {deleteRowMut.isPending ? <Loader2 className="size-3 animate-spin" /> : t("productLifecycle.spares.confirmRemove")}
                            </button>
                            <button type="button" className="text-text-muted hover:underline" onClick={() => setConfirmingRemoveId(null)}>
                              {t("common.cancel")}
                            </button>
                          </span>
                        ) : (
                          <Button size="icon-xs" variant="ghost" title={t("productLifecycle.spares.remove")} onClick={() => setConfirmingRemoveId(row.id)}>
                            <Trash2 className="size-3.5 text-danger" />
                          </Button>
                        )}
                      </div>
                      <Input
                        value={edits.label}
                        onChange={(e) => patchRowEdit(row, { label: e.target.value })}
                        placeholder={t("productLifecycle.spares.labelPlaceholder")}
                        aria-label={t("productLifecycle.spares.labelLabel")}
                      />
                      {errors.label ? <p className="text-xs text-danger">{t(`productLifecycle.spares.errors.${errors.label}`)}</p> : null}
                      <div className="flex items-center gap-1.5">
                        <Input
                          type="number"
                          min={1}
                          step={1}
                          value={edits.intervalValue}
                          onChange={(e) => patchRowEdit(row, { intervalValue: e.target.value })}
                          placeholder={t("productLifecycle.spares.intervalLabel")}
                          aria-label={t("productLifecycle.spares.intervalLabel")}
                          className="flex-1"
                        />
                        <UnitSelect value={edits.intervalUnit} onChange={(unit) => patchRowEdit(row, { intervalUnit: unit })} />
                        <Button size="icon-xs" disabled={updateRowMut.isPending} onClick={() => handleSaveRow(row)} title={t("productLifecycle.spares.save")}>
                          {updateRowMut.isPending ? <Loader2 className="size-3 animate-spin" /> : t("productLifecycle.spares.save")}
                        </Button>
                      </div>
                      {errors.intervalValue ? <p className="text-xs text-danger">{t(`productLifecycle.spares.errors.${errors.intervalValue}`)}</p> : null}
                    </li>
                  )
                })}

                {draftRows.map((draft) => {
                  const errors = draftErrors[draft.key] ?? {}
                  return (
                    <li key={draft.key} className="space-y-1.5 rounded-xl border border-dashed border-border p-2.5">
                      <div className="flex items-center gap-1.5">
                        <select
                          value={draft.spareId ?? ""}
                          onChange={(e) => {
                            const spareId = e.target.value || null
                            const picked = spareOptions.find((s) => s.id === spareId)
                            patchDraftRow(draft.key, { spareId, label: !draft.label && picked ? picked.name : draft.label })
                          }}
                          className="h-9 flex-1 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
                        >
                          <option value="">{t("productLifecycle.spares.noSparePicked")}</option>
                          {spareOptions.map((s) => (
                            <option key={s.id} value={s.id}>
                              {s.name}
                              {s.sku ? ` (${s.sku})` : ""}
                            </option>
                          ))}
                        </select>
                        <Button size="icon-xs" variant="ghost" title={t("productLifecycle.spares.remove")} onClick={() => removeDraftRow(draft.key)}>
                          <Trash2 className="size-3.5 text-danger" />
                        </Button>
                      </div>
                      <Input
                        value={draft.label}
                        onChange={(e) => patchDraftRow(draft.key, { label: e.target.value })}
                        placeholder={t("productLifecycle.spares.labelPlaceholder")}
                        aria-label={t("productLifecycle.spares.labelLabel")}
                      />
                      {errors.label ? <p className="text-xs text-danger">{t(`productLifecycle.spares.errors.${errors.label}`)}</p> : null}
                      <div className="flex items-center gap-1.5">
                        <Input
                          type="number"
                          min={1}
                          step={1}
                          value={draft.intervalValue}
                          onChange={(e) => patchDraftRow(draft.key, { intervalValue: e.target.value })}
                          placeholder={t("productLifecycle.spares.intervalLabel")}
                          aria-label={t("productLifecycle.spares.intervalLabel")}
                          className="flex-1"
                        />
                        <UnitSelect value={draft.intervalUnit} onChange={(unit) => patchDraftRow(draft.key, { intervalUnit: unit })} />
                        <Button size="icon-xs" disabled={createRowMut.isPending} onClick={() => handleSaveDraftRow(draft)} title={t("productLifecycle.spares.save")}>
                          {createRowMut.isPending ? <Loader2 className="size-3 animate-spin" /> : t("productLifecycle.spares.save")}
                        </Button>
                      </div>
                      {errors.intervalValue ? <p className="text-xs text-danger">{t(`productLifecycle.spares.errors.${errors.intervalValue}`)}</p> : null}
                    </li>
                  )
                })}
              </ul>

              <Button size="sm" variant="outline" className="gap-1" onClick={handleAddDraftRow}>
                <Plus className="size-3.5" />
                {t("productLifecycle.spares.addRow")}
              </Button>

              <p className="rounded-xl border border-dashed border-border bg-surface-alt px-3 py-2 text-xs text-text-muted">
                {t("productLifecycle.retroactiveNote")}
              </p>
            </section>

            {/* Apply to existing installations — master-only defensive check,
                same pattern as AutoAssignLeadsCard.tsx, even though the whole
                /admin/masters route is already master-only. */}
            {isMaster ? (
              <section className="space-y-2 rounded-xl border border-border p-3">
                {!showApplyConfirm ? (
                  <Button size="sm" variant="outline" disabled={previewMut.isPending} onClick={handlePreviewApply}>
                    {previewMut.isPending ? (
                      <>
                        <Loader2 className="size-3.5 animate-spin" /> {t("productLifecycle.apply.previewing")}
                      </>
                    ) : (
                      t("productLifecycle.apply.button")
                    )}
                  </Button>
                ) : (
                  <div className="space-y-2">
                    <p className="text-sm text-text">
                      {previewCount && previewCount.units > 0
                        ? t("productLifecycle.apply.previewResult", { count: previewCount.units, parts: previewCount.parts })
                        : t("productLifecycle.apply.previewEmpty")}
                    </p>
                    <div className="flex items-center gap-1.5">
                      <Button size="sm" disabled={applyMut.isPending || !previewCount || previewCount.units === 0} onClick={handleConfirmApply}>
                        {applyMut.isPending ? (
                          <>
                            <Loader2 className="size-3.5 animate-spin" /> {t("productLifecycle.apply.applying")}
                          </>
                        ) : (
                          t("productLifecycle.apply.confirm")
                        )}
                      </Button>
                      <Button
                        size="sm"
                        variant="ghost"
                        onClick={() => {
                          setShowApplyConfirm(false)
                          setPreviewCount(null)
                        }}
                      >
                        {t("common.cancel")}
                      </Button>
                    </div>
                  </div>
                )}
              </section>
            ) : null}
          </>
        )}
      </DialogContent>
    </Dialog>
  )
}
