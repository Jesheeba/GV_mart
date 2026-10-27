import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as tasksService from "@/services/tasks"
import type { AssignTaskInput, UpdateTaskInput } from "@/services/tasks"
import { setTaskStatus } from "@/services/workspace"
import type { Enums } from "@/types/database"
import { useToast } from "@/components/ui/toast-context"

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

// Reuses workspace.ts's setTaskStatus (same `tasks` table) but invalidates
// the whole ["tasks", ...] key space, not just ["tasks", "workspace"] —
// useWorkspace's own useSetTaskStatus wouldn't refresh this page's
// ["tasks", "org", orgId] list.
export function useSetOrgTaskStatus() {
  const qc = useQueryClient()
  const { toast } = useToast()
  return useMutation({
    mutationFn: ({ id, status }: { id: string; status: Enums<"task_status"> }) => setTaskStatus(id, status),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["tasks"] }),
    // the database says why (only the assignee can finish a task, a PO task needs a master)
    onError: (e) => toast.error(e instanceof Error && e.message ? e.message : "Could not update the task"),
  })
}
