import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as taskLogs from "@/services/taskLogs"
import type { AddTaskLogInput } from "@/services/taskLogs"
import { useToast } from "@/components/ui/toast-context"

export function useTaskLogs(taskId: string | undefined) {
  return useQuery({
    queryKey: ["tasks", "logs", taskId],
    queryFn: () => taskLogs.listTaskLogs(taskId!),
    enabled: !!taskId,
  })
}

export function useAddTaskLog() {
  const qc = useQueryClient()
  const { toast } = useToast()
  return useMutation({
    mutationFn: (input: AddTaskLogInput) => taskLogs.addTaskLog(input),
    onSuccess: (_d, v) => qc.invalidateQueries({ queryKey: ["tasks", "logs", v.taskId] }),
    onError: (e) => toast.error(e instanceof Error && e.message ? e.message : "Could not add the note"),
  })
}
