import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as techniciansAdmin from "@/services/techniciansAdmin"
import type { CreateSpareHandoverInput } from "@/services/techniciansAdmin"

export function useTechniciansList(orgId: string | undefined) {
  return useQuery({
    queryKey: ["technicians", "adminList", orgId],
    queryFn: () => techniciansAdmin.listTechnicians(orgId!),
    enabled: !!orgId,
  })
}

export function useUpdateTechnician() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ id, patch }: { id: string; patch: Parameters<typeof techniciansAdmin.updateTechnician>[1] }) =>
      techniciansAdmin.updateTechnician(id, patch),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["technicians"] })
    },
  })
}

export function useTechniciansWithLocation(orgId: string | undefined) {
  return useQuery({
    queryKey: ["technicians", "withLocation", orgId],
    queryFn: () => techniciansAdmin.listTechniciansWithLatestLocation(orgId!),
    enabled: !!orgId,
    refetchInterval: 30_000,
  })
}

export function useAttendanceForDate(orgId: string | undefined, date: string) {
  return useQuery({
    queryKey: ["attendance", "byDate", orgId, date],
    queryFn: () => techniciansAdmin.listAttendanceForDate(orgId!, date),
    enabled: !!orgId && !!date,
  })
}

export function useSpareHandovers(orgId: string | undefined) {
  return useQuery({
    queryKey: ["spare_handovers", "list", orgId],
    queryFn: () => techniciansAdmin.listSpareHandovers(orgId!),
    enabled: !!orgId,
  })
}

export function useSparesForHandover(orgId: string | undefined) {
  return useQuery({
    queryKey: ["spares", "forHandover", orgId],
    queryFn: () => techniciansAdmin.listSparesForHandover(orgId!),
    enabled: !!orgId,
  })
}

export function useCreateSpareHandover() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: CreateSpareHandoverInput) => techniciansAdmin.createSpareHandover(input),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["spare_handovers"] }),
  })
}

export function useAdminSignSpareHandover() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ handoverId, adminSignUrl }: { handoverId: string; adminSignUrl: string }) =>
      techniciansAdmin.adminSignSpareHandover(handoverId, adminSignUrl),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["spare_handovers"] }),
  })
}
