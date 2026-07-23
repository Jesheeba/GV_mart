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

export function useTechnicianAttendanceForMonth(technicianId: string | undefined, year: number, month: number) {
  return useQuery({
    queryKey: ["attendance", "byMonth", technicianId, year, month],
    queryFn: () => techniciansAdmin.getTechnicianAttendanceForMonth(technicianId!, year, month),
    enabled: !!technicianId,
  })
}

/** Only fires once a calendar day is actually clicked (`dateStr` set) —
 * there's no reason to fetch every visible day's visits/ratings up front. */
export function useTechnicianVisitsForDate(technicianId: string | undefined, dateStr: string | null) {
  return useQuery({
    queryKey: ["attendance", "visitsForDate", technicianId, dateStr],
    queryFn: () => techniciansAdmin.getTechnicianVisitsForDate(technicianId!, dateStr!),
    enabled: !!technicianId && !!dateStr,
  })
}

export function useTechnicianRewards(technicianId: string | undefined) {
  return useQuery({
    queryKey: ["rewards", "byTechnician", technicianId],
    queryFn: () => techniciansAdmin.listTechnicianRewards(technicianId!),
    enabled: !!technicianId,
  })
}

/** Requirement 2/11 — History tab's per-job duration + rating enrichment (see getTechnicianTicketHistory doc comment). */
export function useTechnicianTicketHistory(technicianId: string | undefined) {
  return useQuery({
    queryKey: ["technicians", "ticketHistory", technicianId],
    queryFn: () => techniciansAdmin.getTechnicianTicketHistory(technicianId!),
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

// ── Phase 1 assignment-engine data: technician_availability ───────────────

export function useTechnicianAvailability(technicianId: string | undefined) {
  return useQuery({
    queryKey: ["technician-availability", technicianId],
    queryFn: () => techniciansAdmin.listTechnicianAvailability(technicianId!),
    enabled: !!technicianId,
  })
}

export function useUpsertTechnicianAvailability() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: Parameters<typeof techniciansAdmin.upsertTechnicianAvailability>[0]) =>
      techniciansAdmin.upsertTechnicianAvailability(input),
    onSuccess: (_data, variables) => {
      qc.invalidateQueries({ queryKey: ["technician-availability", variables.technician_id] })
    },
  })
}

export function useDeleteTechnicianAvailability() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ id }: { id: string; technicianId: string }) => techniciansAdmin.deleteTechnicianAvailability(id),
    onSuccess: (_data, variables) => {
      qc.invalidateQueries({ queryKey: ["technician-availability", variables.technicianId] })
    },
  })
}
