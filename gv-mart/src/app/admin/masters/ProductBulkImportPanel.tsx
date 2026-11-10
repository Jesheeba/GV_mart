import { useRef, useState } from "react"
import { useTranslation } from "react-i18next"
import { AlertTriangle, CheckCircle2, Download, Loader2, Upload, XCircle } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogTitle } from "@/components/ui/dialog"
import { useCreateProductWithStock } from "@/hooks/useMasters"
import { parseCsv, downloadCsv } from "@/lib/csv"
import type { Enums } from "@/types/database"
import { CATEGORIES } from "./ProductsTab"

export const TEMPLATE_HEADER = ["name", "brand", "model", "category", "price", "hsn", "item_code", "opening_stock", "reorder_level"]
const TEMPLATE_EXAMPLE_ROW = ["Aquafresh RO 7L", "Aquafresh", "AF-700", "ro", "12000", "84212100", "AF700-01", "5", "10"]

export type ExistingProduct = { id: string; name: string; brand_id: string; model_id: string; item_code: string | null }
export type BrandRow = { id: string; name: string }
export type ModelRow = { id: string; name: string; brand_id: string }

type Resolved = {
  name: string
  brandId: string
  modelId: string
  category: Enums<"brand_category">
  price: number
  hsnCode: string | null
  itemCode: string | null
  openingStock: number | null
  minStock: number | null
}

type ParsedRow = {
  rowNum: number
  raw: Record<string, string>
  errors: string[]
  isDuplicate: boolean
  resolved: Resolved | null
}

type ImportOutcome = { rowNum: number; name: string; status: "created" | "skipped" | "failed"; detail?: string }

function col(raw: Record<string, string>, key: string): string {
  return (raw[key] ?? "").trim()
}

export function parseRows(
  csvRows: string[][],
  brands: BrandRow[],
  models: ModelRow[],
  existingProducts: ExistingProduct[]
): { rows: ParsedRow[]; headerError: string | null } {
  if (csvRows.length === 0) return { rows: [], headerError: "empty file" }
  const header = csvRows[0].map((h) => h.trim().toLowerCase())
  const missingCols = TEMPLATE_HEADER.filter((h) => h !== "hsn" && h !== "item_code" && h !== "opening_stock" && h !== "reorder_level" && !header.includes(h))
  if (missingCols.length > 0) {
    return { rows: [], headerError: `missing required column(s): ${missingCols.join(", ")}` }
  }

  const seenItemCodesInFile = new Set<string>()
  const existingItemCodes = new Set(existingProducts.filter((p) => p.item_code).map((p) => p.item_code!.toLowerCase()))

  const parsed: ParsedRow[] = csvRows.slice(1).map((cells, idx) => {
    const raw: Record<string, string> = {}
    header.forEach((h, i) => (raw[h] = cells[i] ?? ""))
    const rowNum = idx + 2 // 1-indexed + header row
    const errors: string[] = []

    const name = col(raw, "name")
    if (!name) errors.push("name is required")

    const brandName = col(raw, "brand")
    const brand = brands.find((b) => b.name.trim().toLowerCase() === brandName.toLowerCase())
    if (!brandName) errors.push("brand is required")
    else if (!brand) errors.push(`brand not found: "${brandName}" — add it in Masters > Brands first`)

    const modelName = col(raw, "model")
    const model = brand ? models.find((m) => m.brand_id === brand.id && m.name.trim().toLowerCase() === modelName.toLowerCase()) : undefined
    if (!modelName) errors.push("model is required")
    else if (brand && !model) errors.push(`model not found for brand "${brandName}": "${modelName}" — add it in Masters > Models first`)

    const categoryRaw = col(raw, "category").toLowerCase()
    const category = (CATEGORIES as readonly string[]).includes(categoryRaw) ? (categoryRaw as Enums<"brand_category">) : null
    if (!categoryRaw) errors.push("category is required")
    else if (!category) errors.push(`category must be one of: ${CATEGORIES.join(", ")}`)

    const priceRaw = col(raw, "price")
    const price = Number(priceRaw)
    if (!priceRaw) errors.push("price is required")
    else if (Number.isNaN(price) || price < 0) errors.push("price must be a number ≥ 0")

    const hsnRaw = col(raw, "hsn")
    if (hsnRaw && !/^\d{4,8}$/.test(hsnRaw)) errors.push("hsn must be 4–8 digits")

    const itemCodeRaw = col(raw, "item_code")
    if (itemCodeRaw) {
      if (!/^[A-Za-z0-9_-]+$/.test(itemCodeRaw)) errors.push("item_code may only contain letters, numbers, _ and -")
      else {
        const key = itemCodeRaw.toLowerCase()
        if (existingItemCodes.has(key)) errors.push(`item_code "${itemCodeRaw}" is already used by an existing product`)
        else if (seenItemCodesInFile.has(key)) errors.push(`item_code "${itemCodeRaw}" is duplicated elsewhere in this file`)
        else seenItemCodesInFile.add(key)
      }
    }

    const openingStockRaw = col(raw, "opening_stock")
    let openingStock: number | null = null
    if (openingStockRaw) {
      openingStock = Number(openingStockRaw)
      if (Number.isNaN(openingStock) || openingStock < 0) errors.push("opening_stock must be a whole number ≥ 0")
    }

    const reorderRaw = col(raw, "reorder_level")
    let minStock: number | null = null
    if (reorderRaw) {
      minStock = Number(reorderRaw)
      if (Number.isNaN(minStock) || minStock < 0) errors.push("reorder_level must be a whole number ≥ 0")
    }

    const isDuplicate =
      !!brand &&
      !!model &&
      !!name &&
      existingProducts.some((p) => p.brand_id === brand.id && p.model_id === model.id && p.name.trim().toLowerCase() === name.toLowerCase())

    const resolved: Resolved | null =
      errors.length === 0 && brand && model && category
        ? {
            name,
            brandId: brand.id,
            modelId: model.id,
            category,
            price,
            hsnCode: hsnRaw || null,
            itemCode: itemCodeRaw || null,
            openingStock,
            minStock,
          }
        : null

    return { rowNum, raw, errors, isDuplicate, resolved }
  })

  return { rows: parsed, headerError: null }
}

