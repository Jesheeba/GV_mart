import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2, Trash2 } from "lucide-react"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { DatePicker } from "@/components/ui/date-picker"
import { useToast } from "@/components/ui/toast-context"
import { useAssignableProfiles, useDeleteTask, useSetOrgTaskStatus, useUpdateTask } from "@/hooks/useTasks"
import { useCreateTaskLog, useTaskLogs } from "@/hooks/useTaskLogs"
import { getIstNow } from "@/lib/ist"
import type { OrgTask, PriorityLevel } from "@/services/tasks"
import { cn } from "@/lib/utils"

const PRIORITIES: PriorityLevel[] = ["normal", "urgent", "very_urgent"]

function toDateOnly(iso: string) {
  return iso.slice(0, 10)
}
function toTimeOnly(iso: string) {
  return new Date(iso).toTimeString().slice(0, 5)
}

/** Click-to-view/edit surface opened from both the list row and calendar event click — reassignment, priority, due date/time, status, and (ops-only) delete, all on the one task. */
export function TaskDetailDialog({
  task,
  orgId,
  userId,
  canDelete,
  onClose,
}: {
  task: OrgTask
  orgId: string
  userId: string
  canDelete: boolean
  onClose: () => void
}) {
  const { t } = useTranslation()
  const { toast } = useToast()
  const { data: assignableProfiles } = useAssignableProfiles(orgId)
  const updateTask = useUpdateTask()
  const setStatus = useSetOrgTaskStatus()
  const deleteTask = useDeleteTask()

  const [title, setTitle] = useState(task.title)
  const [description, setDescription] = useState(task.description ?? "")
  const [assigneeId, setAssigneeId] = useState(task.assignee_id ?? "")
  const [priority, setPriority] = useState<PriorityLevel>(task.priority)
  const [dueDate, setDueDate] = useState(task.due_at ? toDateOnly(task.due_at) : (task.due_date ?? ""))
  const [dueTime, setDueTime] = useState(task.due_at ? toTimeOnly(task.due_at) : "")
  const [isRecurring, setIsRecurring] = useState(task.is_recurring)

  const isDone = task.status === "done"
  const canSubmit = title.trim().length > 0 && assigneeId.length > 0 && !updateTask.isPending

  function handleSave() {
    if (!canSubmit) return
    const dueAt = dueDate && dueTime ? new Date(`${dueDate}T${dueTime}`).toISOString() : null
    updateTask.mutate(
      {
        id: task.id,
        title: title.trim(),
        description: description.trim() || null,
        assigneeId,
        assignedBy: userId,
        priority,
        dueDate: dueDate || null,
        dueAt,
        isRecurring: isRecurring && !!dueDate,
      },
      { onSuccess: () => onClose(), onError: () => toast.error(t("common.actionFailed")) }
    )
  }

  function handleDelete() {
    if (!window.confirm(t("tasks.detailDialog.confirmDelete"))) return
    deleteTask.mutate(task.id, { onSuccess: () => onClose(), onError: () => toast.error(t("common.actionFailed")) })
  }

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent>
        <DialogTitle>{t("tasks.detailDialog.title")}</DialogTitle>
        <DialogDescription>{t("tasks.detailDialog.subtitle")}</DialogDescription>

        <div className="flex items-center gap-2">
          <button
            type="button"
            onClick={() => setStatus.mutate({ id: task.id, status: isDone ? "open" : "done" })}
            disabled={setStatus.isPending}
            className={cn(
              "flex size-6 shrink-0 items-center justify-center rounded-full border transition-colors",
              isDone ? "border-success bg-success text-white" : "border-border text-transparent hover:border-ink"
            )}
            aria-label={t(isDone ? "workspace.markOpen" : "workspace.markDone")}
          >
            {setStatus.isPending ? <Loader2 className="size-3 animate-spin" /> : "✓"}
          </button>
          <span className="text-xs font-medium text-text-muted">{t(isDone ? "tasks.detailDialog.statusDone" : "tasks.detailDialog.statusOpen")}</span>
        </div>

        <div className="space-y-1.5">
          <Label htmlFor="detailTitle">{t("tasks.assignDialog.taskTitle")}</Label>
          <Input id="detailTitle" value={title} onChange={(e) => setTitle(e.target.value)} />
        </div>

        <div className="space-y-1.5">
          <Label htmlFor="detailDescription">{t("tasks.assignDialog.description")}</Label>
          <Input id="detailDescription" value={description} onChange={(e) => setDescription(e.target.value)} />
        </div>

        <div className="space-y-1.5">
          <div className="flex items-center justify-between">
            <Label htmlFor="detailAssignee">{t("tasks.assignDialog.assignTo")}</Label>
            <button type="button" onClick={() => setAssigneeId(userId)} className="text-xs font-semibold text-accent hover:underline">
              {t("tasks.assignDialog.assignToMe")}
            </button>
          </div>
          <select
            id="detailAssignee"
            value={assigneeId}
            onChange={(e) => setAssigneeId(e.target.value)}
            className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
          >
            {(assignableProfiles ?? []).map((p) => (
              <option key={p.id} value={p.id}>
                {p.full_name} · {t(`tasks.roleLabel.${p.role}`)}
              </option>
            ))}
          </select>
          {task.assigner ? <p className="text-xs text-text-muted">{t("tasks.assignedBy", { name: task.assigner.full_name })}</p> : null}
        </div>

        <div className="space-y-1.5">
          <Label>{t("tasks.assignDialog.priority")}</Label>
          <div className="flex w-fit gap-1 rounded-full bg-surface-alt p-1">
            {PRIORITIES.map((p) => (
              <button
                key={p}
                type="button"
                onClick={() => setPriority(p)}
                className={cn("rounded-full px-4 py-1.5 text-sm font-medium transition-colors", priority === p ? "bg-ink text-white" : "text-text-muted")}
              >
                {t(`service.priority.${p}`)}
              </button>
            ))}
          </div>
        </div>

        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <div className="space-y-1.5">
            <Label htmlFor="detailDueDate">{t("tasks.assignDialog.dueDate")}</Label>
            <DatePicker
              id="detailDueDate"
              value={dueDate}
              onChange={(value) => {
                setDueDate(value)
                if (!value) setIsRecurring(false)
              }}
            />
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="detailDueTime">{t("tasks.assignDialog.dueTime")}</Label>
            <Input id="detailDueTime" type="time" value={dueTime} onChange={(e) => setDueTime(e.target.value)} disabled={!dueDate} />
          </div>
        </div>

        <label className={cn("flex items-center gap-2.5 rounded-xl border border-border bg-surface-alt px-3.5 py-2.5 text-sm text-text", !dueDate && "opacity-50")}>
          <input
            type="checkbox"
            className="size-4 accent-accent"
            checked={isRecurring}
            disabled={!dueDate}
            onChange={(e) => setIsRecurring(e.target.checked)}
          />
          <span className="font-medium">{t("tasks.assignDialog.repeatMonthly")}</span>
        </label>
        {!dueDate ? <p className="text-xs text-text-muted">{t("tasks.assignDialog.repeatMonthlyHint")}</p> : null}

        <TaskWorkLog taskId={task.id} orgId={orgId} userId={userId} />

        <div className="flex items-center justify-between gap-2 pt-1">
          {canDelete ? (
            <Button type="button" variant="ghost" onClick={handleDelete} disabled={deleteTask.isPending} className="text-danger hover:text-danger">
              {deleteTask.isPending ? <Loader2 className="size-3.5 animate-spin" /> : <Trash2 className="size-3.5" />}
              {t("common.delete")}
            </Button>
          ) : (
            <span />
          )}
          <div className="flex gap-2">
            <Button type="button" variant="outline" onClick={onClose}>
              {t("common.cancel")}
            </Button>
            <Button type="button" onClick={handleSave} disabled={!canSubmit}>
              {updateTask.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("common.save")}
            </Button>
          </div>
        </div>
      </DialogContent>
    </Dialog>
  )
}

