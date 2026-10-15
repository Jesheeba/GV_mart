import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as svc from "@/services/followupQuestions"
import type { UserRole } from "@/lib/roles"

export function useFollowupQuestionList(orgId: string | undefined) {
  return useQuery({ queryKey: ["followupQuestions", "list", orgId], queryFn: () => svc.listFollowupQuestions(orgId!), enabled: !!orgId })
}

export function useFollowupQuestionTypeLinks(orgId: string | undefined) {
  return useQuery({ queryKey: ["followupQuestions", "links", orgId], queryFn: () => svc.listFollowupQuestionTypeLinks(orgId!), enabled: !!orgId })
}

function useInvalidate() {
  const qc = useQueryClient()
  return () => qc.invalidateQueries({ queryKey: ["followupQuestions"] })
}

export function useCreateFollowupQuestion() {
  const inv = useInvalidate()
  return useMutation({ mutationFn: svc.createFollowupQuestion, onSuccess: inv })
}

export function useUpdateFollowupQuestion() {
  const inv = useInvalidate()
  return useMutation({
    mutationFn: ({ id, patch }: { id: string; patch: Parameters<typeof svc.updateFollowupQuestion>[1] }) => svc.updateFollowupQuestion(id, patch),
    onSuccess: inv,
  })
}

export function useSetFollowupQuestionTypeLink() {
  const inv = useInvalidate()
  return useMutation({ mutationFn: svc.setFollowupQuestionTypeLink, onSuccess: inv })
}

/** Questions for one call sheet. Fetched fresh each time the sheet opens, so a question the master just turned on appears. */
export function usePostServiceQuestions(followupId: string | undefined) {
  return useQuery({
    queryKey: ["followupQuestions", "forCall", followupId],
    queryFn: () => svc.getPostServiceQuestions(followupId!),
    enabled: !!followupId,
    staleTime: 0,
    gcTime: 0,
  })
}

export function useCustomerPostServiceCalls(customerId: string | undefined, role: UserRole | undefined) {
  const allowed = role === "master" || role === "sales_admin" || role === "operation_admin"
  return useQuery({
    queryKey: ["postServiceCalls", "customer", customerId],
    queryFn: () => svc.listCustomerPostServiceCalls(customerId!),
    enabled: !!customerId && allowed,
  })
}

export function useFollowupAnswersReport(from: string, to: string, enabled: boolean) {
  return useQuery({ queryKey: ["followupQuestions", "report", from, to], queryFn: () => svc.getFollowupAnswersReport(from, to), enabled })
}
