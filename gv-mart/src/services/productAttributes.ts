import { supabase } from "@/lib/supabase"
import type { Json, TablesInsert, TablesUpdate } from "@/types/database"

// Product Enquiry rebuild (2026-08-04), Phase 1 — custom attributes, feature
// bullets, and related-product mapping. custom_attributes/feature_bullets
// are plain jsonb columns on products (no DB-level content validation, same
// as amc_plans.inclusions) — these are read-modify-write helpers, not a
// separate table, since the caller already has the current product row
// loaded (ProductsTab.tsx's list) and only needs to patch one field.

export async function setProductCustomAttribute(productId: string, current: Json, keyId: string, value: string | number | boolean | null) {
  const next: Record<string, Json> = { ...((current as Record<string, Json>) ?? {}) }
  if (value === null || value === "") {
    delete next[keyId]
  } else {
    next[keyId] = value
  }
  const { data, error } = await supabase.from("products").update({ custom_attributes: next }).eq("id", productId).select().single()
  if (error) throw error
  return data
}

export async function setProductFeatureBullets(productId: string, bullets: string[]) {
  const { data, error } = await supabase.from("products").update({ feature_bullets: bullets }).eq("id", productId).select().single()
  if (error) throw error
  return data
}

// ── Attribute keys (org-level catalog) ──────────────────────────────────
export async function listProductAttributeKeys(orgId: string) {
  const { data, error } = await supabase.from("product_attribute_keys").select("*").eq("org_id", orgId).order("sort_order")
  if (error) throw error
  return data
}
export async function createProductAttributeKey(row: TablesInsert<"product_attribute_keys">) {
  const { data, error } = await supabase.from("product_attribute_keys").insert(row).select().single()
  if (error) throw error
  return data
}
export async function updateProductAttributeKey(id: string, patch: TablesUpdate<"product_attribute_keys">) {
  const { data, error } = await supabase.from("product_attribute_keys").update(patch).eq("id", id).select().single()
  if (error) throw error
  return data
}
export async function deleteProductAttributeKey(id: string) {
  const { error } = await supabase.from("product_attribute_keys").delete().eq("id", id)
  if (error) throw error
}

// ── Related products / accessories ──────────────────────────────────────
export async function listProductRelated(productId: string) {
  const { data, error } = await supabase
    .from("product_related")
    // product_related has two FKs to products (product_id, related_product_id)
    // — the `products!related_product_id` hint picks the latter explicitly,
    // same disambiguation getCatalogProduct's embed needs (customerCatalog.ts).
    .select("*, related:products!related_product_id(id, name, is_active)")
    .eq("product_id", productId)
  if (error) throw error
  return data
}
export async function addProductRelated(
  orgId: string,
  productId: string,
  relatedProductId: string,
  relationType: TablesInsert<"product_related">["relation_type"]
) {
  const { data, error } = await supabase
    .from("product_related")
    .insert({ org_id: orgId, product_id: productId, related_product_id: relatedProductId, relation_type: relationType })
    .select()
    .single()
  if (error) throw error
  return data
}
export async function removeProductRelated(id: string) {
  const { error } = await supabase.from("product_related").delete().eq("id", id)
  if (error) throw error
}

// ── Per-product CTA overrides ───────────────────────────────────────────
export async function listProductCtaOverrides(productId: string) {
  const { data, error } = await supabase.from("product_cta_overrides").select("*").eq("product_id", productId)
  if (error) throw error
  return data
}
export async function setProductCtaOverride(orgId: string, productId: string, ctaType: TablesInsert<"product_cta_overrides">["cta_type"], isEnabled: boolean) {
  const { data, error } = await supabase
    .from("product_cta_overrides")
    .upsert({ org_id: orgId, product_id: productId, cta_type: ctaType, is_enabled: isEnabled }, { onConflict: "product_id,cta_type" })
    .select()
    .single()
  if (error) throw error
  return data
}
export async function clearProductCtaOverride(productId: string, ctaType: TablesInsert<"product_cta_overrides">["cta_type"]) {
  const { error } = await supabase.from("product_cta_overrides").delete().eq("product_id", productId).eq("cta_type", ctaType)
  if (error) throw error
}
