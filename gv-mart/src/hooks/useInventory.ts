import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as inventory from "@/services/inventory"
import type { ItemType } from "@/services/inventory"

export function useInventoryList(orgId: string | undefined, itemType: ItemType) {
  return useQuery({
    queryKey: ["inventory", "list", orgId, itemType],
    queryFn: () => inventory.listInventory(orgId!, itemType),
    enabled: !!orgId,
  })
}

export function useUpdateThresholds() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ id, patch }: { id: string; patch: { min_stock: number; max_stock: number | null; reorder_qty: number } }) =>
      inventory.updateThresholds(id, patch),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["inventory", "list"] }),
  })
}

export function useAdjustStock() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: Parameters<typeof inventory.adjustStock>[0]) => inventory.adjustStock(input),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["inventory", "list"] }),
  })
}

/** GV.md 1.1 — see inventory.setItemStandardTime doc. */
export function useSetItemStandardTime() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: Parameters<typeof inventory.setItemStandardTime>[0]) => inventory.setItemStandardTime(input),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["inventory", "list"] }),
  })
}
