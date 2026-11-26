// Brand + Model + Product name are three separate master tables, but from a
// picker's point of view (New Sale, Quotations, Purchase) they're one thing:
// "which product". This lets a search for "amaron" (a brand) surface its
// products the same as searching the product's own name would.
type ProductForSearch = {
  name: string
  brands?: { name: string } | null
  models?: { name: string } | null
}

// The 2026-11-03 spreadsheet import created a placeholder brand named
// "RO (spreadsheet import)" and models that just repeat the product name
// minus its "ROP " prefix — showing both made every label read twice
// ("RO (spreadsheet import) 2090 BLUE — ROP 2090 BLUE"). Owner chose a
// display-only fix (2026-11-26), so the data is left as imported.
const IMPORT_PLACEHOLDER_BRAND = /\(spreadsheet import\)\s*$/i

/** Brand/model names worth showing next to a product name: drops the import placeholder brand, "—" fillers, and any part the name already contains. */
export function productExtraParts(name: string, brand?: string | null, model?: string | null): string[] {
  const lower = name.toLowerCase()
  return [brand, model].filter(
    (part): part is string => !!part && part !== "—" && !IMPORT_PLACEHOLDER_BRAND.test(part) && !lower.includes(part.toLowerCase())
  )
}

export function productSearchLabel(p: ProductForSearch): string {
  const parts = productExtraParts(p.name, p.brands?.name, p.models?.name)
  return parts.length ? `${parts.join(" ")} — ${p.name}` : p.name
}

/** True when every whitespace-separated word of `query` appears somewhere in `haystack`, in any order (case-insensitive). */
export function matchesAllWords(haystack: string, query: string): boolean {
  const h = haystack.toLowerCase()
  return query.toLowerCase().split(/\s+/).filter(Boolean).every((word) => h.includes(word))
}

export function productMatchesQuery(p: ProductForSearch, query: string): boolean {
  return matchesAllWords(`${p.brands?.name ?? ""} ${p.models?.name ?? ""} ${p.name}`, query)
}
