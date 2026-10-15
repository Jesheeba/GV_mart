import { useMemo, useState, type ReactNode } from "react"
import { useTranslation } from "react-i18next"
import { CheckCircle2, Loader2, Plus, RotateCcw } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { DatePicker } from "@/components/ui/date-picker"
import { createTaskSchema } from "@/lib/validation/systemPages"
import { isTaskOverdue } from "@/lib/task-overdue"
import { canToggleTaskStatus } from "@/lib/task-permissions"
import { userColour } from "@/lib/user-colour"
import { getIstNow } from "@/lib/ist"
import { cn } from "@/lib/utils"
import { useAssignTask, useMoveTaskToToday, useSetOrgTaskStatus } from "@/hooks/useTasks"
import type { OrgTask } from "@/services/tasks"
import type { UserRole } from "@/lib/roles"

/**
 * P3: My Day replaces the old standalone Workspace page. It is the default tab of Tasks, for every role including
 * technicians, and reads from the SAME `useOrgTasks` list every other tab uses (narrowed server-side to "mine or
 * assigned-by-me" for non-ops roles since 20261103100000) rather than a second, parallel query — this list IS "my
 * day" plus everyone else's, filtered client-side to `assignee_id === userId`.
 *
 * The old lazy "rollover on read" is gone: a task overdue since before today stays showing its real due date and a
 * "Move to today" button; nothing mutates until that button is pressed.
 */
export function MyDayView({
  tasks,
  orgId,
  userId,
  role,
  onOpen,
}: {
  tasks: OrgTask[]
  orgId: string
  userId: string
  role: UserRole | undefined
  onOpen: (task: OrgTask) => void
}) {
  const { t } = useTranslation()
  const assignTask = useAssignTask()
  const setStatus = useSetOrgTaskStatus()
  const moveToToday = useMoveTaskToToday()

  const [newTitle, setNewTitle] = useState("")
  const [newDueDate, setNewDueDate] = useState(getIstNow().date)
  const parsed = createTaskSchema.safeParse({ title: newTitle, dueDate: newDueDate })

  const mine = useMemo(() => tasks.filter((tsk) => tsk.assignee_id === userId), [tasks, userId])
  const today = getIstNow().date

  const { overdue, dueToday, upcoming, noDate, completed } = useMemo(() => {
    const open = mine.filter((tsk) => tsk.status !== "done")
    const done = mine.filter((tsk) => tsk.status === "done")
    return {
      overdue: open.filter((tsk) => isTaskOverdue(tsk)),
      dueToday: open.filter((tsk) => !isTaskOverdue(tsk) && (tsk.due_at ? tsk.due_at.slice(0, 10) === today : tsk.due_date === today)),
      upcoming: open.filter((tsk) => !isTaskOverdue(tsk) && (tsk.due_at ? tsk.due_at.slice(0, 10) > today : (tsk.due_date ?? "") > today)),
      noDate: open.filter((tsk) => !tsk.due_date && !tsk.due_at),
      completed: [...done].sort((a, b) => new Date(b.updated_at).getTime() - new Date(a.updated_at).getTime()).slice(0, 20),
    }
  }, [mine, today])

  function handleAddTask() {
    if (!parsed.success || !orgId) return
    assignTask.mutate(
      {
        orgId,
        assignedBy: userId,
        assigneeId: userId,
        title: newTitle.trim(),
        description: null,
        priority: "normal",
        dueDate: newDueDate || null,
        dueAt: null,
        isRecurring: false,
      },
      { onSuccess: () => setNewTitle("") }
    )
  }

  function toggle(task: OrgTask) {
    setStatus.mutate({ id: task.id, status: task.status === "done" ? "open" : "done" })
  }

  return (
    <div className="space-y-4">
      <Card size="default" className="px-5">
        <div className="flex flex-wrap items-center gap-2">
          <Input placeholder={t("workspace.newTaskPlaceholder")} value={newTitle} onChange={(e) => setNewTitle(e.target.value)} className="flex-1 min-w-[160px]" />
          <DatePicker value={newDueDate} onChange={setNewDueDate} className="w-40" />
          <Button type="button" size="sm" disabled={!parsed.success || assignTask.isPending} onClick={handleAddTask}>
            {assignTask.isPending ? <Loader2 className="size-3.5 animate-spin" /> : <Plus className="size-3.5" />}
            {t("workspace.addTask")}
          </Button>
        </div>
      </Card>

      {mine.length === 0 ? (
        <Card className="items-center gap-1 py-8 text-center">
          <p className="text-sm text-text-muted">{t("tasks.myDay.empty")}</p>
        </Card>
      ) : null}

      <MyDaySection title={t("tasks.myDay.overdue", { count: overdue.length })} tasks={overdue} emphasize onOpen={onOpen} onToggle={toggle} role={role} userId={userId}>
        {(tsk) => (
          <Button
            type="button"
            size="sm"
            variant="outline"
            disabled={moveToToday.isPending && moveToToday.variables?.id === tsk.id}
            onClick={(e) => {
              e.stopPropagation()
              moveToToday.mutate(tsk)
            }}
          >
            {moveToToday.isPending && moveToToday.variables?.id === tsk.id ? <Loader2 className="size-3 animate-spin" /> : <RotateCcw className="size-3" />}
            {t("tasks.myDay.moveToToday")}
          </Button>
        )}
      </MyDaySection>

      <MyDaySection title={t("tasks.myDay.dueToday", { count: dueToday.length })} tasks={dueToday} onOpen={onOpen} onToggle={toggle} role={role} userId={userId} />
      <MyDaySection title={t("tasks.myDay.upcoming", { count: upcoming.length })} tasks={upcoming} onOpen={onOpen} onToggle={toggle} role={role} userId={userId} collapsible />
      <MyDaySection title={t("tasks.myDay.noDate", { count: noDate.length })} tasks={noDate} onOpen={onOpen} onToggle={toggle} role={role} userId={userId} collapsible />
      <MyDaySection title={t("tasks.myDay.completed", { count: completed.length })} tasks={completed} onOpen={onOpen} onToggle={toggle} role={role} userId={userId} collapsible done />
    </div>
  )
}

