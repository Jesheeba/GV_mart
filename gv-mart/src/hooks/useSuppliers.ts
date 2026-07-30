import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as suppliers from "@/services/suppliers"
import type { TablesInsert, TablesUpdate } from "@/types/database"
import type { ItemType } from "@/services/suppliers"

export function useSuppliersList(orgId: string | undefined) {
  return useQuery({
    queryKey: ["suppliers", "list", orgId],
    queryFn: () => suppliers.listSuppliers(orgId!),
    enabled: !!orgId,
  })
}
export function useCreateSupplier() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (row: TablesInsert<"suppliers">) => suppliers.createSupplier(row),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["suppliers", "list"] }),
  })
}
export function useUpdateSupplier() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ id, patch }: { id: string; patch: TablesUpdate<"suppliers"> }) => suppliers.updateSupplier(id, patch),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["suppliers", "list"] }),
  })
}
export function useDeleteSupplier() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (id: string) => suppliers.deleteSupplier(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["suppliers", "list"] }),
  })
}

export function useSupplierProducts(orgId: string | undefined, supplierId: string | undefined) {
  return useQuery({
    queryKey: ["suppliers", "products", orgId, supplierId],
    queryFn: () => suppliers.listSupplierProducts(orgId!, supplierId!),
    enabled: !!orgId && !!supplierId,
  })
}
/** Every supplier linked to one item, cheapest first — used by the PO
 *  quote-first flow (PurchaseQuotesTab) to populate "which supplier is this
 *  reply for" without re-deriving it from purchase_quote_requests, and by
 *  the "cheapest supplier" marker elsewhere. */
export function useSuppliersForItem(orgId: string | undefined, itemType: ItemType | undefined, itemId: string | undefined) {
  return useQuery({
    queryKey: ["suppliers", "forItem", orgId, itemType, itemId],
    queryFn: () => suppliers.listSuppliersForItem(orgId!, itemType!, itemId!),
    enabled: !!orgId && !!itemType && !!itemId,
  })
}
export function useLinkedItemKeys(orgId: string | undefined) {
  return useQuery({
    queryKey: ["suppliers", "linkedItemKeys", orgId],
    queryFn: () => suppliers.listLinkedItemKeys(orgId!),
    enabled: !!orgId,
  })
}
export function useCatalogForLinking(orgId: string | undefined) {
  return useQuery({
    queryKey: ["suppliers", "catalog", orgId],
    queryFn: () => suppliers.listCatalogForLinking(orgId!),
    enabled: !!orgId,
  })
}
export function useLinkSupplierItem(orgId: string | undefined, supplierId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (row: Omit<TablesInsert<"supplier_products">, "org_id" | "supplier_id">) =>
      suppliers.linkSupplierItem({ ...row, org_id: orgId!, supplier_id: supplierId }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["suppliers", "products", orgId, supplierId] }),
  })
}
export function useUpdateSupplierItem(orgId: string | undefined, supplierId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ id, patch }: { id: string; patch: TablesUpdate<"supplier_products"> }) =>
      suppliers.updateSupplierItem(id, patch),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["suppliers", "products", orgId, supplierId] }),
  })
}
export function useUnlinkSupplierItem(orgId: string | undefined, supplierId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (id: string) => suppliers.unlinkSupplierItem(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["suppliers", "products", orgId, supplierId] }),
  })
}
