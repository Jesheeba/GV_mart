import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as tasksService from "@/services/tasks"
import type { AssignTaskInput } from "@/services/tasks"
import { setTaskStatus } from "@/services/workspace"
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

// Reuses workspace.ts's setTaskStatus (same `tasks` table) but invalidates
// the whole ["tasks", ...] key space, not just ["tasks", "workspace"] —
// useWorkspace's own useSetTaskStatus wouldn't refresh this page's
// ["tasks", "org", orgId] list.
export function useSetOrgTaskStatus() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ id, status }: { id: string; status: Enums<"task_status"> }) => setTaskStatus(id, status),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["tasks"] }),
  })
}
