import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as svc from "@/services/technicianLeave"
import type { LeaveDecision, LeaveRequestStatus } from "@/services/technicianLeave"

const POLL_MS = 60_000

export function useMyLeaveRequests(technicianId: string | undefined) {
  return useQuery({
    queryKey: ["technician_leave_requests", "mine", technicianId],
    queryFn: () => svc.listMyLeaveRequests(technicianId!),
    enabled: !!technicianId,
    refetchInterval: POLL_MS,
  })
}

export function useOrgLeaveRequests(orgId: string | undefined, status?: LeaveRequestStatus[]) {
  return useQuery({
    queryKey: ["technician_leave_requests", "org", orgId, status],
    queryFn: () => svc.listOrgLeaveRequests(orgId!, { status }),
    enabled: !!orgId,
  })
}

export function usePendingLeaveRequestCount(orgId: string | undefined) {
  return useQuery({
    queryKey: ["technician_leave_requests", "pending_count", orgId],
    queryFn: () => svc.countPendingLeaveRequests(orgId!),
    enabled: !!orgId,
    refetchInterval: POLL_MS,
  })
}

export function useAssignedVisitsInRange(technicianId: string | undefined, startDate: string | undefined, endDate: string | undefined) {
  return useQuery({
    queryKey: ["technician_leave_requests", "assigned_visits", technicianId, startDate, endDate],
    queryFn: () => svc.listAssignedVisitsInRange(technicianId!, startDate!, endDate!),
    enabled: !!technicianId && !!startDate && !!endDate,
  })
}

export function useProtectedLeaveDays(orgId: string | undefined, technicianId: string | undefined, from: string | undefined, to: string | undefined) {
  return useQuery({
    queryKey: ["technician_leave_requests", "protected_days", orgId, technicianId, from, to],
    queryFn: () => svc.getProtectedLeaveDays(orgId!, technicianId!, from!, to!),
    enabled: !!orgId && !!technicianId && !!from && !!to,
  })
}

function invalidateLeave(qc: ReturnType<typeof useQueryClient>) {
  qc.invalidateQueries({ queryKey: ["technician_leave_requests"] })
}

export function useRequestTechnicianLeave() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ startDate, endDate, reason }: { startDate: string; endDate: string; reason: string | null }) =>
      svc.requestTechnicianLeave(startDate, endDate, reason),
    onSuccess: () => invalidateLeave(qc),
  })
}

export function useCancelTechnicianLeave() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (requestId: string) => svc.cancelTechnicianLeave(requestId),
    onSuccess: () => invalidateLeave(qc),
  })
}

export function useDecideTechnicianLeave() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ requestId, decision, note }: { requestId: string; decision: LeaveDecision; note: string | null }) =>
      svc.decideTechnicianLeave(requestId, decision, note),
    onSuccess: () => invalidateLeave(qc),
  })
}
