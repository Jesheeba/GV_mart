import { supabase } from "@/lib/supabase"
import type { TablesInsert, TablesUpdate } from "@/types/database"

// Product Enquiry rebuild (2026-08-04), Phase 2 — admin CRUD for the
// module-config layer (tabs/filters/comparison-fields/CTA config) that
// drives the customer-facing Product Enquiry screen. Plain org-scoped
// list/create/update/delete, same shape as every other masters.ts entity —
// fits the entityHooks factory as-is, no bespoke hooks needed.

export async function listProductEnquiryTabs(orgId: string) {
  const { data, error } = await supabase.from("product_enquiry_tabs").select("*").eq("org_id", orgId).order("sort_order")
  if (error) throw error
  return data
}
export async function createProductEnquiryTab(row: TablesInsert<"product_enquiry_tabs">) {
  const { data, error } = await supabase.from("product_enquiry_tabs").insert(row).select().single()
  if (error) throw error
  return data
}
export async function updateProductEnquiryTab(id: string, patch: TablesUpdate<"product_enquiry_tabs">) {
  const { data, error } = await supabase.from("product_enquiry_tabs").update(patch).eq("id", id).select().single()
  if (error) throw error
  return data
}
export async function deleteProductEnquiryTab(id: string) {
  const { error } = await supabase.from("product_enquiry_tabs").delete().eq("id", id)
  if (error) throw error
}

export async function listProductEnquiryFilters(orgId: string) {
  const { data, error } = await supabase
    .from("product_enquiry_filters")
    .select("*, product_attribute_keys(label)")
    .eq("org_id", orgId)
    .order("sort_order")
  if (error) throw error
  return data
}
export async function createProductEnquiryFilter(row: TablesInsert<"product_enquiry_filters">) {
  const { data, error } = await supabase.from("product_enquiry_filters").insert(row).select().single()
  if (error) throw error
  return data
}
export async function updateProductEnquiryFilter(id: string, patch: TablesUpdate<"product_enquiry_filters">) {
  const { data, error } = await supabase.from("product_enquiry_filters").update(patch).eq("id", id).select().single()
  if (error) throw error
  return data
}
export async function deleteProductEnquiryFilter(id: string) {
  const { error } = await supabase.from("product_enquiry_filters").delete().eq("id", id)
  if (error) throw error
}

export async function listProductEnquiryComparisonFields(orgId: string) {
  const { data, error } = await supabase
    .from("product_enquiry_comparison_fields")
    .select("*, product_attribute_keys(label)")
    .eq("org_id", orgId)
    .order("sort_order")
  if (error) throw error
  return data
}
export async function createProductEnquiryComparisonField(row: TablesInsert<"product_enquiry_comparison_fields">) {
  const { data, error } = await supabase.from("product_enquiry_comparison_fields").insert(row).select().single()
  if (error) throw error
  return data
}
export async function updateProductEnquiryComparisonField(id: string, patch: TablesUpdate<"product_enquiry_comparison_fields">) {
  const { data, error } = await supabase.from("product_enquiry_comparison_fields").update(patch).eq("id", id).select().single()
  if (error) throw error
  return data
}
export async function deleteProductEnquiryComparisonField(id: string) {
  const { error } = await supabase.from("product_enquiry_comparison_fields").delete().eq("id", id)
  if (error) throw error
}

export async function listProductEnquiryCtaConfig(orgId: string) {
  const { data, error } = await supabase.from("product_enquiry_cta_config").select("*").eq("org_id", orgId).order("sort_order")
  if (error) throw error
  return data
}
export async function createProductEnquiryCtaConfig(row: TablesInsert<"product_enquiry_cta_config">) {
  const { data, error } = await supabase.from("product_enquiry_cta_config").insert(row).select().single()
  if (error) throw error
  return data
}
export async function updateProductEnquiryCtaConfig(id: string, patch: TablesUpdate<"product_enquiry_cta_config">) {
  const { data, error } = await supabase.from("product_enquiry_cta_config").update(patch).eq("id", id).select().single()
  if (error) throw error
  return data
}
export async function deleteProductEnquiryCtaConfig(id: string) {
  const { error } = await supabase.from("product_enquiry_cta_config").delete().eq("id", id)
  if (error) throw error
}
