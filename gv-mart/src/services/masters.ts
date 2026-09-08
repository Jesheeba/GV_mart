import { supabase } from "@/lib/supabase"
import type { Tables, TablesInsert, TablesUpdate } from "@/types/database"

// ── Brands ───────────────────────────────────────────────────────────────
export async function listBrands(orgId: string) {
  const { data, error } = await supabase.from("brands").select("*").eq("org_id", orgId).order("name")
  if (error) throw error
  return data
}
export async function createBrand(row: TablesInsert<"brands">) {
  const { data, error } = await supabase.from("brands").insert(row).select().single()
  if (error) throw error
  return data
}
export async function updateBrand(id: string, patch: TablesUpdate<"brands">) {
  const { data, error } = await supabase.from("brands").update(patch).eq("id", id).select().single()
  if (error) throw error
  return data
}
export async function deleteBrand(id: string) {
  const { error } = await supabase.from("brands").delete().eq("id", id)
  if (error) throw error
}

// ── Models ───────────────────────────────────────────────────────────────
export async function listModels(orgId: string) {
  const { data, error } = await supabase.from("models").select("*, brands(name)").eq("org_id", orgId).order("name")
  if (error) throw error
  return data
}
export async function createModel(row: TablesInsert<"models">) {
  const { data, error } = await supabase.from("models").insert(row).select().single()
  if (error) throw error
  return data
}
export async function updateModel(id: string, patch: TablesUpdate<"models">) {
  const { data, error } = await supabase.from("models").update(patch).eq("id", id).select().single()
  if (error) throw error
  return data
}
export async function deleteModel(id: string) {
  const { error } = await supabase.from("models").delete().eq("id", id)
  if (error) throw error
}

// ── Products ─────────────────────────────────────────────────────────────
export async function listProducts(orgId: string) {
  const { data, error } = await supabase
    .from("products")
    .select("*, brands(name), models(name)")
    .eq("org_id", orgId)
    .order("name")
  if (error) throw error
  return data
}
export async function createProduct(row: TablesInsert<"products">) {
  const { data, error } = await supabase.from("products").insert(row).select().single()
  if (error) throw error
  return data
}
export async function updateProduct(id: string, patch: TablesUpdate<"products">) {
  const { data, error } = await supabase.from("products").update(patch).eq("id", id).select().single()
  if (error) throw error
  return data
}
export async function deleteProduct(id: string) {
  const { error } = await supabase.from("products").delete().eq("id", id)
  if (error) throw error
}

// ── Spares ───────────────────────────────────────────────────────────────
export async function listSpares(orgId: string) {
  const { data, error } = await supabase.from("spares").select("*").eq("org_id", orgId).order("name")
  if (error) throw error
  return data
}
export async function createSpare(row: TablesInsert<"spares">) {
  const { data, error } = await supabase.from("spares").insert(row).select().single()
  if (error) throw error
  return data
}
export async function updateSpare(id: string, patch: TablesUpdate<"spares">) {
  const { data, error } = await supabase.from("spares").update(patch).eq("id", id).select().single()
  if (error) throw error
  return data
}
export async function deleteSpare(id: string) {
  const { error } = await supabase.from("spares").delete().eq("id", id)
  if (error) throw error
}

// ── Appointment slots (Customer Dashboard Booking Audit, Tasks 2/3) ───────
export async function listAppointmentSlots(orgId: string) {
  const { data, error } = await supabase.from("appointment_slots").select("*").eq("org_id", orgId).order("sort_order")
  if (error) throw error
  return data
}
export async function createAppointmentSlot(row: TablesInsert<"appointment_slots">) {
  const { data, error } = await supabase.from("appointment_slots").insert(row).select().single()
  if (error) throw error
  return data
}
export async function updateAppointmentSlot(id: string, patch: TablesUpdate<"appointment_slots">) {
  const { data, error } = await supabase.from("appointment_slots").update(patch).eq("id", id).select().single()
  if (error) throw error
  return data
}
export async function deleteAppointmentSlot(id: string) {
  const { error } = await supabase.from("appointment_slots").delete().eq("id", id)
  if (error) throw error
}

// Task 6 (2026-07-30) — bulk import (paste-in add) and bulk enable/disable,
// both plain client calls: is_master() write RLS already covers insert and
// update on spares, same as the single-row create/update above.
export async function bulkCreateSpares(rows: TablesInsert<"spares">[]) {
  const { data, error } = await supabase.from("spares").insert(rows).select()
  if (error) throw error
  return data
}
export async function bulkSetSparesActive(ids: string[], isActive: boolean) {
  const { error } = await supabase.from("spares").update({ is_active: isActive }).in("id", ids)
  if (error) throw error
}

