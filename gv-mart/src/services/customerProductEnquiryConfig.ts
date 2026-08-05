import { supabase } from "@/lib/supabase"

// Product Enquiry rebuild (2026-08-04), Phase 3 — customer-side reads of
// the admin-configured module layer. Every read here filters is_active
// client-side (product_enquiry_tabs_select_org has no is_active filter of
// its own, matching products_select_org's existing gap) — customer-facing
// queries must never rely on RLS alone to hide disabled config rows.

export async function listActiveProductEnquiryTabs(orgId: string) {
  const { data, error } = await supabase
    .from("product_enquiry_tabs")
    .select("*")
    .eq("org_id", orgId)
    .eq("is_active", true)
    .order("sort_order")
  if (error) throw error
  return data
}

export async function listActiveProductEnquiryFilters(orgId: string) {
  const { data, error } = await supabase
    .from("product_enquiry_filters")
    .select("*, product_attribute_keys(id, label, data_type)")
    .eq("org_id", orgId)
    .eq("is_active", true)
    .order("sort_order")
  if (error) throw error
  return data
}

export async function listActiveProductEnquiryComparisonFields(orgId: string) {
  const { data, error } = await supabase
    .from("product_enquiry_comparison_fields")
    .select("*, product_attribute_keys(id, label, data_type)")
    .eq("org_id", orgId)
    .eq("is_active", true)
    .order("sort_order")
  if (error) throw error
  return data
}

export async function listActiveProductAttributeKeys(orgId: string) {
  const { data, error } = await supabase.from("product_attribute_keys").select("*").eq("org_id", orgId).eq("is_active", true).order("sort_order")
  if (error) throw error
  return data
}

// Merges the org-wide CTA defaults (product_enquiry_cta_config) with any
// per-product override (product_cta_overrides, Phase 1) — same
// category-default-OR-product-override merge complaint_types already does,
// just client-side instead of a view. A row's effective enabled state is
// the override's is_enabled if one exists for this product+cta_type,
// otherwise the org default's is_active.
export async function listEffectiveProductCtas(orgId: string, productId: string) {
  const [{ data: config, error: configError }, { data: overrides, error: overridesError }] = await Promise.all([
    supabase.from("product_enquiry_cta_config").select("*").eq("org_id", orgId).order("sort_order"),
    supabase.from("product_cta_overrides").select("*").eq("product_id", productId),
  ])
  if (configError) throw configError
  if (overridesError) throw overridesError
  const overrideMap = new Map((overrides ?? []).map((o) => [o.cta_type, o.is_enabled]))
  return (config ?? [])
    .map((c) => ({ ...c, effectiveEnabled: overrideMap.has(c.cta_type) ? (overrideMap.get(c.cta_type) as boolean) : c.is_active }))
    .filter((c) => c.effectiveEnabled)
}
