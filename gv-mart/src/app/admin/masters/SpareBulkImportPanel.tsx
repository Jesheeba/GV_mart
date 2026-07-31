import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2, Upload } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import { useBulkCreateSpares } from "@/hooks/useMasters"
import type { TablesInsert } from "@/types/database"

type ParsedLine = { row: Omit<TablesInsert<"spares">, "org_id"> } | { error: string }

function parseLine(line: string): ParsedLine {
  const [name, sku, priceStr, hsn, stdStr] = line.split(",").map((p) => p.trim())
  if (!name) return { error: "name is required" }
  const price = priceStr ? Number(priceStr) : Number.NaN
  if (!priceStr || Number.isNaN(price) || price < 0) return { error: "price must be a non-negative number" }
  let standardTimeMinutes: number | null = null
  if (stdStr) {
    const n = Number(stdStr)
    if (Number.isNaN(n) || n < 0) return { error: "standard time must be a non-negative number" }
    standardTimeMinutes = n
  }
  return { row: { name, sku: sku || null, price, hsn_code: hsn || null, standard_time_minutes: standardTimeMinutes } }
}

/**
 * Task 6 (2026-07-30) — bulk import for Spare Parts. One line per spare,
 * comma-separated (name, sku, price, hsn code, standard time minutes) —
 * simple paste-in rather than a file upload, since this app has no existing
 * CSV file-parsing dependency and a paste box covers "export from a
 * spreadsheet, paste here" just as well for a masters list this size.
 */
export function SpareBulkImportPanel({ orgId, onClose }: { orgId: string | undefined; onClose: () => void }) {
  const { t } = useTranslation()
  const bulkCreate = useBulkCreateSpares()
  const [text, setText] = useState("")
  const [rowErrors, setRowErrors] = useState<string[]>([])
  const [successCount, setSuccessCount] = useState<number | null>(null)
  const [submitError, setSubmitError] = useState<string | null>(null)

  async function handleImport() {
    setRowErrors([])
    setSubmitError(null)
    setSuccessCount(null)

    const lines = text
      .split("\n")
      .map((l) => l.trim())
      .filter(Boolean)
    if (lines.length === 0 || !orgId) {
      setRowErrors([t("masters.spares.bulkImportNoRows")])
      return
    }

    const errors: string[] = []
    const validRows: TablesInsert<"spares">[] = []
    lines.forEach((line, i) => {
      const parsed = parseLine(line)
      if ("error" in parsed) errors.push(t("masters.spares.bulkImportRowError", { line: i + 1, error: parsed.error }))
      else validRows.push({ ...parsed.row, org_id: orgId })
    })
    if (errors.length > 0) {
      setRowErrors(errors)
      return
    }

    try {
      const created = await bulkCreate.mutateAsync(validRows)
      setSuccessCount(created.length)
      setText("")
    } catch (e) {
      setSubmitError(e instanceof Error ? e.message : String(e))
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
        <DialogTitle>{t("masters.spares.bulkImportTitle")}</DialogTitle>
        <DialogDescription>{t("masters.spares.bulkImportHint")}</DialogDescription>

        <textarea
          rows={8}
          value={text}
          onChange={(e) => setText(e.target.value)}
          placeholder={t("masters.spares.bulkImportPlaceholder")}
          className="w-full rounded-xl border border-border bg-surface px-3.5 py-2.5 font-mono text-xs text-text outline-none placeholder:text-text-muted focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"
        />

        {rowErrors.length > 0 ? (
          <ul className="space-y-0.5">
            {rowErrors.map((e, i) => (
              <li key={i} className="text-xs text-danger">
                {e}
              </li>
            ))}
          </ul>
        ) : null}
        {submitError ? <p className="text-xs text-danger">{submitError}</p> : null}
        {successCount != null ? <p className="text-xs text-success">{t("masters.spares.bulkImportSuccess", { count: successCount })}</p> : null}

        <div className="flex justify-end gap-2">
          <Button size="sm" variant="ghost" onClick={onClose}>
            {t("common.cancel")}
          </Button>
          <Button size="sm" className="gap-1.5" disabled={bulkCreate.isPending || !text.trim()} onClick={handleImport}>
            {bulkCreate.isPending ? <Loader2 className="size-3.5 animate-spin" /> : <Upload className="size-3.5" />}
            {t("masters.spares.bulkImportSubmit")}
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  )
}
