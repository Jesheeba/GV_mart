import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as svc from "@/services/postServiceFollowups"
import type { FollowupScope } from "@/services/leadFollowups"
import { canWorkFollowups } from "@/hooks/useLeadFollowups"
import type { UserRole } from "@/lib/roles"

const POLL_MS = 60_000

// The ["followups", ...] prefix means every existing invalidation (Log outcome, reschedule …) also refreshes these,
// and logging a call refreshes the lead lists + the sidebar badge.
export function usePostServiceFollowups(scope: FollowupScope, role: UserRole | undefined) {
  return useQuery({
    queryKey: ["followups", "postService", scope],
    queryFn: () => svc.listPostServiceFollowups({ scope }),
    enabled: canWorkFollowups(role),
    refetchInterval: POLL_MS,
  })
}

export function useLogPostServiceCall() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: svc.logPostServiceCall,
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["followups"] })
      qc.invalidateQueries({ queryKey: ["postServiceCalls"] })
      qc.invalidateQueries({ queryKey: ["notifications"] })
    },
  })
}

export function useTicketPostServiceCalls(ticketId: string | undefined) {
  return useQuery({
    queryKey: ["postServiceCalls", ticketId],
    queryFn: () => svc.listTicketPostServiceCalls(ticketId!),
    enabled: !!ticketId,
  })
}
