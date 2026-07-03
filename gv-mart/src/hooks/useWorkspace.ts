import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as workspace from "@/services/workspace"
import type { CreateTaskInput } from "@/services/workspace"
import type { Enums } from "@/types/database"

export function useMyWorkspaceTasks(orgId: string | undefined, assigneeId: string | undefined) {
  return useQuery({
    queryKey: ["tasks", "workspace", "today", orgId, assigneeId],
    queryFn: () => workspace.listMyWorkspaceTasks(orgId!, assigneeId!),
    enabled: !!orgId && !!assigneeId,
  })
}

export function useUpcomingWorkspaceTasks(orgId: string | undefined, assigneeId: string | undefined) {
  return useQuery({
    queryKey: ["tasks", "workspace", "upcoming", orgId, assigneeId],
    queryFn: () => workspace.listUpcomingWorkspaceTasks(orgId!, assigneeId!),
    enabled: !!orgId && !!assigneeId,
  })
}

export function useCompletedWorkspaceTasks(orgId: string | undefined, assigneeId: string | undefined) {
  return useQuery({
    queryKey: ["tasks", "workspace", "completed", orgId, assigneeId],
    queryFn: () => workspace.listCompletedWorkspaceTasks(orgId!, assigneeId!),
    enabled: !!orgId && !!assigneeId,
  })
}

export function useCreateTask() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: CreateTaskInput) => workspace.createTask(input),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["tasks", "workspace"] }),
  })
}

export function useSetTaskStatus() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ id, status }: { id: string; status: Enums<"task_status"> }) => workspace.setTaskStatus(id, status),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["tasks", "workspace"] }),
  })
}

export function useMyNotificationsFeed(orgId: string | undefined, userId: string | undefined, role: Enums<"user_role"> | undefined) {
  return useQuery({
    queryKey: ["notifications", "feed", orgId, userId, role],
    queryFn: () => workspace.listMyNotificationsFeed(orgId!, userId!, role!),
    enabled: !!orgId && !!userId && !!role,
  })
}

export function useLogConfirmationCall() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ orgId, userId, ticketLabel }: { orgId: string; userId: string; ticketLabel: string }) =>
      workspace.logConfirmationCallAction(orgId, userId, ticketLabel),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["notifications"] }),
  })
}

export function useDaySheetSummary(orgId: string | undefined, technicianId: string | undefined) {
  return useQuery({
    queryKey: ["daySheet", "summary", orgId, technicianId],
    queryFn: () => workspace.getDaySheetSummary(orgId!, technicianId!),
    enabled: !!orgId && !!technicianId,
  })
}
