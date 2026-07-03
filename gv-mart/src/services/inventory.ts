import { supabase } from "@/lib/supabase"
import type { Enums, Tables } from "@/types/database"

export type InventoryRow = Tables<"inventory">
export type ItemType = Enums<"item_type">

export type InventoryListItem = InventoryRow & {
  itemName: string
  itemBrand: string | null
}

async function nameLookup(orgId: string, itemType: ItemType) {
  if (itemType === "product") {
    const { data, error } = await supabase
      .from("products")
      .select("id,name,brands(name)")
      .eq("org_id", orgId)
    if (error) throw error
    return new Map((data ?? []).map((p) => [p.id, { name: p.name, brand: p.brands?.name ?? null }]))
  }
  const { data, error } = await supabase.from("spares").select("id,name").eq("org_id", orgId)
  if (error) throw error
  return new Map((data ?? []).map((s) => [s.id, { name: s.name, brand: null }]))
}

export async function listInventory(orgId: string, itemType: ItemType): Promise<InventoryListItem[]> {
  const [{ data, error }, names] = await Promise.all([
    supabase.from("inventory").select("*").eq("org_id", orgId).eq("item_type", itemType).order("stock_qty"),
    nameLookup(orgId, itemType),
  ])
  if (error) throw error
  return (data ?? []).map((row) => {
    const info = names.get(row.item_id)
    return { ...row, itemName: info?.name ?? "—", itemBrand: info?.brand ?? null }
  })
}

export async function updateThresholds(id: string, patch: { min_stock: number; reorder_qty: number }) {
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
