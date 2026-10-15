import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as taskLogsService from "@/services/taskLogs"
import type { CreateTaskLogInput } from "@/services/taskLogs"

export function useTaskLogs(taskId: string | undefined) {
  return useQuery({
    queryKey: ["taskLogs", taskId],
    queryFn: () => taskLogsService.listTaskLogs(taskId!),
    enabled: !!taskId,
  })
}

export function useCreateTaskLog() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: CreateTaskLogInput) => taskLogsService.createTaskLog(input),
    onSuccess: (_data, input) => qc.invalidateQueries({ queryKey: ["taskLogs", input.taskId] }),
  })
}