// ── Product <-> Spare mapping (Task 6, "assign multiple spare parts to
// products") ────────────────────────────────────────────────────────────
export async function listProductSpares(productId: string) {
  const { data, error } = await supabase
    .from("product_spares")
    .select("*, spares(id, name, sku, is_active)")
    .eq("product_id", productId)
  if (error) throw error
  return data
}
export async function addProductSpare(orgId: string, productId: string, spareId: string) {
  const { data, error } = await supabase
    .from("product_spares")
    .insert({ org_id: orgId, product_id: productId, spare_id: spareId })
    .select()
    .single()
  if (error) throw error
  return data
}
export async function removeProductSpare(id: string) {
  const { error } = await supabase.from("product_spares").delete().eq("id", id)
  if (error) throw error
}

// ── Complaint type <-> Spare mapping (2026-08-06, "which spares fix this
// issue") — same shape as product_spares above, keyed by complaint_type_id
// instead of product_id. Feeds the on-site "Suggested for this issue" chips
// (SpareSelectStep.tsx), replacing the old product-based suggestion. ──────
export async function listComplaintTypeSpares(complaintTypeId: string) {
  const { data, error } = await supabase
    .from("complaint_type_spares")
    .select("*, spares(id, name, sku, is_active)")
    .eq("complaint_type_id", complaintTypeId)
  if (error) throw error
  return data
}
export async function addComplaintTypeSpare(orgId: string, complaintTypeId: string, spareId: string) {
  const { data, error } = await supabase
    .from("complaint_type_spares")
    .insert({ org_id: orgId, complaint_type_id: complaintTypeId, spare_id: spareId })
    .select()
    .single()
  if (error) throw error
  return data
}
export async function removeComplaintTypeSpare(id: string) {
  const { error } = await supabase.from("complaint_type_spares").delete().eq("id", id)
  if (error) throw error
}

// ── Gifts ────────────────────────────────────────────────────────────────
export async function listGifts(orgId: string) {
  const { data, error } = await supabase.from("gifts").select("*").eq("org_id", orgId).order("threshold_amount")
  if (error) throw error
  return data
}
export async function createGift(row: TablesInsert<"gifts">) {
  const { data, error } = await supabase.from("gifts").insert(row).select().single()
  if (error) throw error
  return data
}
export async function updateGift(id: string, patch: TablesUpdate<"gifts">) {
  const { data, error } = await supabase.from("gifts").update(patch).eq("id", id).select().single()
  if (error) throw error
  return data
}
export async function deleteGift(id: string) {
  const { error } = await supabase.from("gifts").delete().eq("id", id)
  if (error) throw error
}

// ── Gift Exclusion Products (Enhancement spec Task 4) ───────────────────────
// Products a customer's cart still doesn't earn the standard threshold-based
// gift for, even though the cart as a whole clears the threshold — see
// create_sale's gift block (20260807090000_gift_exclusion_products.sql).
// Joined with the product name for display; same shape as gifts above.
export async function listGiftExclusionProducts(orgId: string) {
  const { data, error } = await supabase
    .from("gift_exclusion_products")
    .select("*, products(id, name)")
    .eq("org_id", orgId)
    .order("created_at")
  if (error) throw error
  return data
}
export async function createGiftExclusionProduct(row: TablesInsert<"gift_exclusion_products">) {
  const { data, error } = await supabase.from("gift_exclusion_products").insert(row).select().single()
  if (error) throw error
  return data
}
export async function updateGiftExclusionProduct(id: string, patch: TablesUpdate<"gift_exclusion_products">) {
  const { data, error } = await supabase.from("gift_exclusion_products").update(patch).eq("id", id).select().single()
  if (error) throw error
  return data
}
export async function deleteGiftExclusionProduct(id: string) {
  const { error } = await supabase.from("gift_exclusion_products").delete().eq("id", id)
  if (error) throw error
}

// ── Water quality / TDS-based RO recommendation (standalone feature, see
// 20260902100000_water_quality_tds_recommendation.sql) ─────────────────────
// Government CGWB data, imported once (scripts/import-water-quality.ts) —
// this is a static local table, never queried live. Staff can correct a
// district's figures here if local knowledge is more accurate than the
// government dataset for a specific area.
export async function listWaterQualityReference(orgId: string) {
  const { data, error } = await supabase.from("water_quality_reference").select("*").eq("org_id", orgId).order("district")
  if (error) throw error
  return data
}
export async function createWaterQualityReference(row: TablesInsert<"water_quality_reference">) {
  const { data, error } = await supabase.from("water_quality_reference").insert(row).select().single()
  if (error) throw error
  return data
}
export async function updateWaterQualityReference(id: string, patch: TablesUpdate<"water_quality_reference">) {
  const { data, error } = await supabase.from("water_quality_reference").update(patch).eq("id", id).select().single()
  if (error) throw error
  return data
}
export async function deleteWaterQualityReference(id: string) {
  const { error } = await supabase.from("water_quality_reference").delete().eq("id", id)
  if (error) throw error
}

