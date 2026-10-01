import { supabase } from "@/lib/supabase"
import type { Tables, TablesInsert, TablesUpdate } from "@/types/database"

export type TechnicianTierRow = Tables<"technician_tiers">
export type TierPromotionEligibilityRow = Tables<"tier_promotion_eligibility"> & {
  technicians: { profiles: { full_name: string } | null } | null
  technician_tiers: { name: string } | null
}
export type TechnicianTierProgress = {
  current_tier_id: string | null
  current_tier_name: string | null
  next_tier_id: string | null
  next_tier_name: string | null
  required_earning: number | null
  required_months: number | null
  earning: number | null
}

export async function listTechnicianTiers(orgId: string): Promise<TechnicianTierRow[]> {
  const { data, error } = await supabase.from("technician_tiers").select("*").eq("org_id", orgId).order("rank")
  if (error) throw error
  return data ?? []
}
export async function createTechnicianTier(row: TablesInsert<"technician_tiers">) {
  const { data, error } = await supabase.from("technician_tiers").insert(row).select().single()
  if (error) throw error
  return data
}
export async function updateTechnicianTier(id: string, patch: TablesUpdate<"technician_tiers">) {
  const { data, error } = await supabase.from("technician_tiers").update(patch).eq("id", id).select().single()
  if (error) throw error
  return data
}
export async function deleteTechnicianTier(id: string) {
  const { error } = await supabase.from("technician_tiers").delete().eq("id", id)
  // technicians.tier_id is ON DELETE RESTRICT — a tier in use can't be removed.
  if (error) throw new Error(error.code === "23503" ? "This tier is assigned to technicians or has promotion records — move them first." : error.message)
}

export async function listPendingPromotions(orgId: string): Promise<TierPromotionEligibilityRow[]> {
  const { data, error } = await supabase
    .from("tier_promotion_eligibility")
    .select("*, technicians(profiles(full_name)), technician_tiers:target_tier_id(name)")
    .eq("org_id", orgId)
    .eq("status", "pending")
    .order("detected_at", { ascending: false })
  if (error) throw error
  return (data ?? []) as unknown as TierPromotionEligibilityRow[]
}
export async function approveTierPromotion(eligibilityId: string) {
  const { error } = await supabase.rpc("approve_tier_promotion", { p_eligibility_id: eligibilityId })
  if (error) throw error
}
export async function dismissTierPromotion(eligibilityId: string) {
  const { error } = await supabase.rpc("dismiss_tier_promotion", { p_eligibility_id: eligibilityId })
  if (error) throw error
}
export async function getTechnicianTierProgress(technicianId: string): Promise<TechnicianTierProgress | null> {
  const { data, error } = await supabase.rpc("technician_tier_progress", { p_technician_id: technicianId })
  if (error) throw error
  return ((data ?? [])[0] as TechnicianTierProgress | undefined) ?? null
}
