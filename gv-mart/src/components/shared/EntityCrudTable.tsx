import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2, Pencil, Plus, Trash2, X } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"

// Supabase/PostgREST rejections (PostgrestError) are plain objects with a
// `.message` string but are not `instanceof Error`, so a naive instanceof
// check falls through to `String(e)` → the literal text "[object Object]".
function extractErrorMessage(e: unknown): string {
  if (e instanceof Error) return e.message
  if (typeof e === "object" && e !== null && "message" in e && typeof (e as { message: unknown }).message === "string") {
    return (e as { message: string }).message
  }
  return String(e)
}

export type CrudFieldOption = { value: string; label: string }

export type CrudFieldDef = {
  key: string
  label: string
  type: "text" | "number" | "email" | "tel" | "url" | "select" | "textarea"
  // Either a static list, or derived from the form's current in-progress
  // values — e.g. a Model select filtered down to whichever Brand is
  // currently selected in the same open form. Re-evaluated on every render
  // while the form is open, so it stays in sync as the user edits other
  // fields.
  options?: CrudFieldOption[] | ((values: Record<string, string>) => CrudFieldOption[])
  step?: string
  placeholder?: string
  // Client-side type checking, enforced in submit() before onCreate/onUpdate
  // ever sees the values (this component isn't a real <form>, so a plain
  // `required` attribute on the <input> would never block the Save button).
  required?: boolean
  min?: number
  max?: number
  pattern?: string
  patternMessage?: string
}

function resolveOptions(field: CrudFieldDef, values: Record<string, string>): CrudFieldOption[] {
  if (!field.options) return []
  return typeof field.options === "function" ? field.options(values) : field.options
}

function validateFields(fields: CrudFieldDef[], values: Record<string, string>, t: (key: string, opts?: Record<string, unknown>) => string): string | null {
  for (const f of fields) {
    const raw = values[f.key] ?? ""
    const value = raw.trim()
    if (f.required && value === "") {
      return t("common.errors.fieldRequired", { field: f.label })
    }
    if (value === "") continue
    if (f.type === "number") {
      const n = Number(value)
      if (Number.isNaN(n)) return t("common.errors.fieldMustBeNumber", { field: f.label })
      if (f.min != null && n < f.min) return t("common.errors.fieldMin", { field: f.label, min: f.min })
      if (f.max != null && n > f.max) return t("common.errors.fieldMax", { field: f.label, max: f.max })
    }
    if (f.type === "email" && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value)) {
      return t("common.errors.fieldInvalid", { field: f.label })
    }
    if (f.type === "url") {
      try {
        new URL(value)
      } catch {
        return t("common.errors.fieldInvalid", { field: f.label })
      }
    }
    if (f.pattern && !new RegExp(`^(?:${f.pattern})$`).test(value)) {
      return f.patternMessage ?? t("common.errors.fieldInvalid", { field: f.label })
    }
  }
  return null
}

/**
 * Generic add/edit/delete table for simple flat master entities (Brands,
 * Spares, Gifts, Incentive Rules…). Entities with real relational structure
 * (Models, Products, AMC Plans, Settings) get bespoke UI instead.
 */