// District-name resolution for districts that don't match a
// water_quality_reference row directly (old names, genuinely different
// spellings — see getCustomerTdsSuggestion in services/waterQuality.ts).
export async function listWaterQualityDistrictAliases(orgId: string) {
  const { data, error } = await supabase.from("water_quality_district_aliases").select("*").eq("org_id", orgId).order("alias")
  if (error) throw error
  return data
}
export async function createWaterQualityDistrictAlias(row: TablesInsert<"water_quality_district_aliases">) {
  const { data, error } = await supabase.from("water_quality_district_aliases").insert(row).select().single()
  if (error) throw error
  return data
}
export async function updateWaterQualityDistrictAlias(id: string, patch: TablesUpdate<"water_quality_district_aliases">) {
  const { data, error } = await supabase.from("water_quality_district_aliases").update(patch).eq("id", id).select().single()
  if (error) throw error
  return data
}
export async function deleteWaterQualityDistrictAlias(id: string) {
  const { error } = await supabase.from("water_quality_district_aliases").delete().eq("id", id)
  if (error) throw error
}

// Band (low/medium/high, see bandForTds in services/waterQuality.ts) →
// product picks. No product carries structured capacity/TDS-controller
// data, so this mapping can't be derived automatically.
export async function listProductTdsRecommendations(orgId: string) {
  const { data, error } = await supabase
    .from("product_tds_recommendations")
    .select("*, products(id, name)")
    .eq("org_id", orgId)
    .order("band")
    .order("sort_order")
  if (error) throw error
  return data
}
export async function createProductTdsRecommendation(row: TablesInsert<"product_tds_recommendations">) {
  const { data, error } = await supabase.from("product_tds_recommendations").insert(row).select().single()
  if (error) throw error
  return data
}
export async function updateProductTdsRecommendation(id: string, patch: TablesUpdate<"product_tds_recommendations">) {
  const { data, error } = await supabase.from("product_tds_recommendations").update(patch).eq("id", id).select().single()
  if (error) throw error
  return data
}
export async function deleteProductTdsRecommendation(id: string) {
  const { error } = await supabase.from("product_tds_recommendations").delete().eq("id", id)
  if (error) throw error
}

// ── SOP step templates (Technician Module Audit, Task 5) ───────────────────
// Read is org-wide (technicians pick from this list on-site), write is
// master-only — same shape as gifts/spares/products above.
export async function listSopStepTemplates(orgId: string) {
  const { data, error } = await supabase
    .from("sop_step_templates")
    .select("*, products(name)")
    .eq("org_id", orgId)
    .order("name")
  if (error) throw error
  return data
}
export async function createSopStepTemplate(row: TablesInsert<"sop_step_templates">) {
  const { data, error } = await supabase.from("sop_step_templates").insert(row).select().single()
  if (error) throw error
  return data
}
export async function updateSopStepTemplate(id: string, patch: TablesUpdate<"sop_step_templates">) {
  const { data, error } = await supabase.from("sop_step_templates").update(patch).eq("id", id).select().single()
  if (error) throw error
  return data
}
export async function deleteSopStepTemplate(id: string) {
  const { error } = await supabase.from("sop_step_templates").delete().eq("id", id)
  if (error) throw error
}

// ── AMC plans ────────────────────────────────────────────────────────────
export async function listAmcPlans(orgId: string): Promise<AmcPlanRow[]> {
  const { data, error } = await supabase.from("amc_plans").select("*").eq("org_id", orgId).order("years")
  if (error) throw error
  return data ?? []
}
export async function createAmcPlan(row: TablesInsert<"amc_plans">) {
  const { data, error } = await supabase.from("amc_plans").insert(row).select().single()
  if (error) throw error
  return data
}
export async function updateAmcPlan(id: string, patch: TablesUpdate<"amc_plans">) {
  const { data, error } = await supabase.from("amc_plans").update(patch).eq("id", id).select().single()
  if (error) throw error
  return data
}
export async function deleteAmcPlan(id: string) {
  const { error } = await supabase.from("amc_plans").delete().eq("id", id)
  if (error) throw error
}

