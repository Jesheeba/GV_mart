import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as masters from "@/services/masters"
import type { TablesUpdate } from "@/types/database"

// All three generics are inferred from the concrete functions passed in
// `api` (e.g. masters.createBrand) — call sites never specify type args.
function entityHooks<TRow, TInsert, TUpdate>(
  key: string,
  api: {
    list: (orgId: string) => Promise<TRow[]>
    create: (row: TInsert) => Promise<unknown>
    update: (id: string, patch: TUpdate) => Promise<unknown>
    remove: (id: string) => Promise<void>
  }
) {
  function useList(orgId: string | undefined) {
    return useQuery({
      queryKey: [key, "list", orgId],
      queryFn: () => api.list(orgId!),
      enabled: !!orgId,
    })
  }
  function useCreate() {
    const qc = useQueryClient()
    return useMutation({
      mutationFn: (row: TInsert) => api.create(row),
      onSuccess: () => qc.invalidateQueries({ queryKey: [key, "list"] }),
    })
  }
  function useUpdate() {
    const qc = useQueryClient()
    return useMutation({
      mutationFn: ({ id, patch }: { id: string; patch: TUpdate }) => api.update(id, patch),
      onSuccess: () => qc.invalidateQueries({ queryKey: [key, "list"] }),
    })
  }
  function useDelete() {
    const qc = useQueryClient()
    return useMutation({
      mutationFn: (id: string) => api.remove(id),
      onSuccess: () => qc.invalidateQueries({ queryKey: [key, "list"] }),
    })
  }
  return { useList, useCreate, useUpdate, useDelete }
}

export const brandsHooks = entityHooks("brands", {
  list: masters.listBrands,
  create: masters.createBrand,
  update: masters.updateBrand,
  remove: masters.deleteBrand,
})

export const modelsHooks = entityHooks("models", {
  list: masters.listModels,
  create: masters.createModel,
  update: masters.updateModel,
  remove: masters.deleteModel,
})

export const productsHooks = entityHooks("products", {
  list: masters.listProducts,
  create: masters.createProduct,
  update: masters.updateProduct,
  remove: masters.deleteProduct,
})

export const sparesHooks = entityHooks("spares", {
  list: masters.listSpares,
  create: masters.createSpare,
  update: masters.updateSpare,
  remove: masters.deleteSpare,
})

export const giftsHooks = entityHooks("gifts", {
  list: masters.listGifts,
  create: masters.createGift,
  update: masters.updateGift,
  remove: masters.deleteGift,
})

export const amcPlansHooks = entityHooks("amc_plans", {
  list: masters.listAmcPlans,
  create: masters.createAmcPlan,
  update: masters.updateAmcPlan,
  remove: masters.deleteAmcPlan,
})

// ── AMC plan covered spares (Fix 2) — not a flat CRUD list so it doesn't
// fit entityHooks' shape; one query per plan + a "replace the whole set"
// mutation, mirroring the amc_plans query key so both invalidate cleanly. ──
export function useAmcPlanCoveredSpares(planId: string | null) {
  return useQuery({
    queryKey: ["amc_plan_covered_spares", planId],
    queryFn: () => masters.listAmcPlanCoveredSpareIds(planId!),
    enabled: !!planId,
  })
}
export function useSetAmcPlanCoveredSpares() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ planId, spareIds }: { planId: string; spareIds: string[] }) => masters.setAmcPlanCoveredSpares(planId, spareIds),
    onSuccess: (_data, vars) => qc.invalidateQueries({ queryKey: ["amc_plan_covered_spares", vars.planId] }),
  })
}

export const incentiveRulesHooks = entityHooks("incentive_rules", {
  list: masters.listIncentiveRules,
  create: masters.createIncentiveRule,
  update: masters.updateIncentiveRule,
  remove: masters.deleteIncentiveRule,
})

export const complaintTypesHooks = entityHooks("complaint_types", {
  list: masters.listComplaintTypes,
  create: masters.createComplaintType,
  update: masters.updateComplaintType,
  remove: masters.deleteComplaintType,
})

export function useSettings(orgId: string | undefined) {
  return useQuery({
    queryKey: ["settings", orgId],
    queryFn: () => masters.getSettings(orgId!),
    enabled: !!orgId,
  })
}
export function useUpdateSettings(orgId: string | undefined) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (patch: TablesUpdate<"settings">) => masters.updateSettings(orgId!, patch),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["settings", orgId] }),
  })
}