/**
 * P3: a work-log entry — a note, minutes spent, and what's planned next (and when). Append-only (task_logs has no
 * update/delete policy, 20261103100000): a correction is a new entry, not an edit of history. Visible to whoever
 * can see the task at all (same RLS); this dialog itself is already only opened by someone who can see the task.
 */
function TaskWorkLog({ taskId, orgId, userId }: { taskId: string; orgId: string; userId: string }) {
  const { t } = useTranslation()
  const logs = useTaskLogs(taskId)
  const createLog = useCreateTaskLog()

  const [note, setNote] = useState("")
  const [minutes, setMinutes] = useState("")
  const [nextPlannedDate, setNextPlannedDate] = useState("")
  const [nextPlannedNote, setNextPlannedNote] = useState("")

  const minutesValue = minutes.trim() === "" ? null : Number(minutes)
  const minutesValid = minutesValue === null || (Number.isInteger(minutesValue) && minutesValue >= 0 && minutesValue <= 1440)
  const hasContent = note.trim() !== "" || minutesValue !== null || nextPlannedDate !== "" || nextPlannedNote.trim() !== ""
  const canLog = hasContent && minutesValid && !createLog.isPending

  function handleAddLog() {
    if (!canLog) return
    createLog.mutate(
      {
        orgId,
        taskId,
        createdBy: userId,
        note: note.trim() || null,
        minutesSpent: minutesValue,
        nextPlannedDate: nextPlannedDate || null,
        nextPlannedNote: nextPlannedNote.trim() || null,
      },
      {
        onSuccess: () => {
          setNote("")
          setMinutes("")
          setNextPlannedDate("")
          setNextPlannedNote("")
        },
      }
    )
  }

  return (
    <div className="space-y-2 rounded-xl border border-border bg-surface-alt p-3.5">
      <Label className="text-xs font-semibold text-text-muted">{t("tasks.workLog.title")}</Label>

      {logs.isLoading ? (
        <p className="text-xs text-text-muted">{t("common.loading")}</p>
      ) : (logs.data?.length ?? 0) === 0 ? (
        <p className="text-xs text-text-muted">{t("tasks.workLog.empty")}</p>
      ) : (
        <ul className="space-y-2">
          {logs.data!.map((entry) => (
            <li key={entry.id} className="rounded-lg border border-border bg-surface px-3 py-2 text-xs">
              <div className="flex flex-wrap items-center gap-x-2 text-text-muted">
                <span className="font-medium text-text">{entry.author?.full_name ?? t("tasks.unknownUser")}</span>
                <span>· {new Date(entry.created_at).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" })}</span>
                {entry.minutes_spent !== null ? <span>· {t("tasks.workLog.minutes", { count: entry.minutes_spent })}</span> : null}
              </div>
              {entry.note ? <p className="mt-1 text-text">{entry.note}</p> : null}
              {entry.next_planned_date || entry.next_planned_note ? (
                <p className="mt-1 text-text-muted">
                  {t("tasks.workLog.nextPlanned")}
                  {entry.next_planned_date ? ` ${entry.next_planned_date}` : ""}
                  {entry.next_planned_note ? ` — ${entry.next_planned_note}` : ""}
                </p>
              ) : null}
            </li>
          ))}
        </ul>
      )}

      <div className="space-y-2 pt-1">
        <Input placeholder={t("tasks.workLog.notePlaceholder")} value={note} maxLength={2000} onChange={(e) => setNote(e.target.value)} />
        <div className="grid grid-cols-1 gap-2 sm:grid-cols-3">
          <Input
            type="number"
            min={0}
            max={1440}
            placeholder={t("tasks.workLog.minutesPlaceholder")}
            value={minutes}
            onChange={(e) => setMinutes(e.target.value)}
          />
          <DatePicker
            value={nextPlannedDate}
            onChange={setNextPlannedDate}
            min={getIstNow().date}
            aria-label={t("tasks.workLog.nextPlannedDate")}
          />
          <Input placeholder={t("tasks.workLog.nextPlannedNotePlaceholder")} value={nextPlannedNote} maxLength={500} onChange={(e) => setNextPlannedNote(e.target.value)} />
        </div>
        {!minutesValid ? <p className="text-xs text-danger">{t("tasks.workLog.minutesInvalid")}</p> : null}
        <div className="flex justify-end">
          <Button type="button" size="sm" variant="outline" disabled={!canLog} onClick={handleAddLog}>
            {createLog.isPending ? <Loader2 className="size-3.5 animate-spin" /> : null}
            {t("tasks.workLog.add")}
          </Button>
        </div>
      </div>
    </div>
  )
}
