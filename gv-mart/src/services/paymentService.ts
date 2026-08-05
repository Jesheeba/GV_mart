import { supabase } from "@/lib/supabase"
import type { Tables, TablesInsert } from "@/types/database"

export type PaymentSettingsRow = Tables<"payment_settings">

/** Admin read — mirrors services/masters.ts#getSettings. `maybeSingle` since no row exists until the admin's first save. */
export async function getPaymentSettings(orgId: string): Promise<PaymentSettingsRow | null> {
  const { data, error } = await supabase.from("payment_settings").select("*").eq("org_id", orgId).maybeSingle()
  if (error) throw error
  return data
}

/**
 * Admin write. `upsert` (not `update`, unlike masters.ts#updateSettings) —
 * unlike `settings`, no `payment_settings` row is auto-provisioned per org,
 * so the first save must insert.
 */
export async function upsertPaymentSettings(orgId: string, patch: Omit<TablesInsert<"payment_settings">, "org_id">): Promise<PaymentSettingsRow> {
  const { data, error } = await supabase
    .from("payment_settings")
    .upsert({ ...patch, org_id: orgId }, { onConflict: "org_id" })
    .select()
    .single()
  if (error) throw error
  return data
}

/** Customer read — same row, scoped by the payment_settings_select_customer RLS policy (ticket join, since customers have no current_org_id()). */
export async function getCustomerPaymentSettings(orgId: string): Promise<PaymentSettingsRow | null> {
  const { data, error } = await supabase.from("payment_settings").select("*").eq("org_id", orgId).maybeSingle()
  if (error) throw error
  return data
}
