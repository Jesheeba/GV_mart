import { useState } from "react"
import { getIstNow } from "@/lib/ist"
import { useTranslation } from "react-i18next"
import { Bell, CheckCircle2, Loader2, Plus, RotateCcw } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { DatePicker } from "@/components/ui/date-picker"
import {
  useCompletedWorkspaceTasks,
  useCreateTask,
  useMarkAppointmentConfirmed,
  useMoveTaskToToday,
  useMyNotificationsFeed,
  useMyWorkspaceTasks,
  useSetTaskStatus,
  useUpcomingAppointmentsForConfirmation,
  useUpcomingWorkspaceTasks,
} from "@/hooks/useWorkspace"
import type { TaskRow, UpcomingAppointmentForConfirmation } from "@/services/workspace"
import { createTaskSchema } from "@/lib/validation/systemPages"
import { cn } from "@/lib/utils"
import { canCompleteTask, completeBlockReason, isTaskOverdue, type ActorLike, type CompleteBlockReason } from "@/lib/task-rules"
import type { UserRole } from "@/lib/roles"

function todayIso() {
  return getIstNow().date
}

// The rollover fields (original_due_date/rolled_count) only ever come back
// populated on rows from listMyWorkspaceTasks (see workspace.ts
// TaskRowWithRollover) — upcoming/completed tasks never roll, so TaskItem
// treats them as optional rather than requiring every caller to supply them.
type MyDayTask = TaskRow & { original_due_date?: string | null; rolled_count?: number }

function MyDayTaskItem({
  task,
  actor,
  onToggle,
  onMoveToToday,
  isMutating,
}: {
  task: MyDayTask
  actor: ActorLike | null | undefined
  onToggle: () => void
  onMoveToToday?: () => void
  isMutating: boolean
}) {
  const { t } = useTranslation()
  const isDone = task.status === "done"
  const rolledCount = task.rolled_count ?? 0
  const isRolled = !isDone && rolledCount > 0
  const overdue = isTaskOverdue(task, todayIso())
  const daysOverdue =
    overdue && task.due_date ? Math.max(1, Math.round((new Date(todayIso()).getTime() - new Date(task.due_date).getTime()) / 86_400_000)) : null
  // A task landing on "my day" is normally the viewer's own, but a reopened/reassigned PO task can still need a master
  // (guard_task_completion, mirrored by canCompleteTask/completeBlockReason) — same reason the admin Tasks list shows.
  const canComplete = isDone || canCompleteTask(task, actor)
  const blockReason: CompleteBlockReason | null = isDone ? null : completeBlockReason(task, actor)

  return (
    <div
      className={cn("flex items-center gap-3 rounded-xl border border-border px-3 py-2.5", isRolled && "border-warning/40 bg-warning/5", overdue && "border-danger bg-danger/5")}
      data-overdue={overdue ? "true" : undefined}
    >
      <button
        type="button"
        onClick={onToggle}
        disabled={isMutating || !canComplete}
        title={!canComplete ? t(`tasks.cannotFinish.${blockReason ?? "not_assignee"}`, { name: t("tasks.unknownUser") }) : undefined}
        className={cn(
          !canComplete && "cursor-not-allowed opacity-40",
          "flex size-5 shrink-0 items-center justify-center rounded-full border transition-colors",
          isDone ? "border-success bg-success text-white" : "border-border text-transparent hover:border-ink"
        )}
        aria-label={t(isDone ? "workspace.markOpen" : "workspace.markDone")}
      >
        <CheckCircle2 className="size-3.5" />
      </button>
      <div className="min-w-0 flex-1">
        <p className={cn("truncate text-sm font-medium text-text", overdue && "text-danger", isDone && "text-text-muted line-through")}>{task.title}</p>
        <div className="flex flex-wrap items-center gap-2 text-xs text-text-muted">
          {task.due_date ? <span className={cn(overdue && "font-semibold text-danger")}>{task.due_date}</span> : null}
          {overdue && daysOverdue ? <span className="font-semibold text-danger">{t("workspace.daysOverdue", { count: daysOverdue })}</span> : null}
          {isRolled ? (
            <span className="flex items-center gap-1 text-warning">
              <RotateCcw className="size-3" />
              {t("workspace.rolledOverCount", { count: rolledCount })}
            </span>
          ) : null}
          {task.source && task.source !== "manual" ? <span>· {task.source}</span> : null}
        </div>
        {blockReason === "po_needs_master" ? <p className="text-xs font-medium text-warning">{t("tasks.cannotFinish.po_needs_master")}</p> : null}
      </div>
      {overdue && onMoveToToday ? (
        <Button type="button" size="sm" variant="outline" disabled={isMutating} onClick={onMoveToToday} className="shrink-0">
          {t("workspace.moveToToday")}
        </Button>
      ) : null}
    </div>
  )
}