function MyDaySection({
  title,
  tasks,
  onOpen,
  onToggle,
  role,
  userId,
  emphasize,
  collapsible,
  done,
  children,
}: {
  title: string
  tasks: OrgTask[]
  onOpen: (task: OrgTask) => void
  onToggle: (task: OrgTask) => void
  role: UserRole | undefined
  userId: string
  emphasize?: boolean
  collapsible?: boolean
  done?: boolean
  children?: (task: OrgTask) => ReactNode
}) {
  const [open, setOpen] = useState(!collapsible)
  if (tasks.length === 0) return null
  return (
    <Card size="default" className={cn("px-5", emphasize && "border-danger/40 bg-danger/5")}>
      <button type="button" className="mb-2 flex w-full items-center justify-between text-left" onClick={() => collapsible && setOpen((v) => !v)}>
        <p className="text-sm font-semibold text-text">{title}</p>
      </button>
      {open ? (
        <div className="space-y-2">
          {tasks.map((tsk) => (
            <MyDayRow
              key={tsk.id}
              task={tsk}
              onOpen={onOpen}
              onToggle={onToggle}
              canToggle={canToggleTaskStatus(tsk, userId, role)}
              done={!!done}
              extra={children?.(tsk)}
            />
          ))}
        </div>
      ) : null}
    </Card>
  )
}

function MyDayRow({
  task,
  onOpen,
  onToggle,
  canToggle,
  done,
  extra,
}: {
  task: OrgTask
  onOpen: (task: OrgTask) => void
  onToggle: (task: OrgTask) => void
  canToggle: boolean
  done: boolean
  extra?: ReactNode
}) {
  const { t } = useTranslation()
  const dot = task.assignee ? userColour(task.assignee.id, task.assignee.colour) : undefined
  return (
    <div
      role="button"
      tabIndex={0}
      onClick={() => onOpen(task)}
      onKeyDown={(e) => {
        if (e.key === "Enter" || e.key === " ") onOpen(task)
      }}
      className="flex cursor-pointer items-center gap-3 rounded-xl border border-border bg-surface px-3 py-2.5 hover:bg-surface-alt"
    >
      <button
        type="button"
        disabled={!canToggle}
        title={canToggle ? undefined : t("tasks.cannotToggle")}
        onClick={(e) => {
          e.stopPropagation()
          if (canToggle) onToggle(task)
        }}
        className={cn(
          "flex size-5 shrink-0 items-center justify-center rounded-full border transition-colors",
          done ? "border-success bg-success text-white" : "border-border text-transparent hover:border-ink",
          !canToggle && "cursor-not-allowed opacity-40"
        )}
        aria-label={t(done ? "workspace.markOpen" : "workspace.markDone")}
      >
        <CheckCircle2 className="size-3.5" />
      </button>
      {dot ? <span className="size-2.5 shrink-0 rounded-full" style={{ backgroundColor: dot }} aria-hidden /> : null}
      <div className="min-w-0 flex-1">
        <p className={cn("truncate text-sm font-medium text-text", done && "text-text-muted line-through")}>{task.title}</p>
        {task.due_date || task.due_at ? <p className="text-xs text-text-muted">{task.due_at ?? task.due_date}</p> : null}
      </div>
      {extra ? (
        <span onClick={(e) => e.stopPropagation()} role="presentation">
          {extra}
        </span>
      ) : null}
    </div>
  )
}
