import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Bell, CheckCircle2, Loader2, Plus, RotateCcw } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { useProfile } from "@/hooks/useProfile"
import {
  useCompletedWorkspaceTasks,
  useCreateTask,
  useLogConfirmationCall,
  useMyNotificationsFeed,
  useMyWorkspaceTasks,
  useSetTaskStatus,
  useUpcomingWorkspaceTasks,
} from "@/hooks/useWorkspace"
import type { TaskRow } from "@/services/workspace"
import { createTaskSchema } from "@/lib/validation/systemPages"
import { cn } from "@/lib/utils"

function todayIso() {
  return new Date().toISOString().slice(0, 10)
}

function TaskItem({ task, onToggle, isMutating }: { task: TaskRow; onToggle: () => void; isMutating: boolean }) {
  const { t } = useTranslation()
  const isRolled = !!task.due_date && task.due_date < todayIso() && task.status === "open"
  const isDone = task.status === "done"

  return (
    <div className={cn("flex items-center gap-3 rounded-xl border border-border px-3 py-2.5", isRolled && "border-warning/40 bg-warning/5")}>
      <button
        type="button"
        onClick={onToggle}
        disabled={isMutating}
        className={cn(
          "flex size-5 shrink-0 items-center justify-center rounded-full border transition-colors",
          isDone ? "border-success bg-success text-white" : "border-border text-transparent hover:border-ink"
        )}
        aria-label={t(isDone ? "workspace.markOpen" : "workspace.markDone")}
      >
        <CheckCircle2 className="size-3.5" />
      </button>
      <div className="min-w-0 flex-1">
        <p className={cn("truncate text-sm font-medium text-text", isDone && "text-text-muted line-through")}>{task.title}</p>
        <div className="flex items-center gap-2 text-xs text-text-muted">
          {task.due_date ? <span>{task.due_date}</span> : null}
          {isRolled ? (
            <span className="flex items-center gap-1 text-warning">
              <RotateCcw className="size-3" /> {t("workspace.rolledOver")}
            </span>
          ) : null}
          {task.source && task.source !== "manual" ? <span>· {task.source}</span> : null}
        </div>
      </div>
    </div>
  )
}

