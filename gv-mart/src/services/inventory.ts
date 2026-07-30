import { supabase } from "@/lib/supabase"
import type { Enums, Tables } from "@/types/database"

export type InventoryRow = Tables<"inventory">
export type ItemType = Enums<"item_type">

export type InventoryListItem = InventoryRow & {
  itemName: string
  itemBrand: string | null
  // GV.md 1.1: admin-set standard service time for this item, surfaced here
  // so operation_admin (who has no direct write access to products/spares —
  // see set_item_standard_time's migration comment) can view/edit it from
  // the one screen that role already reaches.
  standardTimeMinutes: number | null
}

async function nameLookup(orgId: string, itemType: ItemType) {
  if (itemType === "product") {
    const { data, error } = await supabase
      .from("products")
      .select("id,name,brands(name),standard_time_minutes")
      .eq("org_id", orgId)
    if (error) throw error
    return new Map((data ?? []).map((p) => [p.id, { name: p.name, brand: p.brands?.name ?? null, standardTimeMinutes: p.standard_time_minutes }]))
  }
  if (itemType === "gift") {
    // Gifts have no brand or admin-set standard time (set_item_standard_time
    // only covers products/spares — see its migration comment); both are
    // simply null here, same as a spare's brand.
    const { data, error } = await supabase.from("gifts").select("id,name").eq("org_id", orgId)
    if (error) throw error
    return new Map((data ?? []).map((g) => [g.id, { name: g.name, brand: null, standardTimeMinutes: null }]))
  }
  const { data, error } = await supabase.from("spares").select("id,name,standard_time_minutes").eq("org_id", orgId)
  if (error) throw error
  return new Map((data ?? []).map((s) => [s.id, { name: s.name, brand: null, standardTimeMinutes: s.standard_time_minutes }]))
}

export async function listInventory(orgId: string, itemType: ItemType): Promise<InventoryListItem[]> {
  const [{ data, error }, names] = await Promise.all([
    supabase.from("inventory").select("*").eq("org_id", orgId).eq("item_type", itemType).order("stock_qty"),
    nameLookup(orgId, itemType),
  ])
  if (error) throw error
  return (data ?? []).map((row) => {
    const info = names.get(row.item_id)
    return { ...row, itemName: info?.name ?? "—", itemBrand: info?.brand ?? null, standardTimeMinutes: info?.standardTimeMinutes ?? null }
  })
}

/** GV.md 1.1: admin AND operation_admin can set/edit this — see set_item_standard_time RPC (20260725100000_sop_item_times_and_allowances.sql) for why this is a narrow RPC rather than a direct products/spares table write. */
export async function setItemStandardTime(input: { orgId: string; itemType: ItemType; itemId: string; minutes: number | null }) {
  const { error } = await supabase.rpc("set_item_standard_time", {
    p_org_id: input.orgId,
    p_item_type: input.itemType,
    p_item_id: input.itemId,
    p_minutes: input.minutes,
  })
  if (error) throw error
}

export async function updateThresholds(id: string, patch: { min_stock: number; max_stock: number }) {
  const { data, error } = await supabase.from("inventory").update(patch).eq("id", id).select().single()
  if (error) throw error
  return data
}

/** Adjusts stock_qty by a signed delta and logs the change to inventory_movements. */
export async function adjustStock(input: {
  orgId: string
  inventoryId: string
  itemType: ItemType
  itemId: string
  delta: number
  reason: string
}) {
  const { data: current, error: fetchError } = await supabase
    .from("inventory")
    .select("stock_qty")
    .eq("id", input.inventoryId)
    .single()
  if (fetchError) throw fetchError

  const nextQty = current.stock_qty + input.delta
  if (nextQty < 0) throw new Error("Stock cannot go below zero")

  const { error: updateError } = await supabase.from("inventory").update({ stock_qty: nextQty }).eq("id", input.inventoryId)
  if (updateError) throw updateError

  const { error: movementError } = await supabase.from("inventory_movements").insert({
    org_id: input.orgId,
    item_type: input.itemType,
    item_id: input.itemId,
    change_qty: input.delta,
    reason: input.reason,
  })
  if (movementError) throw movementError

  return nextQty
}
