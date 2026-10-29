import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as productLifecycle from "@/services/productLifecycle"
import type { LifetimeUnit } from "@/types/productLifecycle"

// Product Lifecycle & Automated Service Reminder System — W1 (masters form).
// Follows the same React Query shape as src/hooks/useMasters.ts
// (useProductSpares / useAddProductSpare / useRemoveProductSpare), kept in
// its own file per the build spec's file-scope list.

export function useProductLifecycleConfig(productId: string | undefined) {
  return useQuery({
    queryKey: ["productLifecycleConfig", productId],
    queryFn: () => productLifecycle.getProductLifecycleConfig(productId!),
    enabled: !!productId,
  })
}

export function useUpsertProductLifecycleConfig(productId: string | undefined) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ orgId, lifetimeValue, lifetimeUnit }: { orgId: string; lifetimeValue: number; lifetimeUnit: LifetimeUnit }) =>
      productLifecycle.upsertProductLifecycleConfig(orgId, productId!, lifetimeValue, lifetimeUnit),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["productLifecycleConfig", productId] }),
  })
}

export function useProductSpareSchedules(productId: string | undefined) {
  return useQuery({
    queryKey: ["productSpareSchedules", productId],
    queryFn: () => productLifecycle.listProductSpareSchedules(productId!),
    enabled: !!productId,
  })
}

export function useCreateProductSpareSchedule(productId: string | undefined) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (row: {
      org_id: string
      spare_id: string | null
      label: string
      interval_value: number
      interval_unit: LifetimeUnit
    }) => productLifecycle.createProductSpareSchedule({ ...row, product_id: productId! }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["productSpareSchedules", productId] }),
  })
}

export function useUpdateProductSpareSchedule(productId: string | undefined) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({
      id,
      patch,
    }: {
      id: string
      patch: Partial<{
        spare_id: string | null
        label: string
        interval_value: number
        interval_unit: LifetimeUnit
        is_active: boolean
      }>
    }) => productLifecycle.updateProductSpareSchedule(id, patch),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["productSpareSchedules", productId] }),
  })
}

export function useDeleteProductSpareSchedule(productId: string | undefined) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (id: string) => productLifecycle.deleteProductSpareSchedule(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["productSpareSchedules", productId] }),
  })
}

// ── Apply-to-existing-installations (preview then confirm) ──────────────
export function usePreviewApplyUpdatedSchedule() {
  return useMutation({
    mutationFn: (productId: string) => productLifecycle.previewApplyUpdatedSchedule(productId),
  })
}

export function useApplyUpdatedSchedule() {
  return useMutation({
    mutationFn: (productId: string) => productLifecycle.applyUpdatedSchedule(productId),
  })
}
