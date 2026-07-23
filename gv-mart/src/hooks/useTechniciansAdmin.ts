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

export function useEligibleTechnicianProfiles(orgId: string | undefined) {
  return useQuery({
    queryKey: ["technicians", "eligibleProfiles", orgId],
    queryFn: () => techniciansAdmin.listEligibleTechnicianProfiles(orgId!),
    enabled: !!orgId,
  })
}

export function useCreateTechnician() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ orgId, profileId }: { orgId: string; profileId: string }) => techniciansAdmin.createTechnician(orgId, profileId),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["technicians"] }),
  })
}

export function useTechnicianCurrentJob(technicianId: string | undefined) {
  return useQuery({
    queryKey: ["technicians", "currentJob", technicianId],
    queryFn: () => techniciansAdmin.getTechnicianCurrentJob(technicianId!),
    enabled: !!technicianId,
  })
}

export function useTechnicianAttendanceHistory(technicianId: string | undefined) {
  return useQuery({
    queryKey: ["attendance", "history", technicianId],
    queryFn: () => techniciansAdmin.getTechnicianAttendanceHistory(technicianId!),
    enabled: !!technicianId,
  })
}

export function useTechnicianRewards(technicianId: string | undefined) {
  return useQuery({
    queryKey: ["rewards", "byTechnician", technicianId],
    queryFn: () => techniciansAdmin.listTechnicianRewards(technicianId!),
    enabled: !!technicianId,
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

/** Each technician's current/next job today + destination coords, for the live-tracking ETA/off-route logic (v2.2 §6.6). */
export function useTechniciansActiveJobs(orgId: string | undefined) {
  return useQuery({
    queryKey: ["technicians", "activeJobs", orgId],
    queryFn: () => techniciansAdmin.listTechniciansActiveJobs(orgId!),
    enabled: !!orgId,
    refetchInterval: 60_000,
  })
}

/** Build Order A4: each technician's currently-open visit + its ticket's estimated
 *  duration, for the job-overrun alert on TechniciansMapPage. Same 30s cadence as
 *  the "now" tick that page already runs for idle/off-route, since an overrun
 *  reads late but is otherwise low-urgency. */
export function useTechniciansOpenVisits(orgId: string | undefined) {
  return useQuery({
    queryKey: ["technicians", "openVisits", orgId],
    queryFn: () => techniciansAdmin.listTechniciansOpenVisits(orgId!),
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
