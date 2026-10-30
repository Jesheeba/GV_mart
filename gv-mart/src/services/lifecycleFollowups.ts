import type { SupabaseClient } from "@supabase/supabase-js"
import { supabase } from "@/lib/supabase"

// Product Lifecycle & Automated Service Reminder System -- W5 (sales follow-ups).
//
// Reads go through get_lifecycle_followups_for_sales (SECURITY DEFINER, gated server-side
// to is_sales_staff() -- master + sales_admin). Every write is its own RPC, same convention
// as src/services/leadFollowups.ts / postServiceFollowups.ts.
//
// The RPC names and row shape are fixed by the lead's contract and aren't in
// src/types/database.ts yet (this worktree's isolated DB is never migrated), so `db` below is
// `supabase` cast to the untyped client shape purely so `.rpc()` accepts these not-yet-generated
// names -- same workaround already used in src/services/productLifecycle.ts. Once the lead's
// migration is applied and database.ts regenerated, this file can switch back to the typed
// `supabase` client with no call-site changes.
const db = supabase as unknown as SupabaseClient

export type LifecycleFollowupStatus = "due_soon" | "due" | "overdue"

/** One row of get_lifecycle_followups_for_sales, camelCase per this codebase's RPC-mapper convention (see src/services/reportMappers.ts). */
export interface LifecycleFollowupRow {
  scheduleId: string
  customerId: string
  customerName: string
  productName: string
  label: string
  nextDueDate: string
  status: LifecycleFollowupStatus
}

/** Raw shape returned by get_lifecycle_followups_for_sales (snake_case). */
type LifecycleFollowupRpcRow = {
  schedule_id: string
  customer_id: string
  customer_name: string
  product_name: string
  label: string
  next_due_date: string
  status: LifecycleFollowupStatus
}

export function mapLifecycleFollowupRow(r: LifecycleFollowupRpcRow): LifecycleFollowupRow {
  return {
    scheduleId: r.schedule_id,
    customerId: r.customer_id,
    customerName: r.customer_name,
    productName: r.product_name,
    label: r.label,
    nextDueDate: r.next_due_date,
    status: r.status,
  }
}

export async function listLifecycleFollowupsForSales(orgId: string): Promise<LifecycleFollowupRow[]> {
  const { data, error } = await db.rpc("get_lifecycle_followups_for_sales", { p_org_id: orgId })
  if (error) throw error
  return ((data ?? []) as unknown as LifecycleFollowupRpcRow[]).map(mapLifecycleFollowupRow)
}

export async function markLifecycleFollowupContacted(i: { scheduleId: string; note?: string | null }): Promise<void> {
  const { error } = await db.rpc("lifecycle_mark_followup_contacted", { p_schedule_id: i.scheduleId, p_note: i.note ?? null })
  if (error) throw error
}

export async function snoozeLifecycleFollowup(i: { scheduleId: string; until: string }): Promise<void> {
  const { error } = await db.rpc("lifecycle_snooze_followup", { p_schedule_id: i.scheduleId, p_until: i.until })
  if (error) throw error
}

/** Creates a service ticket from the schedule and returns its new uuid. */
export async function createLifecycleServiceRequest(scheduleId: string): Promise<string> {
  const { data, error } = await db.rpc("lifecycle_create_service_request", { p_schedule_id: scheduleId })
  if (error) throw error
  return data as string
}
