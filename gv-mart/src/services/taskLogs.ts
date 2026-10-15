import { supabase } from "@/lib/supabase"
import type { Tables } from "@/types/database"

export type TaskLogRow = Tables<"task_logs">
export type TaskLogWithAuthor = TaskLogRow & { author: { full_name: string } | null }

/** Append-only — task_logs has no update/delete policy (20261103100000), so a correction is a new entry. */
export async function listTaskLogs(taskId: string): Promise<TaskLogWithAuthor[]> {
  const { data, error } = await supabase
    .from("task_logs")
    .select("*, author:profiles!task_logs_created_by_fkey(full_name)")
    .eq("task_id", taskId)
    .order("created_at", { ascending: false })
  if (error) throw error
  return (data ?? []) as unknown as TaskLogWithAuthor[]
}

export type CreateTaskLogInput = {
  orgId: string
  taskId: string
  createdBy: string
  note: string | null
  minutesSpent: number | null
  nextPlannedDate: string | null
  nextPlannedNote: string | null
}

export async function createTaskLog(input: CreateTaskLogInput): Promise<TaskLogRow> {
  const { data, error } = await supabase
    .from("task_logs")
    .insert({
      org_id: input.orgId,
      task_id: input.taskId,
      created_by: input.createdBy,
      note: input.note,
      minutes_spent: input.minutesSpent,
      next_planned_date: input.nextPlannedDate,
      next_planned_note: input.nextPlannedNote,
    })
    .select()
    .single()
  if (error) throw error
  return data
}
