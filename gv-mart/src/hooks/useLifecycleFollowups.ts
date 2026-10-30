import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as svc from "@/services/lifecycleFollowups"

const POLL_MS = 60_000

/** Product Lifecycle follow-ups for the shared Sales/Master Daily Follow Up list (W5). Server-gated to
 * is_sales_staff() (master + sales_admin), same as the rest of this screen -- no extra client role check here. */
export function useLifecycleFollowups(orgId: string | undefined) {
  return useQuery({
    queryKey: ["lifecycleFollowups", orgId],
    queryFn: () => svc.listLifecycleFollowupsForSales(orgId!),
    enabled: !!orgId,
    refetchInterval: POLL_MS,
  })
}

function useInvalidateLifecycleFollowups(orgId: string | undefined) {
  const qc = useQueryClient()
  return () => qc.invalidateQueries({ queryKey: ["lifecycleFollowups", orgId] })
}

export function useMarkFollowupContacted(orgId: string | undefined) {
  const done = useInvalidateLifecycleFollowups(orgId)
  return useMutation({ mutationFn: svc.markLifecycleFollowupContacted, onSuccess: done })
}

export function useSnoozeFollowup(orgId: string | undefined) {
  const done = useInvalidateLifecycleFollowups(orgId)
  return useMutation({ mutationFn: svc.snoozeLifecycleFollowup, onSuccess: done })
}

export function useCreateServiceRequest(orgId: string | undefined) {
  const done = useInvalidateLifecycleFollowups(orgId)
  return useMutation({ mutationFn: svc.createLifecycleServiceRequest, onSuccess: done })
}
