import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as segments from "@/services/audienceSegments"
import type { SegmentConditionTree } from "@/services/audienceSegments"

export function useAudienceSegments(orgId: string | undefined) {
  return useQuery({ queryKey: ["audienceSegments", orgId], queryFn: () => segments.listAudienceSegments(orgId!), enabled: !!orgId })
}

export function useSaveAudienceSegment() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: segments.saveAudienceSegment,
    onSuccess: () => qc.invalidateQueries({ queryKey: ["audienceSegments"] }),
  })
}

export function useDeleteAudienceSegment() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: segments.deleteAudienceSegment,
    onSuccess: () => qc.invalidateQueries({ queryKey: ["audienceSegments"] }),
  })
}

export function useSegmentMatchCount(orgId: string | undefined, conditionTree: SegmentConditionTree | undefined) {
  return useQuery({
    queryKey: ["segmentMatchCount", orgId, conditionTree],
    queryFn: () => segments.matchCount(orgId!, conditionTree!),
    enabled: !!orgId && !!conditionTree && conditionTree.conditions.length > 0,
  })
}

export function useSegmentMatchPreview() {
  return useMutation({ mutationFn: ({ orgId, conditionTree }: { orgId: string; conditionTree: SegmentConditionTree }) => segments.matchPreview(orgId, conditionTree) })
}

export function useSendSegmentNow() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: segments.sendSegmentNow,
    onSuccess: (_data, segmentId) => qc.invalidateQueries({ queryKey: ["segmentRuns", segmentId] }),
  })
}

export function useSetSegmentStanding() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ segmentId, isStanding, wasiTemplateName }: { segmentId: string; isStanding: boolean; wasiTemplateName: string | null }) =>
      segments.setSegmentStanding(segmentId, isStanding, wasiTemplateName),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["audienceSegments"] }),
  })
}

export function useSegmentRuns(segmentId: string | undefined) {
  return useQuery({ queryKey: ["segmentRuns", segmentId], queryFn: () => segments.listSegmentRuns(segmentId!), enabled: !!segmentId })
}

export function useApprovedTemplateNames() {
  return useQuery({ queryKey: ["approvedTemplateNames"], queryFn: segments.listApprovedTemplateNames })
}
