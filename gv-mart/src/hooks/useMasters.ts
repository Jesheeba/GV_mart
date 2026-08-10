import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as masters from "@/services/masters"
import * as productAttributes from "@/services/productAttributes"
import * as productEnquiryConfig from "@/services/productEnquiryConfig"
import * as productMedia from "@/services/productMedia"
import type { Json, TablesInsert, TablesUpdate } from "@/types/database"

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

// Customer Dashboard Booking Audit (2026-07-31) Tasks 2/3 — admin-configured
// appointment slots (Morning/Afternoon/Evening etc.), independent of
// technician working hours.
export const appointmentSlotsHooks = entityHooks("appointment_slots", {
  list: masters.listAppointmentSlots,
  create: masters.createAppointmentSlot,
  update: masters.updateAppointmentSlot,
  remove: masters.deleteAppointmentSlot,
})

// Task 6 (2026-07-30) — bulk import/update don't fit entityHooks' one-row
// shape, and product<->spare mapping is queried per-product, not as a flat
// list — both live alongside sparesHooks instead.
export function useBulkCreateSpares() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (rows: TablesInsert<"spares">[]) => masters.bulkCreateSpares(rows),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["spares", "list"] }),
  })
}
export function useBulkSetSparesActive() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ ids, isActive }: { ids: string[]; isActive: boolean }) => masters.bulkSetSparesActive(ids, isActive),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["spares", "list"] }),
  })
}

export function useProductSpares(productId: string | undefined) {
  return useQuery({
    queryKey: ["product_spares", "list", productId],
    queryFn: () => masters.listProductSpares(productId!),
    enabled: !!productId,
  })
}
export function useAddProductSpare() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ orgId, productId, spareId }: { orgId: string; productId: string; spareId: string }) =>
      masters.addProductSpare(orgId, productId, spareId),
    onSuccess: (_data, vars) => qc.invalidateQueries({ queryKey: ["product_spares", "list", vars.productId] }),
  })
}
export function useRemoveProductSpare(productId: string | undefined) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (id: string) => masters.removeProductSpare(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["product_spares", "list", productId] }),
  })
}

export function useComplaintTypeSpares(complaintTypeId: string | undefined) {
  return useQuery({
    queryKey: ["complaint_type_spares", "list", complaintTypeId],
    queryFn: () => masters.listComplaintTypeSpares(complaintTypeId!),
    enabled: !!complaintTypeId,
  })
}
export function useAddComplaintTypeSpare() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ orgId, complaintTypeId, spareId }: { orgId: string; complaintTypeId: string; spareId: string }) =>
      masters.addComplaintTypeSpare(orgId, complaintTypeId, spareId),
    onSuccess: (_data, vars) => qc.invalidateQueries({ queryKey: ["complaint_type_spares", "list", vars.complaintTypeId] }),
  })
}
export function useRemoveComplaintTypeSpare(complaintTypeId: string | undefined) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (id: string) => masters.removeComplaintTypeSpare(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["complaint_type_spares", "list", complaintTypeId] }),
  })
}

export const giftsHooks = entityHooks("gifts", {
  list: masters.listGifts,
  create: masters.createGift,
  update: masters.updateGift,
  remove: masters.deleteGift,
})

export const giftExclusionProductsHooks = entityHooks("gift_exclusion_products", {
  list: masters.listGiftExclusionProducts,
  create: masters.createGiftExclusionProduct,
  update: masters.updateGiftExclusionProduct,
  remove: masters.deleteGiftExclusionProduct,
})

export const sopStepTemplatesHooks = entityHooks("sop_step_templates", {
  list: masters.listSopStepTemplates,
  create: masters.createSopStepTemplate,
  update: masters.updateSopStepTemplate,
  remove: masters.deleteSopStepTemplate,
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

// ── Product Enquiry rebuild (2026-08-04), Phase 1 ───────────────────────
// Attribute keys fit entityHooks as-is (a flat org-level master list).
export const productAttributeKeysHooks = entityHooks("product_attribute_keys", {
  list: productAttributes.listProductAttributeKeys,
  create: productAttributes.createProductAttributeKey,
  update: productAttributes.updateProductAttributeKey,
  remove: productAttributes.deleteProductAttributeKey,
})

// ── Product Enquiry rebuild (2026-08-04), Phase 2 ───────────────────────
// Module-config tables are all flat org-level lists — entityHooks as-is.
export const productEnquiryTabsHooks = entityHooks("product_enquiry_tabs", {
  list: productEnquiryConfig.listProductEnquiryTabs,
  create: productEnquiryConfig.createProductEnquiryTab,
  update: productEnquiryConfig.updateProductEnquiryTab,
  remove: productEnquiryConfig.deleteProductEnquiryTab,
})
export const productEnquiryFiltersHooks = entityHooks("product_enquiry_filters", {
  list: productEnquiryConfig.listProductEnquiryFilters,
  create: productEnquiryConfig.createProductEnquiryFilter,
  update: productEnquiryConfig.updateProductEnquiryFilter,
  remove: productEnquiryConfig.deleteProductEnquiryFilter,
})
export const productEnquiryComparisonFieldsHooks = entityHooks("product_enquiry_comparison_fields", {
  list: productEnquiryConfig.listProductEnquiryComparisonFields,
  create: productEnquiryConfig.createProductEnquiryComparisonField,
  update: productEnquiryConfig.updateProductEnquiryComparisonField,
  remove: productEnquiryConfig.deleteProductEnquiryComparisonField,
})
export const productEnquiryCtaConfigHooks = entityHooks("product_enquiry_cta_config", {
  list: productEnquiryConfig.listProductEnquiryCtaConfig,
  create: productEnquiryConfig.createProductEnquiryCtaConfig,
  update: productEnquiryConfig.updateProductEnquiryCtaConfig,
  remove: productEnquiryConfig.deleteProductEnquiryCtaConfig,
})

// Images/documents/videos/related/CTA-overrides are all queried per-product
// (not a flat list), same shape as useProductSpares above.
export function useProductImages(productId: string | undefined) {
  return useQuery({
    queryKey: ["product_images", "list", productId],
    queryFn: () => productMedia.listProductImages(productId!),
    enabled: !!productId,
  })
}
export function useUploadProductImage(productId: string | undefined) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ orgId, file }: { orgId: string; file: File }) => productMedia.uploadProductImage(orgId, productId!, file),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["product_images", "list", productId] }),
  })
}
export function useUpdateProductImage(productId: string | undefined) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ id, patch }: { id: string; patch: TablesUpdate<"product_images"> }) => productMedia.updateProductImage(id, patch),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["product_images", "list", productId] }),
  })
}
export function useDeleteProductImage(productId: string | undefined) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (id: string) => productMedia.deleteProductImage(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["product_images", "list", productId] }),
  })
}
export function useSetPrimaryProductImage(productId: string | undefined) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (imageId: string) => productMedia.setPrimaryProductImage(productId!, imageId),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["product_images", "list", productId] }),
  })
}