/**
 * Agent B item 4: "My Day" is the default tab of the (single) Tasks section — what used to be the standalone
 * /admin/workspace page, now a tab here instead of a second nav entry with an overlapping purpose. Nothing was
 * dropped in the move: quick add-to-myself, today/upcoming/completed-today, the overdue "Move to today" action
 * (P3, no more silent rollover), the appointment confirmation-call queue, and the personal notifications feed.
 * It reads the viewer's own tasks the same way the old Workspace page did (listMyWorkspaceTasks etc.), which
 * already respects the P3 visibility rule (RLS) — not the full org list TasksPage's other tabs show.
 */
export function MyDayView({ orgId, userId, role }: { orgId: string; userId: string; role: UserRole }) {
  const { t } = useTranslation()
  const actor: ActorLike = { id: userId, role }

  const todaysTasks = useMyWorkspaceTasks(orgId, userId)
  const upcomingTasks = useUpcomingWorkspaceTasks(orgId, userId)
  const completedTasks = useCompletedWorkspaceTasks(orgId, userId)
  const notifications = useMyNotificationsFeed(orgId, userId, role)
  const upcomingAppointments = useUpcomingAppointmentsForConfirmation(orgId)

  const createTask = useCreateTask()
  const setTaskStatus = useSetTaskStatus()
  const moveToToday = useMoveTaskToToday()
  const markConfirmed = useMarkAppointmentConfirmed()

  const [newTitle, setNewTitle] = useState("")
  const [newDueDate, setNewDueDate] = useState(todayIso())

  const parsed = createTaskSchema.safeParse({ title: newTitle, dueDate: newDueDate })

  function handleAddTask() {
    if (!parsed.success || !orgId || !userId) return
    createTask.mutate({ orgId, assigneeId: userId, title: newTitle.trim(), dueDate: newDueDate || null }, { onSuccess: () => setNewTitle("") })
  }

  function handleToggle(task: TaskRow) {
    setTaskStatus.mutate({ id: task.id, status: task.status === "done" ? "open" : "done" })
  }

  // confirmation_called_at is set on THAT appointment (not a generic,
  // untargeted log), so once it's confirmed the query's client-side
  // "not yet called" filter drops it off the list on the next refetch.
  function handleConfirm(appointment: UpcomingAppointmentForConfirmation) {
    if (!orgId || !userId) return
    const customerName = appointment.service_tickets?.customers?.name
    const ticketLabel = customerName
      ? `${customerName} — ${appointment.service_tickets?.name_of_complaint ?? t("workspace.confirmationCall.genericLabel")}`
      : t("workspace.confirmationCall.genericLabel")
    markConfirmed.mutate({ orgId, userId, appointmentId: appointment.id, ticketLabel })
  }

  return (
    <div className="grid grid-cols-1 gap-4 lg:grid-cols-3">
      <div className="space-y-4 lg:col-span-2">
        <Card size="default" className="px-5">
          <p className="mb-3 text-sm font-semibold text-text">{t("workspace.todaysList")}</p>
          <div className="mb-3 flex flex-wrap items-center gap-2">
            <Input
              placeholder={t("workspace.newTaskPlaceholder")}
              value={newTitle}
              onChange={(e) => setNewTitle(e.target.value)}
              className="flex-1 min-w-[160px]"
            />
            <DatePicker value={newDueDate} onChange={setNewDueDate} className="w-40" />
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
                <MyDayTaskItem
                  key={task.id}
                  task={task}
                  actor={actor}
                  onToggle={() => handleToggle(task)}
                  onMoveToToday={() => moveToToday.mutate(task)}
                  isMutating={setTaskStatus.isPending || moveToToday.isPending}
                />
              ))}
            </div>
          )}
        </Card>

        {(upcomingTasks.data?.length ?? 0) > 0 ? (
          <Card size="default" className="px-5">
            <p className="mb-3 text-sm font-semibold text-text">{t("workspace.upcoming")}</p>
            <div className="space-y-2">
              {upcomingTasks.data!.map((task) => (
                <MyDayTaskItem key={task.id} task={task} actor={actor} onToggle={() => handleToggle(task)} isMutating={setTaskStatus.isPending} />
              ))}
            </div>
          </Card>
        ) : null}

        {(completedTasks.data?.length ?? 0) > 0 ? (
          <Card size="default" className="px-5">
            <p className="mb-3 text-sm font-semibold text-text">{t("workspace.completedToday")}</p>
            <div className="space-y-2">
              {completedTasks.data!.slice(0, 10).map((task) => (
                <MyDayTaskItem key={task.id} task={task} actor={actor} onToggle={() => handleToggle(task)} isMutating={setTaskStatus.isPending} />
              ))}
            </div>
          </Card>
        ) : null}
      </div>

      <div className="space-y-4">
        <Card size="default" className="gap-2 px-5">
          <p className="text-sm font-semibold text-text">{t("workspace.confirmationCall.title")}</p>
          <p className="text-xs text-text-muted">{t("workspace.confirmationCall.body")}</p>
          <p className="text-[11px] text-text-muted italic">{t("workspace.confirmationCall.stubNote")}</p>

          {upcomingAppointments.isLoading ? (
            <p className="py-3 text-center text-sm text-text-muted">{t("common.loading")}</p>
          ) : upcomingAppointments.isError ? (
            <p className="py-3 text-center text-sm text-danger">{t("workspace.loadFailed")}</p>
          ) : (upcomingAppointments.data?.length ?? 0) === 0 ? (
            <p className="py-3 text-center text-sm text-text-muted">{t("workspace.confirmationCall.none")}</p>
          ) : (
            <div className="mt-1 space-y-2">
              {upcomingAppointments.data!.map((appointment) => {
                const isThisPending = markConfirmed.isPending && markConfirmed.variables?.appointmentId === appointment.id
                return (
                  <div key={appointment.id} className="flex items-center justify-between gap-2 rounded-xl border border-border px-3 py-2">
                    <div className="min-w-0">
                      <p className="truncate text-sm font-medium text-text">
                        {appointment.service_tickets?.customers?.name ?? t("workspace.confirmationCall.unknownCustomer")}
                      </p>
                      <p className="truncate text-xs text-text-muted">
                        {appointment.service_tickets?.name_of_complaint ?? "—"}
                        {appointment.scheduled_at ? ` · ${new Date(appointment.scheduled_at).toLocaleString()}` : ""}
                      </p>
                    </div>
                    <Button
                      type="button"
                      size="sm"
                      variant="accent"
                      disabled={isThisPending}
                      onClick={() => handleConfirm(appointment)}
                      className="shrink-0"
                    >
                      {isThisPending ? <Loader2 className="size-3.5 animate-spin" /> : null}
                      {t("workspace.confirmationCall.markConfirmed")}
                    </Button>
                  </div>
                )
              })}
            </div>
          )}
        </Card>

        <Card size="default" className="px-5">
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
  )
}
