import { useState } from "react"
import { useTranslation } from "react-i18next"
import { ArrowDown, ArrowUp, Loader2, Pencil, Plus, Trash2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { type CrudFieldDef } from "@/components/shared/EntityCrudTable"

function extractErrorMessage(e: unknown): string {
  if (e instanceof Error) return e.message
  if (typeof e === "object" && e !== null && "message" in e && typeof (e as { message: unknown }).message === "string") {
    return (e as { message: string }).message
  }
  return String(e)
}

function resolveOptions(field: CrudFieldDef, values: Record<string, string>) {
  if (!field.options) return []
  return typeof field.options === "function" ? field.options(values) : field.options
}

/**
 * Product Enquiry rebuild (2026-08-04), Phase 2 — generic admin-editable,
 * reorderable list. No drag-and-drop library exists anywhere in this
 * codebase, and the only prior sort_order column (appointment_slots) is
 * seeded once and never reordered by any UI — this is genuinely new, not an
 * extension of an existing pattern. Reordering uses up/down buttons (no new
 * dependency, keyboard-accessible, fits a short admin list) rather than
 * drag-and-drop. Add/edit reuses EntityCrudTable's CrudFieldDef shape so
 * callers (Tabs/Filters/Comparison Fields/CTA Config) share one field-def
 * type; the `renderExtra` render-prop lets each caller inject its own
 * bounded per-type config sub-fields into the form without this component
 * knowing their shape (keeps this generic, per "curated modules, not a
 * page builder").
 */
export function ReorderableListCard<T extends Record<string, unknown>>({
  fields,
  rows,
  getId,
  getLabel,
  getMeta,
  getSortOrder,
  getIsActive,
  loading,
  error,
  onRetry,
  onCreate,
  onUpdate,
  onDelete,
  onToggleActive,
  onReorder,
  isMutating,
  addLabel,
  emptyMessage,
  toFormValues,
  renderExtra,
}: {
  fields: CrudFieldDef[]
  rows: T[]
  getId: (row: T) => string
  getLabel: (row: T) => string
  getMeta?: (row: T) => string | null
  getSortOrder: (row: T) => number
  getIsActive: (row: T) => boolean
  loading: boolean
  error: string | null
  onRetry: () => void
  onCreate: (values: Record<string, string>) => Promise<unknown>
  onUpdate: (id: string, values: Record<string, string>) => Promise<unknown>
  onDelete: (id: string) => Promise<unknown>
  onToggleActive: (id: string, next: boolean) => Promise<unknown>
  onReorder: (id: string, sortOrder: number) => Promise<unknown>
  isMutating: boolean
  addLabel: string
  emptyMessage: string
  toFormValues: (row: T) => Record<string, string>
  renderExtra?: (values: Record<string, string>, setValues: (updater: (v: Record<string, string>) => Record<string, string>) => void) => React.ReactNode
}) {
  const { t } = useTranslation()
  const [formOpen, setFormOpen] = useState(false)
  const [editingId, setEditingId] = useState<string | null>(null)
  const [values, setValues] = useState<Record<string, string>>({})
  const [formError, setFormError] = useState<string | null>(null)
  const [confirmingDeleteId, setConfirmingDeleteId] = useState<string | null>(null)
  const [busyId, setBusyId] = useState<string | null>(null)

  const sorted = [...rows].sort((a, b) => getSortOrder(a) - getSortOrder(b))

  function openAddForm() {
    setEditingId(null)
    setValues(Object.fromEntries(fields.map((f) => [f.key, f.type === "select" ? (resolveOptions(f, {})[0]?.value ?? "") : ""])))
    setFormError(null)
    setFormOpen(true)
  }
  function openEditForm(row: T) {
    setEditingId(getId(row))
    setValues(toFormValues(row))
    setFormError(null)
    setFormOpen(true)
  }
  function closeForm() {
    setFormOpen(false)
    setEditingId(null)
    setFormError(null)
  }
  async function submit() {
    setFormError(null)
    try {
      if (editingId) await onUpdate(editingId, values)
      else await onCreate(values)
      closeForm()
    } catch (e) {
      setFormError(extractErrorMessage(e))
    }
  }
  async function handleDelete(id: string) {
    setFormError(null)
    setBusyId(id)
    try {
      await onDelete(id)
      setConfirmingDeleteId(null)
    } catch (e) {
      setFormError(extractErrorMessage(e))
    } finally {
      setBusyId(null)
    }
  }
  async function handleToggle(row: T) {
    setFormError(null)
    setBusyId(getId(row))
    try {
      await onToggleActive(getId(row), !getIsActive(row))
    } catch (e) {
      setFormError(extractErrorMessage(e))
    } finally {
      setBusyId(null)
    }
  }
  // Phase 6 hardening review: this swap is two independent, non-transactional
  // .update() calls — if the second fails after the first succeeds, two rows
  // can briefly share a sort_order. Accepted as-is (not wrapped in a new
  // RPC): this codebase already tolerates equivalent non-atomicity elsewhere
  // (e.g. ProductSparesPanel's add/remove are also two independent client
  // calls), the failure window is a single button click by a single admin,
  // and the worst case is a harmless tie-break on next sort — not worth a
  // new RPC just for this.
  async function handleMove(row: T, direction: -1 | 1) {
    const idx = sorted.findIndex((r) => getId(r) === getId(row))
    const swapWith = sorted[idx + direction]
    if (!swapWith) return
    setFormError(null)
    setBusyId(getId(row))
    try {
      await Promise.all([onReorder(getId(row), getSortOrder(swapWith)), onReorder(getId(swapWith), getSortOrder(row))])
    } catch (e) {
      setFormError(extractErrorMessage(e))
    } finally {
      setBusyId(null)
    }
  }

  if (loading) return <p className="py-4 text-center text-sm text-text-muted">{t("common.loading")}</p>
  if (error) {
    return (
      <div className="flex flex-col items-center gap-2 py-4 text-center">
        <p className="text-sm text-text-muted">{error}</p>
        <Button variant="outline" size="sm" onClick={onRetry}>
          {t("common.retry")}
        </Button>
      </div>
    )
  }

  return (
    <div className="space-y-2.5">
      {sorted.length === 0 ? (
        <p className="rounded-xl border border-dashed border-border px-3 py-2.5 text-xs text-text-muted">{emptyMessage}</p>
      ) : (
        <ul className="space-y-1">
          {sorted.map((row, i) => {
            const id = getId(row)
            const meta = getMeta?.(row)
            return (
              <li key={id} className="flex items-center justify-between gap-2 rounded-xl border border-border px-3 py-2">
                <div className="flex min-w-0 items-center gap-2">
                  <div className="flex shrink-0 items-center gap-0.5">
                    <Button size="icon-xs" variant="ghost" disabled={busyId === id || i === 0} onClick={() => handleMove(row, -1)}>
                      <ArrowUp className="size-3" />
                    </Button>
                    <Button size="icon-xs" variant="ghost" disabled={busyId === id || i === sorted.length - 1} onClick={() => handleMove(row, 1)}>
                      <ArrowDown className="size-3" />
                    </Button>
                  </div>
                  <span className="truncate text-sm text-text">
                    {getLabel(row)}
                    {meta ? <span className="ml-1.5 text-xs text-text-muted">{meta}</span> : null}
                  </span>
                </div>
                <div className="flex shrink-0 items-center gap-1">
                  <button
                    type="button"
                    disabled={busyId === id}
                    onClick={() => handleToggle(row)}
                    className={`rounded-full px-2 py-0.5 text-xs font-semibold ${
                      getIsActive(row) ? "bg-success/10 text-success" : "bg-danger/10 text-danger"
                    }`}
                  >
                    {getIsActive(row) ? t("masters.active") : t("masters.inactive")}
                  </button>
                  {confirmingDeleteId === id ? (
                    <span className="flex items-center gap-1.5 text-xs">
                      <button type="button" className="text-danger hover:underline disabled:opacity-50" disabled={busyId === id} onClick={() => handleDelete(id)}>
                        {busyId === id ? <Loader2 className="size-3 animate-spin" /> : t("masters.confirmDelete")}
                      </button>
                      <button type="button" className="text-text-muted hover:underline" onClick={() => setConfirmingDeleteId(null)}>
                        {t("common.cancel")}
                      </button>
                    </span>
                  ) : (
                    <>
                      <Button size="icon-xs" variant="ghost" title={t("masters.edit")} onClick={() => openEditForm(row)}>
                        <Pencil className="size-3.5" />
                      </Button>
                      <Button size="icon-xs" variant="ghost" title={t("masters.delete")} onClick={() => setConfirmingDeleteId(id)}>
                        <Trash2 className="size-3.5 text-danger" />
                      </Button>
                    </>
                  )}
                </div>
              </li>
            )
          })}
        </ul>
      )}

      {formError ? <p className="rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{formError}</p> : null}

      {formOpen ? (
        <div className="rounded-xl border border-border p-3.5">
          <div className="grid grid-cols-2 gap-3">
            {fields.map((f) => (
              <div key={f.key} className="space-y-1">
                <Label htmlFor={`f-${f.key}`}>{f.label}</Label>
                {f.type === "select" ? (
                  <select
                    id={`f-${f.key}`}
                    value={values[f.key] ?? ""}
                    onChange={(e) => setValues((v) => ({ ...v, [f.key]: e.target.value }))}
                    className="h-9 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
                  >
                    {resolveOptions(f, values).map((o) => (
                      <option key={o.value} value={o.value}>
                        {o.label}
                      </option>
                    ))}
                  </select>
                ) : (
                  <Input
                    id={`f-${f.key}`}
                    type={f.type}
                    step={f.step}
                    placeholder={f.placeholder}
                    value={values[f.key] ?? ""}
                    onChange={(e) => setValues((v) => ({ ...v, [f.key]: e.target.value }))}
                  />
                )}
              </div>
            ))}
          </div>
          {renderExtra ? <div className="mt-3">{renderExtra(values, setValues)}</div> : null}
          <div className="mt-3 flex justify-end gap-2">
            <Button size="sm" variant="ghost" onClick={closeForm}>
              {t("common.cancel")}
            </Button>
            <Button size="sm" onClick={submit} disabled={isMutating}>
              {isMutating ? <Loader2 className="size-3.5 animate-spin" /> : t("common.save")}
            </Button>
          </div>
        </div>
      ) : (
        <div className="flex justify-end">
          <Button size="sm" variant="accent" onClick={openAddForm} className="gap-1">
            <Plus className="size-3.5" />
            {addLabel}
          </Button>
        </div>
      )}
    </div>
  )
}
