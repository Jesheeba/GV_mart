import type { SupabaseClient } from "@supabase/supabase-js"
import { supabase } from "@/lib/supabase"
import type { ApplyUpdatedSchedulePreviewRow, LifetimeUnit } from "@/types/productLifecycle"

// Product Lifecycle & Automated Service Reminder System — W1 (masters form).
//
// Tables (product_lifecycle_configs, product_spare_schedules) and RPCs
// (apply_updated_schedule_preview, apply_updated_schedule) don't exist yet in
// src/types/database.ts — the lead's migration lands later and this
// worktree's isolated DB never gets written to. `db` below is `supabase`
// cast to the untyped client shape purely so `.from()`/`.rpc()` accept these
// not-yet-generated names; every call still follows the exact same
// `.from(...)` / `.rpc(...)` convention as src/services/masters.ts. Once the
// lead's migration is applied and database.ts regenerated, this file can
// switch back to the typed `supabase` client with no call-site changes.
const db = supabase as unknown as SupabaseClient

export interface ProductLifecycleConfigRow {
  id: string
  org_id: string
  product_id: string
  lifetime_value: number
  lifetime_unit: LifetimeUnit
  is_active: boolean
  created_at: string
  updated_at: string
}

export interface ProductSpareScheduleRow {
  id: string
  org_id: string
  product_id: string
  spare_id: string | null
  label: string
  interval_value: number
  interval_unit: LifetimeUnit
  is_active: boolean
  created_at: string
  updated_at: string
  spares: { id: string; name: string; sku: string | null; is_active: boolean } | null
}

// ── Lifetime config (one row per product, upsert on product_id) ─────────
export async function getProductLifecycleConfig(productId: string): Promise<ProductLifecycleConfigRow | null> {
  const { data, error } = await db.from("product_lifecycle_configs").select("*").eq("product_id", productId).maybeSingle()
  if (error) throw error
  return data as ProductLifecycleConfigRow | null
}

export async function upsertProductLifecycleConfig(
  orgId: string,
  productId: string,
  lifetimeValue: number,
  lifetimeUnit: LifetimeUnit
): Promise<ProductLifecycleConfigRow> {
  const { data, error } = await db
    .from("product_lifecycle_configs")
    .upsert(
      {
        org_id: orgId,
        product_id: productId,
        lifetime_value: lifetimeValue,
        lifetime_unit: lifetimeUnit,
        is_active: true,
      },
      { onConflict: "product_id" }
    )
    .select()
    .single()
  if (error) throw error
  return data as ProductLifecycleConfigRow
}

// ── Spare-part schedules (repeater rows, standard CRUD per row) ─────────
export async function listProductSpareSchedules(productId: string): Promise<ProductSpareScheduleRow[]> {
  const { data, error } = await db
    .from("product_spare_schedules")
    .select("*, spares(id, name, sku, is_active)")
    .eq("product_id", productId)
    .order("created_at")
  if (error) throw error
  return (data ?? []) as ProductSpareScheduleRow[]
}

export async function createProductSpareSchedule(row: {
  org_id: string
  product_id: string
  spare_id: string | null
  label: string
  interval_value: number
  interval_unit: LifetimeUnit
}): Promise<ProductSpareScheduleRow> {
  const { data, error } = await db.from("product_spare_schedules").insert(row).select("*, spares(id, name, sku, is_active)").single()
  if (error) throw error
  return data as ProductSpareScheduleRow
}

export async function updateProductSpareSchedule(
  id: string,
  patch: Partial<{
    spare_id: string | null
    label: string
    interval_value: number
    interval_unit: LifetimeUnit
    is_active: boolean
  }>
): Promise<ProductSpareScheduleRow> {
  const { data, error } = await db
    .from("product_spare_schedules")
    .update(patch)
    .eq("id", id)
    .select("*, spares(id, name, sku, is_active)")
    .single()
  if (error) throw error
  return data as ProductSpareScheduleRow
}

export async function deleteProductSpareSchedule(id: string): Promise<void> {
  const { error } = await db.from("product_spare_schedules").delete().eq("id", id)
  if (error) throw error
}

// ── Apply-to-existing-installations (master-only button) ────────────────
// Names fixed by the build spec's contract — must match exactly what the
// lead wires server-side.
export async function previewApplyUpdatedSchedule(productId: string): Promise<ApplyUpdatedSchedulePreviewRow[]> {
  const { data, error } = await db.rpc("apply_updated_schedule_preview", { p_product_id: productId })
  if (error) throw error
  return (data ?? []) as ApplyUpdatedSchedulePreviewRow[]
}

export async function applyUpdatedSchedule(productId: string): Promise<number> {
  const { data, error } = await db.rpc("apply_updated_schedule", { p_product_id: productId })
  if (error) throw error
  return (data ?? 0) as number
}