export function EntityCrudTable<T extends Record<string, unknown>>({
  fields,
  rows,
  columns,
  getId,
  loading,
  error,
  onRetry,
  onCreate,
  onUpdate,
  onDelete,
  isMutating,
  addLabel,
  emptyMessage,
  toFormValues,
}: {
  fields: CrudFieldDef[]
  rows: T[]
  columns: DataTableColumn<T>[]
  getId: (row: T) => string
  loading: boolean
  error: string | null
  onRetry: () => void
  onCreate: (values: Record<string, string>) => Promise<unknown>
  onUpdate: (id: string, values: Record<string, string>) => Promise<unknown>
  onDelete: (id: string) => Promise<unknown>
  isMutating: boolean
  addLabel: string
  emptyMessage: string
  toFormValues: (row: T) => Record<string, string>
}) {
  const { t } = useTranslation()
  const [formOpen, setFormOpen] = useState(false)
  const [editingId, setEditingId] = useState<string | null>(null)
  const [values, setValues] = useState<Record<string, string>>({})
  const [confirmingDeleteId, setConfirmingDeleteId] = useState<string | null>(null)
  // Mutations are fire-and-forget from this component's point of view unless
  // we await them — without this, a failed create/update/delete (network,
  // RLS, validation) closed the form / cleared the confirm row exactly as if
  // it had succeeded, with no error shown anywhere and the row silently
  // never appearing. Every onCreate/onUpdate/onDelete caller now passes a
  // mutateAsync-backed promise so we can catch and surface failures here.
  const [formError, setFormError] = useState<string | null>(null)
  const [isDeleting, setIsDeleting] = useState(false)
  const [confirmDiscardOpen, setConfirmDiscardOpen] = useState(false)

  function openAddForm() {
    setEditingId(null)
    // Select fields must default to their first option's value, not "" — a
    // <select> visually shows its first <option> even when the controlled
    // value doesn't match any option, so an untouched select would submit ""
    // while displaying something else entirely (and "" fails enum columns).
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
    setConfirmDiscardOpen(false)
  }
  // Discarding a fresh, still-empty Add form loses nothing, so it closes
  // immediately. Discarding an in-progress edit silently would lose real
  // unsaved changes with no way back, so that path requires an explicit
  // confirm step first (mirrors DraftBanner's discard-confirm pattern).
  function requestCloseForm() {
    if (editingId) setConfirmDiscardOpen(true)
    else closeForm()
  }
  async function submit() {
    setFormError(null)
    const validationError = validateFields(fields, values, t)
    if (validationError) {
      setFormError(validationError)
      return
    }
    try {
      if (editingId) await onUpdate(editingId, values)
      else await onCreate(values)
      closeForm()
    } catch (e) {
      setFormError(extractErrorMessage(e))
    }
  }
  async function handleConfirmDelete(id: string) {
    setFormError(null)
    setIsDeleting(true)
    try {
      await onDelete(id)
      setConfirmingDeleteId(null)
    } catch (e) {
      setFormError(extractErrorMessage(e))
    } finally {
      setIsDeleting(false)
    }
  }

  const actionColumn: DataTableColumn<T> = {
    key: "__actions",
    header: "",
    className: "text-right",
    render: (row) => {
      const id = getId(row)
      return (
        <div className="flex items-center justify-end gap-1">
          {confirmingDeleteId === id ? (
            <span className="flex items-center gap-1.5 text-xs">
              <button
                type="button"
                className="text-danger hover:underline disabled:opacity-50"
                disabled={isDeleting}
                onClick={() => handleConfirmDelete(id)}
              >
                {isDeleting ? <Loader2 className="size-3 animate-spin" /> : t("masters.confirmDelete")}
              </button>
              <button
                type="button"
                className="text-text-muted hover:underline disabled:opacity-50"
                disabled={isDeleting}
                onClick={() => setConfirmingDeleteId(null)}
              >
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
      )
    },
  }

  return (
    <div className="space-y-3">
      <div className="flex justify-end">
        <Button size="sm" variant={formOpen ? "outline" : "accent"} onClick={() => (formOpen ? requestCloseForm() : openAddForm())}>
          {formOpen ? <X className="size-3.5" /> : <Plus className="size-3.5" />}
          {formOpen ? t("common.cancel") : addLabel}
        </Button>
      </div>

      {formError ? <p className="rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{formError}</p> : null}

      {formOpen ? (
        <div className="rounded-xl border border-border p-3.5">
          {confirmDiscardOpen ? (
            <p className="mb-3 flex flex-wrap items-center gap-1.5 rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">
              {t("masters.confirmDiscard")}
              <button type="button" className="font-medium hover:underline" onClick={closeForm}>
                {t("common.yes")}
              </button>
              <span aria-hidden="true">·</span>
              <button type="button" className="font-medium hover:underline" onClick={() => setConfirmDiscardOpen(false)}>
                {t("common.no")}
              </button>
            </p>
          ) : null}
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
            {fields.map((f) => (
              <div key={f.key} className={`space-y-1 ${f.type === "textarea" ? "col-span-2 sm:col-span-3" : ""}`}>
                <Label htmlFor={`f-${f.key}`}>{f.label}</Label>
                {f.type === "select" ? (
                  <select
                    id={`f-${f.key}`}
                    value={values[f.key] ?? ""}
                    onChange={(e) => setValues((v) => ({ ...v, [f.key]: e.target.value }))}
                    className="h-11 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none transition-colors focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30 disabled:pointer-events-none disabled:cursor-not-allowed disabled:bg-surface-alt disabled:opacity-50 aria-invalid:border-destructive aria-invalid:ring-3 aria-invalid:ring-destructive/20"
                  >
                    {resolveOptions(f, values).map((o) => (
                      <option key={o.value} value={o.value}>
                        {o.label}
                      </option>
                    ))}
                  </select>
                ) : f.type === "textarea" ? (
                  <textarea
                    id={`f-${f.key}`}
                    rows={3}
                    placeholder={f.placeholder}
                    value={values[f.key] ?? ""}
                    onChange={(e) => setValues((v) => ({ ...v, [f.key]: e.target.value }))}
                    className="w-full min-w-0 rounded-xl border border-input bg-surface px-3.5 py-2.5 text-sm text-text transition-colors outline-none placeholder:text-text-muted focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"
                  />
                ) : (
                  <Input
                    id={`f-${f.key}`}
                    type={f.type}
                    step={f.step}
                    min={f.min}
                    max={f.max}
                    pattern={f.pattern}
                    placeholder={f.placeholder}
                    value={values[f.key] ?? ""}
                    onChange={(e) => setValues((v) => ({ ...v, [f.key]: e.target.value }))}
                  />
                )}
              </div>
            ))}
          </div>
          <div className="mt-3 flex justify-end gap-2">
            <Button size="sm" variant="ghost" onClick={requestCloseForm}>
              {t("common.cancel")}
            </Button>
            <Button size="sm" onClick={submit} disabled={isMutating}>
              {isMutating ? <Loader2 className="size-3.5 animate-spin" /> : t("common.save")}
            </Button>
          </div>
        </div>
      ) : null}

      <DataTable
        columns={[...columns, actionColumn]}
        rows={rows}
        rowKey={getId}
        loading={loading}
        error={error}
        onRetry={onRetry}
        emptyMessage={emptyMessage}
      />
    </div>
  )
}

