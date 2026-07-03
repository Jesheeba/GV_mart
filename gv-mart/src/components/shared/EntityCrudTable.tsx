import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2, Pencil, Plus, Trash2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"

export type CrudFieldDef = {
  key: string
  label: string
  type: "text" | "number" | "select"
  options?: { value: string; label: string }[]
  step?: string
  placeholder?: string
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
  onCreate: (values: Record<string, string>) => void
  onUpdate: (id: string, values: Record<string, string>) => void
  onDelete: (id: string) => void
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

  function openAddForm() {
    setEditingId(null)
    // Select fields must default to their first option's value, not "" — a
    // <select> visually shows its first <option> even when the controlled
    // value doesn't match any option, so an untouched select would submit ""
    // while displaying something else entirely (and "" fails enum columns).
    setValues(Object.fromEntries(fields.map((f) => [f.key, f.type === "select" ? (f.options?.[0]?.value ?? "") : ""])))
    setFormOpen(true)
  }
  function openEditForm(row: T) {
    setEditingId(getId(row))
    setValues(toFormValues(row))
    setFormOpen(true)
  }
  function closeForm() {
    setFormOpen(false)
    setEditingId(null)
  }
  function submit() {
    if (editingId) onUpdate(editingId, values)
    else onCreate(values)
    closeForm()
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
                className="text-danger hover:underline"
                onClick={() => {
                  onDelete(id)
                  setConfirmingDeleteId(null)
                }}
              >
                {t("masters.confirmDelete")}
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
      )
    },
  }

  return (
    <div className="space-y-3">
      <div className="flex justify-end">
        <Button size="sm" variant={formOpen && !editingId ? "outline" : "accent"} onClick={() => (formOpen ? closeForm() : openAddForm())}>
          <Plus className="size-3.5" />
          {addLabel}
        </Button>
      </div>

      {formOpen ? (
        <div className="rounded-xl border border-border p-3.5">
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
            {fields.map((f) => (
              <div key={f.key} className="space-y-1">
                <Label htmlFor={`f-${f.key}`}>{f.label}</Label>
                {f.type === "select" ? (
                  <select
                    id={`f-${f.key}`}
                    value={values[f.key] ?? ""}
                    onChange={(e) => setValues((v) => ({ ...v, [f.key]: e.target.value }))}
                    className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
                  >
                    {f.options?.map((o) => (
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
          <div className="mt-3 flex justify-end gap-2">
            <Button size="sm" variant="ghost" onClick={closeForm}>
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

