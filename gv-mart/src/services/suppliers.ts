import { supabase } from "@/lib/supabase"
import type { Enums, Tables, TablesInsert, TablesUpdate } from "@/types/database"

export type SupplierRow = Tables<"suppliers">
export type SupplierProductRow = Tables<"supplier_products">
export type ItemType = Enums<"item_type">

export async function listSuppliers(orgId: string) {
  const { data, error } = await supabase.from("suppliers").select("*").eq("org_id", orgId).order("name")
  if (error) throw error
  return data
}
export async function createSupplier(row: TablesInsert<"suppliers">) {
  const { data, error } = await supabase.from("suppliers").insert(row).select().single()
  if (error) throw error
  return data
}
export async function updateSupplier(id: string, patch: TablesUpdate<"suppliers">) {
  const { data, error } = await supabase.from("suppliers").update(patch).eq("id", id).select().single()
  if (error) throw error
  return data
}
export async function deleteSupplier(id: string) {
  const { error } = await supabase.from("suppliers").delete().eq("id", id)
  if (error) throw error
}

/** All item links for a supplier, with the item's display name resolved. */
export async function listSupplierProducts(orgId: string, supplierId: string) {
  const { data, error } = await supabase
    .from("supplier_products")
    .select("*")
    .eq("org_id", orgId)
    .eq("supplier_id", supplierId)
    .order("created_at", { ascending: false })
  if (error) throw error

  const productIds = (data ?? []).filter((r) => r.item_type === "product").map((r) => r.item_id)
  const spareIds = (data ?? []).filter((r) => r.item_type === "spare").map((r) => r.item_id)
  const [{ data: products }, { data: spares }] = await Promise.all([
    productIds.length
      ? supabase.from("products").select("id,name").in("id", productIds)
      : Promise.resolve({ data: [] as { id: string; name: string }[] }),
    spareIds.length
      ? supabase.from("spares").select("id,name").in("id", spareIds)
      : Promise.resolve({ data: [] as { id: string; name: string }[] }),
  ])
  const nameMap = new Map([...(products ?? []), ...(spares ?? [])].map((r) => [r.id, r.name]))

  return (data ?? []).map((row) => ({ ...row, itemName: nameMap.get(row.item_id) ?? "—" }))
}

/** Every supplier linked to one item, cheapest first — for the "cheapest supplier" marker. */
export async function listSuppliersForItem(orgId: string, itemType: ItemType, itemId: string) {
  const { data, error } = await supabase
    .from("supplier_products")
    .select("*, suppliers(name)")
    .eq("org_id", orgId)
    .eq("item_type", itemType)
    .eq("item_id", itemId)
    .order("price", { ascending: true })
  if (error) throw error
  return data
}

export async function linkSupplierItem(row: TablesInsert<"supplier_products">) {
  const { data, error } = await supabase.from("supplier_products").insert(row).select().single()
  if (error) throw error
  return data
}
export async function updateSupplierItem(id: string, patch: TablesUpdate<"supplier_products">) {
  const { data, error } = await supabase.from("supplier_products").update(patch).eq("id", id).select().single()
  if (error) throw error
  return data
}
export async function unlinkSupplierItem(id: string) {
  const { error } = await supabase.from("supplier_products").delete().eq("id", id)
  if (error) throw error
}

export async function listCatalogForLinking(orgId: string) {
  const [{ data: products, error: e1 }, { data: spares, error: e2 }] = await Promise.all([
    supabase.from("products").select("id,name").eq("org_id", orgId).order("name"),
    supabase.from("spares").select("id,name").eq("org_id", orgId).order("name"),
  ])
  if (e1) throw e1
  if (e2) throw e2
  return { products: products ?? [], spares: spares ?? [] }
}
