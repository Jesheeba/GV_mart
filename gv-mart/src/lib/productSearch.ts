// Brand + Model + Product name are three separate master tables, but from a
// picker's point of view (New Sale, Quotations, Purchase) they're one thing:
// "which product". This lets a search for "amaron" (a brand) surface its
// products the same as searching the product's own name would.
type ProductForSearch = {
  name: string
  brands?: { name: string } | null
  models?: { name: string } | null
}

export function productSearchLabel(p: ProductForSearch): string {
  const brandModel = [p.brands?.name, p.models?.name].filter(Boolean).join(" ")
  return brandModel ? `${brandModel} — ${p.name}` : p.name
}

export function productMatchesQuery(p: ProductForSearch, query: string): boolean {
  const q = query.trim().toLowerCase()
  if (!q) return true
  const haystack = `${p.brands?.name ?? ""} ${p.models?.name ?? ""} ${p.name}`.toLowerCase()
  return haystack.includes(q)
}