export function WorkspacePage() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id
  const userId = profile?.id

  const todaysTasks = useMyWorkspaceTasks(orgId, userId)
  const upcomingTasks = useUpcomingWorkspaceTasks(orgId, userId)
  const completedTasks = useCompletedWorkspaceTasks(orgId, userId)
  const notifications = useMyNotificationsFeed(orgId, userId, profile?.role)

  const createTask = useCreateTask()
  const setTaskStatus = useSetTaskStatus()
  const logConfirmationCall = useLogConfirmationCall()

  const [newTitle, setNewTitle] = useState("")
  const [newDueDate, setNewDueDate] = useState(todayIso())
  const [confirmed, setConfirmed] = useState(false)

  const parsed = createTaskSchema.safeParse({ title: newTitle, dueDate: newDueDate })

  function handleAddTask() {
    if (!parsed.success || !orgId || !userId) return
    createTask.mutate(
      { orgId, assigneeId: userId, title: newTitle.trim(), dueDate: newDueDate || null },
      { onSuccess: () => setNewTitle("") }
    )
  }

  function handleToggle(task: TaskRow) {
    setTaskStatus.mutate({ id: task.id, status: task.status === "done" ? "open" : "done" })
  }

  function handleConfirmationCall() {
    if (!orgId || !userId) return
    logConfirmationCall.mutate({ orgId, userId, ticketLabel: t("workspace.confirmationCall.genericLabel") }, { onSuccess: () => setConfirmed(true) })
  }

  return (
    <div className="space-y-4 pt-2">
      <div>
        <h1 className="text-2xl font-bold text-text">{t("nav.workspace")}</h1>
        <p className="text-sm text-text-muted">{t("workspace.subtitle")}</p>
      </div>

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-3">
        <div className="space-y-4 lg:col-span-2">
          <Card size="default">
            <p className="mb-3 text-sm font-semibold text-text">{t("workspace.todaysList")}</p>
            <div className="mb-3 flex flex-wrap items-center gap-2">
              <Input
                placeholder={t("workspace.newTaskPlaceholder")}
                value={newTitle}
                onChange={(e) => setNewTitle(e.target.value)}
                className="flex-1 min-w-[160px]"
              />
              <input
                type="date"
                value={newDueDate}
                onChange={(e) => setNewDueDate(e.target.value)}
                className="h-10 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
              />
              <Button type="button" size="sm" disabled={!parsed.success || createTask.isPending} onClick={handleAddTask}>
                {createTask.isPending ? <Loader2 className="size-3.5 animate-spin" /> : <Plus className="size-3.5" />}
                {t("workspace.addTask")}
              </Button>
            </div>

            {todaysTasks.isLoading ? (
              <p className="py-4 text-center text-sm text-text-muted">{t("common.loading")}</p>
            ) : todaysTasks.isError ? (
              <p className="py-4 text-center text-sm text-danger">{t("workspace.loadFailed")}</p>
            ) : (todaysTasks.data?.length ?? 0) === 0 ? (
              <p className="py-4 text-center text-sm text-text-muted">{t("workspace.noTasksToday")}</p>
            ) : (
              <div className="space-y-2">
                {todaysTasks.data!.map((task) => (
                  <TaskItem key={task.id} task={task} onToggle={() => handleToggle(task)} isMutating={setTaskStatus.isPending} />
                ))}
              </div>
            )}
          </Card>

          {(upcomingTasks.data?.length ?? 0) > 0 ? (
            <Card size="default">
              <p className="mb-3 text-sm font-semibold text-text">{t("workspace.upcoming")}</p>
              <div className="space-y-2">
                {upcomingTasks.data!.map((task) => (
                  <TaskItem key={task.id} task={task} onToggle={() => handleToggle(task)} isMutating={setTaskStatus.isPending} />
                ))}
              </div>
            </Card>
          ) : null}

          {(completedTasks.data?.length ?? 0) > 0 ? (
            <Card size="default">
              <p className="mb-3 text-sm font-semibold text-text">{t("workspace.completedToday")}</p>
              <div className="space-y-2">
                {completedTasks.data!.slice(0, 10).map((task) => (
                  <TaskItem key={task.id} task={task} onToggle={() => handleToggle(task)} isMutating={setTaskStatus.isPending} />
                ))}
              </div>
            </Card>
          ) : null}
        </div>

        <div className="space-y-4">
          <Card size="default" className="gap-2">
            <p className="text-sm font-semibold text-text">{t("workspace.confirmationCall.title")}</p>
            <p className="text-xs text-text-muted">{t("workspace.confirmationCall.body")}</p>
            <p className="text-[11px] text-text-muted italic">{t("workspace.confirmationCall.stubNote")}</p>
            <Button
              type="button"
              size="sm"
              variant={confirmed ? "outline" : "accent"}
              disabled={confirmed || logConfirmationCall.isPending}
              onClick={handleConfirmationCall}
              className="mt-1"
            >
              {logConfirmationCall.isPending ? <Loader2 className="size-3.5 animate-spin" /> : confirmed ? <CheckCircle2 className="size-3.5" /> : null}
              {confirmed ? t("workspace.confirmationCall.confirmedLabel") : t("workspace.confirmationCall.markConfirmed")}
            </Button>
          </Card>

          <Card size="default">
            <p className="mb-3 flex items-center gap-1.5 text-sm font-semibold text-text">
              <Bell className="size-4" /> {t("workspace.notificationsFeed")}
            </p>
            {notifications.isLoading ? (
              <p className="py-4 text-center text-sm text-text-muted">{t("common.loading")}</p>
            ) : (notifications.data?.length ?? 0) === 0 ? (
              <p className="py-4 text-center text-sm text-text-muted">{t("workspace.noNotifications")}</p>
            ) : (
              <div className="space-y-2.5">
                {notifications.data!.map((n) => (
                  <div key={n.id} className={cn("rounded-xl border border-border p-2.5", !n.is_read && "border-info/40 bg-info/5")}>
                    <p className="text-xs font-semibold text-text">{n.title}</p>
                    {n.body ? <p className="mt-0.5 text-xs text-text-muted">{n.body}</p> : null}
                    <p className="mt-1 text-[10px] text-text-muted">{new Date(n.created_at).toLocaleString()}</p>
                  </div>
                ))}
              </div>
            )}
          </Card>
        </div>
      </div>
    </div>
  )
}