// ── AMC plan covered spares (Fix 2: hard-gate uncovered spares on AMC
// visits) ───────────────────────────────────────────────────────────────
function fromCoveredSpares() {
  return supabase.from("amc_plan_covered_spares")
}

export async function listAmcPlanCoveredSpareIds(planId: string): Promise<string[]> {
  const { data, error } = await fromCoveredSpares().select("spare_id").eq("plan_id", planId)
  if (error) throw error
  return (data ?? []).map((r) => r.spare_id)
}

export async function setAmcPlanCoveredSpares(planId: string, spareIds: string[]) {
  const { error: delErr } = await fromCoveredSpares().delete().eq("plan_id", planId)
  if (delErr) throw delErr
  if (spareIds.length === 0) return
  const rows = spareIds.map((spare_id) => ({ plan_id: planId, spare_id }))
  const { error: insErr } = await fromCoveredSpares().insert(rows)
  if (insErr) throw insErr
}

// ── Incentive rules ──────────────────────────────────────────────────────
// v2.2: no hardcoded incentive %/₹ anywhere — every rate is admin-set here.
export async function listIncentiveRules(orgId: string) {
  const { data, error } = await supabase.from("incentive_rules").select("*").eq("org_id", orgId).order("type")
  if (error) throw error
  return data
}
export async function createIncentiveRule(row: TablesInsert<"incentive_rules">) {
  const { data, error } = await supabase.from("incentive_rules").insert(row).select().single()
  if (error) throw error
  return data
}
export async function updateIncentiveRule(id: string, patch: TablesUpdate<"incentive_rules">) {
  const { data, error } = await supabase.from("incentive_rules").update(patch).eq("id", id).select().single()
  if (error) throw error
  return data
}
export async function deleteIncentiveRule(id: string) {
  const { error } = await supabase.from("incentive_rules").delete().eq("id", id)
  if (error) throw error
}

// ── Complaint types (Meeting spec E1) ───────────────────────────────────
// Product-category-tagged, admin-editable — feeds the filtered auto-suggest
// on the customer booking screen and the admin new-complaint screen.
export async function listComplaintTypes(orgId: string) {
  const { data, error } = await supabase.from("complaint_types").select("*").eq("org_id", orgId).order("label")
  if (error) throw error
  return data
}
export async function createComplaintType(row: TablesInsert<"complaint_types">) {
  const { data, error } = await supabase.from("complaint_types").insert(row).select().single()
  if (error) throw error
  return data
}
export async function updateComplaintType(id: string, patch: TablesUpdate<"complaint_types">) {
  const { data, error } = await supabase.from("complaint_types").update(patch).eq("id", id).select().single()
  if (error) throw error
  return data
}
export async function deleteComplaintType(id: string) {
  const { error } = await supabase.from("complaint_types").delete().eq("id", id)
  if (error) throw error
}

// ── Settings (one row per org) ───────────────────────────────────────────
export async function getSettings(orgId: string) {
  const { data, error } = await supabase.from("settings").select("*").eq("org_id", orgId).maybeSingle()
  if (error) throw error
  return data
}
export async function updateSettings(orgId: string, patch: TablesUpdate<"settings">) {
  const { data, error } = await supabase.from("settings").update(patch).eq("org_id", orgId).select().single()
  if (error) throw error
  return data
}

export type BrandRow = Tables<"brands">
export type ModelRow = Tables<"models">
export type ProductRow = Tables<"products">
export type SpareRow = Tables<"spares">
export type GiftRow = Tables<"gifts">
export type GiftExclusionProductRow = Tables<"gift_exclusion_products"> & { products: Pick<Tables<"products">, "id" | "name"> | null }
export type WaterQualityReferenceRow = Tables<"water_quality_reference">
export type WaterQualityDistrictAliasRow = Tables<"water_quality_district_aliases">
export type ProductTdsRecommendationRow = Tables<"product_tds_recommendations"> & { products: Pick<Tables<"products">, "id" | "name"> | null }
export type AmcPlanRow = Tables<"amc_plans">
export type IncentiveRuleRow = Tables<"incentive_rules">
export type ComplaintTypeRow = Tables<"complaint_types">
export type ProductSpareRow = Tables<"product_spares"> & { spares: Pick<Tables<"spares">, "id" | "name" | "sku" | "is_active"> | null }
export type ComplaintTypeSpareRow = Tables<"complaint_type_spares"> & { spares: Pick<Tables<"spares">, "id" | "name" | "sku" | "is_active"> | null }
export type SettingsRow = Tables<"settings">
export type SopStepTemplateRow = Tables<"sop_step_templates"> & { products: Pick<Tables<"products">, "name"> | null }
export type AppointmentSlotRow = Tables<"appointment_slots">