/**
 * Masters > Products CSV bulk import, item 3 of the inventory-opening-stock
 * build (2026-11-10). Writes NOTHING until the owner reviews a preview and
 * clicks Confirm — brand/model/category are matched by name against the
 * org's existing masters data and NEVER auto-created (an unmatched
 * brand/model is reported as a row error, not silently invented). Each
 * accepted row is created through the same create_product_with_stock RPC
 * the single-row Add Product form uses (ProductsTab.tsx) — same validation,
 * same RLS, same inventory-row-on-create behaviour — called once per row
 * rather than adding a second bulk RPC for this.
 */
export function ProductBulkImportPanel({
  orgId,
  brands,
  models,
  existingProducts,
  onClose,
  onImported,
}: {
  orgId: string | undefined
  brands: BrandRow[]
  models: ModelRow[]
  existingProducts: ExistingProduct[]
  onClose: () => void
  onImported: () => void
}) {
  const { t } = useTranslation()
  const createMut = useCreateProductWithStock()
  const fileInputRef = useRef<HTMLInputElement>(null)

  const [step, setStep] = useState<"upload" | "preview" | "importing" | "done">("upload")
  const [fileName, setFileName] = useState<string | null>(null)
  const [headerError, setHeaderError] = useState<string | null>(null)
  const [rows, setRows] = useState<ParsedRow[]>([])
  const [outcomes, setOutcomes] = useState<ImportOutcome[]>([])
  const [importProgress, setImportProgress] = useState(0)

  function handleDownloadTemplate() {
    downloadCsv("gv-mart-products-template.csv", [TEMPLATE_HEADER, TEMPLATE_EXAMPLE_ROW])
  }

  async function handleFileSelected(file: File) {
    setFileName(file.name)
    const text = await file.text()
    const csvRows = parseCsv(text)
    const { rows: parsedRows, headerError: hErr } = parseRows(csvRows, brands, models, existingProducts)
    setHeaderError(hErr)
    setRows(parsedRows)
    setOutcomes([])
    if (!hErr) setStep("preview")
  }

  const validRows = rows.filter((r) => r.resolved)
  const errorRows = rows.filter((r) => !r.resolved)
  const duplicateRows = rows.filter((r) => r.isDuplicate && r.resolved)

  async function handleConfirmImport() {
    setStep("importing")
    setImportProgress(0)
    const results: ImportOutcome[] = []
    for (const row of rows) {
      if (!row.resolved) {
        results.push({ rowNum: row.rowNum, name: col(row.raw, "name") || `row ${row.rowNum}`, status: "skipped", detail: row.errors.join("; ") })
        setImportProgress(results.length)
        continue
      }
      try {
        await createMut.mutateAsync({
          orgId: orgId!,
          name: row.resolved.name,
          brandId: row.resolved.brandId,
          modelId: row.resolved.modelId,
          category: row.resolved.category,
          price: row.resolved.price,
          costPrice: null,
          hsnCode: row.resolved.hsnCode,
          itemCode: row.resolved.itemCode,
          warrantyMonths: null,
          standardTimeMinutes: null,
          installationCharge: null,
          description: null,
          openingStock: row.resolved.openingStock,
          minStock: row.resolved.minStock,
        })
        results.push({ rowNum: row.rowNum, name: row.resolved.name, status: "created" })
      } catch (e) {
        const detail = e instanceof Error ? e.message : String(e)
        results.push({ rowNum: row.rowNum, name: row.resolved.name, status: "failed", detail })
      }
      setImportProgress(results.length)
    }
    setOutcomes(results)
    setStep("done")
    onImported()
  }

  const createdCount = outcomes.filter((o) => o.status === "created").length
  const skippedCount = outcomes.filter((o) => o.status === "skipped").length
  const failedCount = outcomes.filter((o) => o.status === "failed").length

  return (
    <Dialog open onOpenChange={(next) => !next && onClose()}>
      <DialogContent className="max-h-[85vh] max-w-3xl overflow-y-auto">
        <DialogTitle className="flex items-center gap-1.5">
          <Upload className="size-4 text-accent" />
          {t("masters.products.bulkImport.title")}
        </DialogTitle>

        {step === "upload" ? (
          <div className="space-y-3">
            <p className="text-sm text-text-muted">{t("masters.products.bulkImport.intro")}</p>
            <Button variant="outline" size="sm" onClick={handleDownloadTemplate}>
              <Download className="size-3.5" />
              {t("masters.products.bulkImport.downloadTemplate")}
            </Button>
            <div className="rounded-xl border border-dashed border-border p-4 text-center">
              <input
                ref={fileInputRef}
                type="file"
                accept=".csv,text/csv"
                className="hidden"
                onChange={(e) => {
                  const f = e.target.files?.[0]
                  if (f) handleFileSelected(f)
                }}
              />
              <Button size="sm" onClick={() => fileInputRef.current?.click()}>
                <Upload className="size-3.5" />
                {t("masters.products.bulkImport.chooseFile")}
              </Button>
              {fileName ? <p className="mt-2 text-xs text-text-muted">{fileName}</p> : null}
            </div>
            {headerError ? <p className="rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{headerError}</p> : null}
          </div>
        ) : null}

        {step === "preview" ? (
          <div className="space-y-3">
            <div className="flex flex-wrap gap-3 text-sm">
              <span className="flex items-center gap-1 text-success">
                <CheckCircle2 className="size-4" /> {t("masters.products.bulkImport.validCount", { count: validRows.length })}
              </span>
              <span className="flex items-center gap-1 text-danger">
                <XCircle className="size-4" /> {t("masters.products.bulkImport.errorCount", { count: errorRows.length })}
              </span>
              {duplicateRows.length > 0 ? (
                <span className="flex items-center gap-1 text-warning">
                  <AlertTriangle className="size-4" /> {t("masters.products.bulkImport.duplicateCount", { count: duplicateRows.length })}
                </span>
              ) : null}
            </div>

            <div className="max-h-96 overflow-y-auto rounded-xl border border-border">
              <table className="w-full text-xs">
                <thead className="sticky top-0 bg-surface-alt">
                  <tr>
                    <th className="p-2 text-left">#</th>
                    <th className="p-2 text-left">{t("masters.products.name")}</th>
                    <th className="p-2 text-left">{t("masters.products.brand")}</th>
                    <th className="p-2 text-left">{t("masters.products.model")}</th>
                    <th className="p-2 text-left">{t("masters.products.price")}</th>
                    <th className="p-2 text-left">{t("common.status")}</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((r) => (
                    <tr key={r.rowNum} className="border-t border-border">
                      <td className="p-2">{r.rowNum}</td>
                      <td className="p-2">{col(r.raw, "name")}</td>
                      <td className="p-2">{col(r.raw, "brand")}</td>
                      <td className="p-2">{col(r.raw, "model")}</td>
                      <td className="p-2">{col(r.raw, "price")}</td>
                      <td className="p-2">
                        {r.errors.length > 0 ? (
                          <span className="text-danger">{r.errors.join("; ")}</span>
                        ) : r.isDuplicate ? (
                          <span className="text-warning">{t("masters.products.bulkImport.duplicateRow")}</span>
                        ) : (
                          <span className="text-success">{t("masters.products.bulkImport.ok")}</span>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            <div className="flex justify-end gap-2">
              <Button variant="ghost" size="sm" onClick={() => setStep("upload")}>
                {t("common.back")}
              </Button>
              <Button size="sm" disabled={validRows.length === 0} onClick={handleConfirmImport}>
                {t("masters.products.bulkImport.confirmImport", { count: validRows.length })}
              </Button>
            </div>
          </div>
        ) : null}

        {step === "importing" ? (
          <div className="flex flex-col items-center gap-2 py-8">
            <Loader2 className="size-5 animate-spin text-accent" />
            <p className="text-sm text-text-muted">
              {t("masters.products.bulkImport.importing", { done: importProgress, total: rows.length })}
            </p>
          </div>
        ) : null}

        {step === "done" ? (
          <div className="space-y-3">
            <p className="text-sm">
              {t("masters.products.bulkImport.done", { created: createdCount, skipped: skippedCount, failed: failedCount })}
            </p>
            {outcomes.some((o) => o.status !== "created") ? (
              <ul className="max-h-60 space-y-1 overflow-y-auto rounded-xl border border-border p-2 text-xs">
                {outcomes
                  .filter((o) => o.status !== "created")
                  .map((o) => (
                    <li key={o.rowNum} className={o.status === "failed" ? "text-danger" : "text-text-muted"}>
                      row {o.rowNum} ({o.name}): {o.detail}
                    </li>
                  ))}
              </ul>
            ) : null}
            <div className="flex justify-end">
              <Button size="sm" onClick={onClose}>
                {t("common.close")}
              </Button>
            </div>
          </div>
        ) : null}
      </DialogContent>
    </Dialog>
  )
}
