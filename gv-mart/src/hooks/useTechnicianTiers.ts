import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as tiers from "@/services/technicianTiers"

export function useTechnicianTiers(orgId: string | undefined) {
  return useQuery({
    queryKey: ["technician_tiers", "list", orgId],
    queryFn: () => tiers.listTechnicianTiers(orgId!),
    enabled: !!orgId,
  })
}

export function useTechnicianTierMutations() {
  const qc = useQueryClient()
  const invalidate = () => qc.invalidateQueries({ queryKey: ["technician_tiers"] })
  return {
    create: useMutation({ mutationFn: tiers.createTechnicianTier, onSuccess: invalidate }),
    update: useMutation({
      mutationFn: ({ id, patch }: { id: string; patch: Parameters<typeof tiers.updateTechnicianTier>[1] }) => tiers.updateTechnicianTier(id, patch),
      onSuccess: invalidate,
    }),
    remove: useMutation({ mutationFn: tiers.deleteTechnicianTier, onSuccess: invalidate }),
  }
}

export function usePendingPromotions(orgId: string | undefined) {
  return useQuery({
    queryKey: ["tier_promotions", "pending", orgId],
    queryFn: () => tiers.listPendingPromotions(orgId!),
    enabled: !!orgId,
  })
}

/** Approve/dismiss both change what the technician page, the list and the
 * notification bell show, so they invalidate all of them. */
export function usePromotionDecision() {
  const qc = useQueryClient()
  const invalidate = () => {
    qc.invalidateQueries({ queryKey: ["tier_promotions"] })
    qc.invalidateQueries({ queryKey: ["technician_tier_progress"] })
    qc.invalidateQueries({ queryKey: ["technicians"] })
    qc.invalidateQueries({ queryKey: ["notifications"] })
  }
  return {
    approve: useMutation({ mutationFn: tiers.approveTierPromotion, onSuccess: invalidate }),
    dismiss: useMutation({ mutationFn: tiers.dismissTierPromotion, onSuccess: invalidate }),
  }
}

export function useTechnicianTierProgress(technicianId: string | undefined) {
  return useQuery({
    queryKey: ["technician_tier_progress", technicianId],
    queryFn: () => tiers.getTechnicianTierProgress(technicianId!),
    enabled: !!technicianId,
  })
}
