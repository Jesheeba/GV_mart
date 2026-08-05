import { supabase } from "@/lib/supabase"

// Product Enquiry rebuild (2026-08-04), Phases 3-5 — customer-facing
// product catalog reads. Deliberately separate from services/customerApp.ts's
// listOwnedProducts (used by the QR-registration/service-booking pickers)
// rather than extending it in place — that function is a shared dependency
// of unrelated flows, and the catalog needs a heavier join (primary image)
// that those callers don't want paying for on every render.
//
// Grid query stays lean (no documents/videos/custom_attributes/related —
// those only load on the single-product detail fetch, Phase 4) to keep the
// catalog grid cheap regardless of how many products/attributes exist.

export async function listCatalogProducts(orgId: string) {
  const { data, error } = await supabase
    .from("products")
    // feature_bullets is a plain column on products (no join), so including
    // it here for the row's spec line doesn't cost the extra-table joins
    // "lean" is actually guarding against (documents/videos/attributes/related).
    .select("id, name, category, brand_id, model_id, price, warranty_months, feature_bullets, description, brands(name), models(name), product_images(storage_path, is_primary)")
    .eq("org_id", orgId)
    .eq("is_active", true)
    .order("name")
  if (error) throw error
  return data
}

// Full hydration for the single-product detail page (Phase 4) — images,
// documents, videos, custom attributes, feature bullets, related products.
// Never used for the grid query above; that stays lean on purpose.
export async function getCatalogProduct(productId: string) {
  const { data, error } = await supabase
    .from("products")
    .select(
      "id, name, category, brand_id, model_id, price, warranty_months, custom_attributes, feature_bullets, description, is_active, " +
        "brands(name), models(name), " +
        "product_images(id, storage_path, is_primary, sort_order), " +
        "product_documents(id, storage_path, label, doc_type, sort_order), " +
        "product_videos(id, url, title, sort_order, is_active), " +
        // product_related has two FKs to products (product_id, related_product_id)
        // — the outer embed hint (!product_id) picks which one relates THIS
        // product to its product_related rows; the inner alias's own column
        // name (related_product_id) then disambiguates the second hop.
        "product_related!product_id(id, relation_type, related:related_product_id(id, name, price))"
    )
    .eq("id", productId)
    .eq("is_active", true)
    .single()
  if (error) throw error
  return data
}

// Compare page (Phase 5) — batched fetch for 2-3 selected products. No
// media/documents needed for a spec/price comparison table.
export async function listCatalogProductsByIds(orgId: string, ids: string[]) {
  const { data, error } = await supabase
    .from("products")
    .select("id, name, category, brand_id, model_id, price, warranty_months, custom_attributes, brands(name), models(name)")
    .eq("org_id", orgId)
    .eq("is_active", true)
    .in("id", ids)
  if (error) throw error
  return data
}
