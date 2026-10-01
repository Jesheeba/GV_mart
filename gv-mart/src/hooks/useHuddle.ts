import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as huddle from "@/services/huddle"
import type { IssueInput, IssueSearch, IssueStatus } from "@/services/huddle"

const KEY = ["huddle"] as const

export function useMeetingLog(orgId: string | undefined, date: string) {
  return useQuery({ queryKey: [...KEY, "log", orgId, date], queryFn: () => huddle.getMeetingLog(orgId!, date), enabled: !!orgId })
}

export function useAgendaIssues(orgId: string | undefined, date: string, meetingId: string | null, ready: boolean) {
  return useQuery({
    queryKey: [...KEY, "agenda", orgId, date, meetingId],
    queryFn: () => huddle.listAgendaIssues(orgId!, date, meetingId),
    enabled: !!orgId && ready,
  })
}

export function useSearchIssues(orgId: string | undefined, f: IssueSearch) {
  return useQuery({ queryKey: [...KEY, "search", orgId, f], queryFn: () => huddle.searchIssues(orgId!, f), enabled: !!orgId })
}

export function useRecentMeetings(orgId: string | undefined) {
  return useQuery({ queryKey: [...KEY, "recent", orgId], queryFn: () => huddle.listRecentMeetings(orgId!), enabled: !!orgId })
}

export function useIssueTasks(orgId: string | undefined, issueIds: string[]) {
  return useQuery({
    queryKey: ["tasks", "issueTasks", orgId, issueIds],
    queryFn: () => huddle.listIssueTasks(orgId!, issueIds),
    enabled: !!orgId && issueIds.length > 0,
  })
}

export function useHuddlePerformance(orgId: string | undefined, date: string, enabled: boolean) {
  return useQuery({
    queryKey: [...KEY, "performance", orgId, date],
    queryFn: () => huddle.getHuddlePerformance(orgId!, date),
    enabled: !!orgId && enabled,
  })
}

export function useHuddleReminderTime(orgId: string | undefined) {
  return useQuery({ queryKey: [...KEY, "reminderTime", orgId], queryFn: () => huddle.getHuddleReminderTime(orgId!), enabled: !!orgId })
}

function useHuddleMutation<TVars>(fn: (v: TVars) => Promise<unknown>) {
  const qc = useQueryClient()
  return useMutation({ mutationFn: fn, onSuccess: () => qc.invalidateQueries({ queryKey: KEY }) })
}

export const useSaveNotes = (orgId: string, date: string, userId: string) =>
  useHuddleMutation((notes: string) => huddle.saveMeetingNotes(orgId, date, userId, notes))
export const useCreateIssue = (orgId: string, date: string, userId: string) =>
  useHuddleMutation((input: IssueInput) => huddle.createIssue(orgId, date, userId, input))
export const useUpdateIssue = () => useHuddleMutation((v: { id: string; input: IssueInput }) => huddle.updateIssue(v.id, v.input))
export const useSetIssueStatus = (date: string) =>
  useHuddleMutation((v: { id: string; status: IssueStatus }) => huddle.setIssueStatus(v.id, v.status, date))
export const useSetReminderTime = (orgId: string) => useHuddleMutation((time: string | null) => huddle.setHuddleReminderTime(orgId, time))