export function useProductDocuments(productId: string | undefined) {
  return useQuery({
    queryKey: ["product_documents", "list", productId],
    queryFn: () => productMedia.listProductDocuments(productId!),
    enabled: !!productId,
  })
}
export function useUploadProductDocument(productId: string | undefined) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ orgId, file, label, docType }: { orgId: string; file: File; label: string; docType: TablesInsert<"product_documents">["doc_type"] }) =>
      productMedia.uploadProductDocument(orgId, productId!, file, label, docType),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["product_documents", "list", productId] }),
  })
}
export function useDeleteProductDocument(productId: string | undefined) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (id: string) => productMedia.deleteProductDocument(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["product_documents", "list", productId] }),
  })
}

export function useProductVideos(productId: string | undefined) {
  return useQuery({
    queryKey: ["product_videos", "list", productId],
    queryFn: () => productMedia.listProductVideos(productId!),
    enabled: !!productId,
  })
}
export function useCreateProductVideo(productId: string | undefined) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (row: TablesInsert<"product_videos">) => productMedia.createProductVideo(row),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["product_videos", "list", productId] }),
  })
}
export function useUpdateProductVideo(productId: string | undefined) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ id, patch }: { id: string; patch: TablesUpdate<"product_videos"> }) => productMedia.updateProductVideo(id, patch),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["product_videos", "list", productId] }),
  })
}
export function useDeleteProductVideo(productId: string | undefined) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (id: string) => productMedia.deleteProductVideo(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["product_videos", "list", productId] }),
  })
}

export function useSetProductCustomAttribute() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ productId, current, keyId, value }: { productId: string; current: Json; keyId: string; value: string | number | boolean | null }) =>
      productAttributes.setProductCustomAttribute(productId, current, keyId, value),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["products", "list"] }),
  })
}
export function useSetProductFeatureBullets() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ productId, bullets }: { productId: string; bullets: string[] }) => productAttributes.setProductFeatureBullets(productId, bullets),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["products", "list"] }),
  })
}

export function useProductRelated(productId: string | undefined) {
  return useQuery({
    queryKey: ["product_related", "list", productId],
    queryFn: () => productAttributes.listProductRelated(productId!),
    enabled: !!productId,
  })
}
export function useAddProductRelated(productId: string | undefined) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ orgId, relatedProductId, relationType }: { orgId: string; relatedProductId: string; relationType: TablesInsert<"product_related">["relation_type"] }) =>
      productAttributes.addProductRelated(orgId, productId!, relatedProductId, relationType),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["product_related", "list", productId] }),
  })
}
export function useRemoveProductRelated(productId: string | undefined) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (id: string) => productAttributes.removeProductRelated(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["product_related", "list", productId] }),
  })
}

export function useProductCtaOverrides(productId: string | undefined) {
  return useQuery({
    queryKey: ["product_cta_overrides", "list", productId],
    queryFn: () => productAttributes.listProductCtaOverrides(productId!),
    enabled: !!productId,
  })
}
export function useSetProductCtaOverride(productId: string | undefined) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ orgId, ctaType, isEnabled }: { orgId: string; ctaType: TablesInsert<"product_cta_overrides">["cta_type"]; isEnabled: boolean }) =>
      productAttributes.setProductCtaOverride(orgId, productId!, ctaType, isEnabled),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["product_cta_overrides", "list", productId] }),
  })
}
export function useClearProductCtaOverride(productId: string | undefined) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (ctaType: TablesInsert<"product_cta_overrides">["cta_type"]) => productAttributes.clearProductCtaOverride(productId!, ctaType),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["product_cta_overrides", "list", productId] }),
  })
}
