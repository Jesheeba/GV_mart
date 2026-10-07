import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as svc from "@/services/leadAssignment"

export function useLeadAssignState(orgId: string | undefined, enabled = true) {
  return useQuery({
    queryKey: ["leadAssign", "state", orgId],
    queryFn: () => svc.getLeadAssignState(orgId!),
    enabled: !!orgId && enabled,
    refetchInterval: 60_000,
  })
}

export function useSetAutoAssignLeads(orgId: string | undefined) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (enabled: boolean) => svc.setAutoAssignLeads(orgId!, enabled),
    // switching ON hands out waiting leads, so lead lists change too
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["leadAssign"] })
      qc.invalidateQueries({ queryKey: ["leads"] })
    },
  })
}

export function useSetReceivesNewLeads() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ profileId, receives }: { profileId: string; receives: boolean }) => svc.setReceivesNewLeads(profileId, receives),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["profiles", "nonTechnicianStaff"] })
      qc.invalidateQueries({ queryKey: ["leadAssign"] })
      qc.invalidateQueries({ queryKey: ["leads"] })
    },
  })
}
