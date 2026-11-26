import { useId, useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2, Plus } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { normalizeLabel } from "@/lib/quickAdd"

/**
 * "+ Add" link beside a dropdown's label (2026-11-26). Opens a small inline
 * box; Save calls `onAdd` with the trimmed text, and the caller selects the
 * new value. Errors stay inline so the rest of the form keeps its input.
 */
export function QuickAddInline({
  onAdd,
  placeholder,
  maxLength = 60,
}: {
  /** Resolve when saved and selected; throw (an Error with a user-readable message) to keep the box open. */
  onAdd: (text: string) => Promise<void>
  placeholder: string
  maxLength?: number
}) {
  const { t } = useTranslation()
  const inputId = useId()
  const [open, setOpen] = useState(false)
  const [text, setText] = useState("")
  const [error, setError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const value = normalizeLabel(text)

  async function save() {
    if (!value || saving) return
    setSaving(true)
    setError(null)
    try {
      await onAdd(value)
      setText("")
      setOpen(false)
    } catch (e) {
      setError(e instanceof Error && e.message ? e.message : t("common.quickAddFailed"))
    } finally {
      setSaving(false)
    }
  }

  if (!open) {
    return (
      <button type="button" onClick={() => setOpen(true)} className="inline-flex items-center gap-1 text-xs font-medium text-accent hover:underline">
        <Plus className="size-3" />
        {t("common.addNew")}
      </button>
    )
  }

  return (
    <div className="space-y-1">
      <div className="flex items-center gap-1.5">
        <label htmlFor={inputId} className="sr-only">{placeholder}</label>
        <Input
          id={inputId}
          autoFocus
          value={text}
          maxLength={maxLength}
          placeholder={placeholder}
          aria-invalid={!!error}
          onChange={(e) => setText(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") {
              e.preventDefault()
              void save()
            } else if (e.key === "Escape") {
              e.preventDefault()
              setOpen(false)
              setError(null)
            }
          }}
          className="h-8"
        />
        <Button type="button" size="sm" disabled={!value || saving} onClick={() => void save()}>
          {saving ? <Loader2 className="size-3.5 animate-spin" /> : t("common.save")}
        </Button>
        <Button type="button" size="sm" variant="ghost" disabled={saving} onClick={() => { setOpen(false); setError(null) }}>
          {t("common.cancel")}
        </Button>
      </div>
      {error ? <p role="alert" className="text-xs text-danger">{error}</p> : null}
    </div>
  )
}
