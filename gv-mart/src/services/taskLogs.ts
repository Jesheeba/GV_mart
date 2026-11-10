import { supabase } from "@/lib/supabase"
import type { Tables } from "@/types/database"

export type TaskLog = Tables<"task_logs">

/** The work log of one task, oldest first. Visibility follows the task itself (RLS). */
export async function listTaskLogs(taskId: string): Promise<TaskLog[]> {
  const { data, error } = await supabase.from("task_logs").select("*").eq("task_id", taskId).order("created_at", { ascending: true })
  if (error) throw error
  return data ?? []
}

export type AddTaskLogInput = {
  orgId: string
  taskId: string
  note: string | null
  minutesSpent: number | null
  nextPlannedDate: string | null
  nextPlannedNote: string | null
}

/** Adds a note. Who wrote it and when are stamped by the database; entries cannot be edited or removed. */
export async function addTaskLog(input: AddTaskLogInput): Promise<void> {
  const { error } = await supabase.from("task_logs").insert({
    org_id: input.orgId,
    task_id: input.taskId,
    note: input.note,
    minutes_spent: input.minutesSpent,
    next_planned_date: input.nextPlannedDate,
    next_planned_note: input.nextPlannedNote,
  })
  if (error) throw error
}
