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

// ── AMC plans ────────────────────────────────────────────────────────────
export async function listAmcPlans(orgId: string) {
  const { data, error } = await supabase.from("amc_plans").select("*").eq("org_id", orgId).order("years")
  if (error) throw error
  return data
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
export type AmcPlanRow = Tables<"amc_plans">
export type IncentiveRuleRow = Tables<"incentive_rules">
export type SettingsRow = Tables<"settings">
