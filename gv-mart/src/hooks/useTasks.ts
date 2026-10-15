import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as tasksService from "@/services/tasks"
import type { AssignTaskInput, TaskRow, UpdateTaskInput } from "@/services/tasks"
import type { Enums } from "@/types/database"

export function useOrgTasks(orgId: string | undefined) {
  return useQuery({
    queryKey: ["tasks", "org", orgId],
    queryFn: () => tasksService.listOrgTasks(orgId!),
    enabled: !!orgId,
  })
}

export function useAssignableProfiles(orgId: string | undefined) {
  return useQuery({
    queryKey: ["tasks", "assignableProfiles", orgId],
    queryFn: () => tasksService.listAssignableProfiles(orgId!),
    enabled: !!orgId,
  })
}

export function useAssignTask() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: AssignTaskInput) => tasksService.assignTask(input),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["tasks"] })
    },
  })
}

export function useUpdateTask() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: UpdateTaskInput) => tasksService.updateTask(input),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["tasks"] }),
  })
}

export function useDeleteTask() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (id: string) => tasksService.deleteTask(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["tasks"] }),
  })
}

export function useSetOrgTaskStatus() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ id, status }: { id: string; status: Enums<"task_status"> }) => tasksService.setTaskStatus(id, status),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["tasks"] }),
  })
}

// P3: replaces the lazy "rollover on read" workspace.ts used to do on every fetch.
export function useMoveTaskToToday() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (task: Pick<TaskRow, "id" | "due_date" | "original_due_date" | "rolled_count">) => tasksService.moveTaskToToday(task),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["tasks"] }),
  })
}
