import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as svc from "@/services/leadFollowups"
import type { FollowupFilters } from "@/services/leadFollowups"
import type { UserRole } from "@/lib/roles"

const POLL_MS = 60_000

/** Roles that may see follow-ups (master + sales_admin). Everyone else never fires the queries. */
export function canWorkFollowups(role: UserRole | undefined): boolean {
  return role === "master" || role === "sales_admin"
}

export function useLeadOutcomes(orgId: string | undefined) {
  return useQuery({
    queryKey: ["lead_outcomes", "list", orgId],
    queryFn: () => svc.listLeadOutcomes(orgId!),
    enabled: !!orgId,
    staleTime: 5 * 60_000,
  })
}
export function useCreateLeadOutcome() {
  const qc = useQueryClient()
  return useMutation({ mutationFn: svc.createLeadOutcome, onSuccess: () => qc.invalidateQueries({ queryKey: ["lead_outcomes"] }) })
}
export function useUpdateLeadOutcome() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ id, patch }: { id: string; patch: Parameters<typeof svc.updateLeadOutcome>[1] }) => svc.updateLeadOutcome(id, patch),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["lead_outcomes"] }),
  })
}

export function useLeadSchedule(orgId: string | undefined) {
  return useQuery({
    queryKey: ["lead_schedule", orgId],
    queryFn: () => svc.getLeadSchedule(orgId!),
    enabled: !!orgId,
    staleTime: 5 * 60_000,
  })
}
export function useUpdateLeadSchedule(orgId: string | undefined) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (patch: Partial<svc.LeadSchedule>) => svc.updateLeadSchedule(orgId!, patch),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["lead_schedule", orgId] }),
  })
}

export function useFollowups(filters: FollowupFilters, enabled = true) {
  return useQuery({
    queryKey: ["followups", "list", filters],
    queryFn: () => svc.listFollowups(filters),
    enabled,
    refetchInterval: POLL_MS,
  })
}

/** Open leads nobody has scheduled (My Day "No follow-up" tab). */
export function useLeadsWithoutFollowup(filters: svc.NoFollowupFilters, enabled = true) {
  return useQuery({
    queryKey: ["followups", "none", filters],
    queryFn: () => svc.listLeadsWithoutFollowup(filters),
    enabled,
    refetchInterval: POLL_MS,
  })
}

/** Today + overdue badge for the menu. */
export function useFollowupCounts(role: UserRole | undefined) {
  return useQuery({
    queryKey: ["followups", "counts"],
    queryFn: svc.getFollowupCounts,
    enabled: canWorkFollowups(role),
    refetchInterval: POLL_MS,
  })
}

export function useLeadTimeline(leadId: string | undefined) {
  return useQuery({
    queryKey: ["followups", "timeline", leadId],
    queryFn: () => svc.getLeadTimeline(leadId!),
    enabled: !!leadId,
  })
}

export function useOpenFollowup(leadId: string | undefined) {
  return useQuery({
    queryKey: ["followups", "open", leadId],
    queryFn: () => svc.getOpenFollowup(leadId!),
    enabled: !!leadId,
  })
}

function useInvalidateLeadWork() {
  const qc = useQueryClient()
  return () => {
    qc.invalidateQueries({ queryKey: ["followups"] })
    qc.invalidateQueries({ queryKey: ["leads"] })
  }
}

export function useLogLeadOutcome() {
  const done = useInvalidateLeadWork()
  return useMutation({ mutationFn: svc.logLeadOutcome, onSuccess: done })
}
export function useRescheduleFollowup() {
  const done = useInvalidateLeadWork()
  return useMutation({ mutationFn: svc.rescheduleFollowup, onSuccess: done })
}
export function useSetLeadFollowup() {
  const done = useInvalidateLeadWork()
  return useMutation({ mutationFn: svc.setLeadFollowup, onSuccess: done })
}
export function useReopenLead() {
  const done = useInvalidateLeadWork()
  return useMutation({ mutationFn: svc.reopenLead, onSuccess: done })
}
export function useLeadAssignees(orgId: string | undefined, role: UserRole | undefined) {
  return useQuery({
    queryKey: ["lead_assignees", orgId],
    queryFn: () => svc.listLeadAssignees(orgId!),
    enabled: !!orgId && canWorkFollowups(role),
    staleTime: 5 * 60_000,
  })
}
export function useAssignLead() {
  const done = useInvalidateLeadWork()
  return useMutation({ mutationFn: svc.assignLead, onSuccess: done })
}
export function useSetFollowupsBulk() {
  const done = useInvalidateLeadWork()
  return useMutation({ mutationFn: svc.setLeadFollowupsBulk, onSuccess: done })
}
export function useAddLeadNote() {
  const done = useInvalidateLeadWork()
  return useMutation({ mutationFn: ({ leadId, note }: { leadId: string; note: string }) => svc.addLeadNote(leadId, note), onSuccess: done })
}
