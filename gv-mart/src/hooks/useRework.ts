import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as rework from "@/services/rework"
import { triggerWaDispatchNow } from "@/services/whatsapp"

export function useMarkTicketRework() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: rework.MarkReworkInput) => rework.markTicketRework(input),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["service_tickets"] })
      qc.invalidateQueries({ queryKey: ["appointments"] })
      qc.invalidateQueries({ queryKey: ["rework"] })
      triggerWaDispatchNow()
    },
  })
}

export function useReworkCandidate(orgId: string | undefined, customerId: string | undefined, productId: string | undefined, windowDays: number) {
  return useQuery({
    queryKey: ["rework", "candidate", orgId, customerId, productId, windowDays],
    queryFn: () => rework.findReworkCandidate(orgId!, customerId!, productId!, windowDays),
    enabled: !!orgId && !!customerId && !!productId,
  })
}

export function useReworkChild(ticketId: string | undefined) {
  return useQuery({
    queryKey: ["rework", "child", ticketId],
    queryFn: () => rework.getReworkChild(ticketId!),
    enabled: !!ticketId,
  })
}

export function useReworkEscalation(ticketId: string | undefined, enabled = true) {
  return useQuery({
    queryKey: ["rework", "escalation", ticketId],
    queryFn: () => rework.getReworkEscalation(ticketId!),
    enabled: !!ticketId && enabled,
  })
}

export function useRequestReworkEscalation() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: { ticketId: string; reason: string }) => rework.requestReworkEscalation(input.ticketId, input.reason),
    onSuccess: (_d, v) => qc.invalidateQueries({ queryKey: ["rework", "escalation", v.ticketId] }),
  })
}

export function useReworkSummary(from: string, to: string) {
  return useQuery({
    queryKey: ["rework", "summary", from, to],
    queryFn: () => rework.reportReworkSummary(from, to),
    enabled: !!from && !!to,
  })
}
