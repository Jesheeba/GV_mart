import { useMemo, useState, type ReactNode } from "react"
import { useTranslation } from "react-i18next"
import { CheckCircle2, ClipboardList, Loader2, Plus, Repeat, User } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { useProfile } from "@/hooks/useProfile"
import { useOrgTasks, useSetOrgTaskStatus } from "@/hooks/useTasks"
import type { OrgTask } from "@/services/tasks"
import { PriorityBadge } from "@/app/admin/service/TicketBadges"
// Reused as-is from the admin Tasks module — neither dialog has any
// admin-shell coupling (they only use useProfile + the shared tasks
// hooks/RLS, which already treat any staff role or technician the same),
// so duplicating ~300 lines of assign/edit form + mutation logic here would
// just be dead-weight drift risk for zero behavioral difference.
import { AssignTaskDialog } from "@/app/admin/tasks/AssignTaskDialog"
import { TaskDetailDialog } from "@/app/admin/tasks/TaskDetailDialog"
import { cn } from "@/lib/utils"
import { canCompleteTask, compareTasksOverdueFirst, isTaskOverdue } from "@/lib/task-rules"
import { getIstNow } from "@/lib/ist"

type PrimaryFilter = "open" | "mine" | "done" | "all"

// Mobile-simplified sibling of admin's TasksPage: same shared data/RLS (a
// technician can see and assign every org task, per Phase 0's fully-open
// hierarchy decision) but a single scrollable list instead of the
// month/week/day/list calendar grid — there's no room for that on a phone
// screen, and "Assigned to me" already covers the common case by default.
export function TasksPage() {
  const { t } = useTranslation()
  const { data: profile, isLoading, isError, refetch } = useProfile()
  const orgId = profile?.org_id
  const userId = profile?.id

  const { data: tasks, isLoading: tasksLoading, isError: tasksError, refetch: refetchTasks } = useOrgTasks(orgId)
  const setStatus = useSetOrgTaskStatus()

  const [filter, setFilter] = useState<PrimaryFilter>("mine")
  const [assignDialogOpen, setAssignDialogOpen] = useState(false)
  const [selectedTask, setSelectedTask] = useState<OrgTask | null>(null)

  const allTasks = useMemo(() => tasks ?? [], [tasks])
  const openCount = allTasks.filter((tsk) => tsk.status !== "done").length
  const mineCount = allTasks.filter((tsk) => tsk.assignee_id === userId).length
  const doneCount = allTasks.filter((tsk) => tsk.status === "done").length

  const today = getIstNow().date
  const visibleTasks = useMemo(() => {
    let rows = allTasks
    if (filter === "open") rows = allTasks.filter((tsk) => tsk.status !== "done")
    else if (filter === "mine") rows = allTasks.filter((tsk) => tsk.assignee_id === userId)
    else if (filter === "done") rows = allTasks.filter((tsk) => tsk.status === "done")
    return [...rows].sort((a, b) => compareTasksOverdueFirst(a, b, today))
  }, [allTasks, filter, userId, today])

  if (isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError || !profile) {
    return <FullPageError message={t("auth.profileLoadError")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  // Technicians never see the delete button — the tasks_delete_ops RLS
  // policy would reject it server-side anyway, so hiding it avoids a dead
  // action rather than duplicating an access decision the DB already makes.
  const canDelete = false

  return (
    <div className="space-y-4 pt-2">
      <div className="flex items-center justify-between gap-3">
        <h1 className="text-xl font-bold text-text">{t("nav.tasks")}</h1>
        <Button type="button" size="sm" onClick={() => setAssignDialogOpen(true)}>
          <Plus className="size-3.5" />
          {t("tasks.assignTask")}
        </Button>
      </div>

      <div className="flex flex-wrap items-center gap-2">
        <FilterChip active={filter === "mine"} onClick={() => setFilter("mine")}>
          {t("tasks.filters.mine")} · {mineCount}
        </FilterChip>
        <FilterChip active={filter === "open"} onClick={() => setFilter("open")}>
          {t("tasks.filters.open")} · {openCount}
        </FilterChip>
        <FilterChip active={filter === "done"} onClick={() => setFilter("done")}>
          {t("tasks.filters.done")} · {doneCount}
        </FilterChip>
        <FilterChip active={filter === "all"} onClick={() => setFilter("all")}>
          {t("tasks.filters.all")} · {allTasks.length}
        </FilterChip>
      </div>

      {tasksError ? (
        <Card className="items-center gap-2 py-8 text-center">
          <p className="text-sm text-danger">{t("tasks.loadFailed")}</p>
          <Button type="button" variant="outline" size="sm" onClick={() => refetchTasks()}>
            {t("common.retry")}
          </Button>
        </Card>
      ) : tasksLoading ? (
        <Card className="items-center py-8 text-center">
          <p className="text-sm text-text-muted">{t("common.loading")}</p>
        </Card>
      ) : visibleTasks.length === 0 ? (
        <Card className="items-center gap-2 py-10 text-center">
          <ClipboardList className="size-6 text-text-muted" />
          <p className="text-sm text-text-muted">{t("tasks.empty")}</p>
        </Card>
      ) : (
        <div className="space-y-2.5">
          {visibleTasks.map((tsk) => (
            <TaskCard
              key={tsk.id}
              task={tsk}
              isMutating={setStatus.isPending && setStatus.variables?.id === tsk.id}
              overdue={isTaskOverdue(tsk, today)}
              canComplete={canCompleteTask(tsk, profile ? { id: profile.id, role: profile.role } : null)}
              onToggle={() => setStatus.mutate({ id: tsk.id, status: tsk.status === "done" ? "open" : "done" })}
              onOpen={() => setSelectedTask(tsk)}
            />
          ))}
        </div>
      )}

      {assignDialogOpen && orgId && userId ? <AssignTaskDialog orgId={orgId} userId={userId} onClose={() => setAssignDialogOpen(false)} /> : null}
      {selectedTask && orgId && userId ? (
        <TaskDetailDialog task={selectedTask} orgId={orgId} userId={userId} canDelete={canDelete} onClose={() => setSelectedTask(null)} />
      ) : null}
    </div>
  )
}

function FilterChip({ active, onClick, children }: { active: boolean; onClick: () => void; children: ReactNode }) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={cn(
        "rounded-full border border-border px-3.5 py-1.5 text-xs font-bold transition-colors",
        active ? "bg-ink text-white" : "bg-surface text-text"
      )}
    >
      {children}
    </button>
  )
}

function TaskCard({
  task,
  onToggle,
  isMutating,
  onOpen,
  overdue,
  canComplete,
}: {
  task: OrgTask
  onToggle: () => void
  isMutating: boolean
  onOpen: () => void
  overdue: boolean
  canComplete: boolean
}) {
  const { t } = useTranslation()
  const isDone = task.status === "done"
  const dueLabel = task.due_at
    ? new Date(task.due_at).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" })
    : task.due_date
      ? new Date(`${task.due_date}T00:00:00`).toLocaleDateString(undefined, { dateStyle: "medium" })
      : null

  return (
    <button type="button" onClick={onOpen} className="block w-full text-left">
      <Card className={cn("flex-row items-start gap-2.5 transition-colors hover:bg-surface-alt", overdue && "border-danger bg-danger/5", isDone && "opacity-60")} data-overdue={overdue ? "true" : undefined}>
        <span
          role="button"
          tabIndex={0}
          onClick={(e) => {
            e.stopPropagation()
            if (canComplete) onToggle()
          }}
          onKeyDown={(e) => {
            if (e.key === "Enter" || e.key === " ") {
              e.stopPropagation()
              if (canComplete) onToggle()
            }
          }}
          aria-disabled={!canComplete}
          title={!canComplete && !isDone ? t("tasks.onlyAssigneeFinishes", { name: task.assignee?.full_name ?? t("tasks.unknownUser") }) : undefined}
          className={cn(
            !canComplete && "cursor-not-allowed opacity-40",
            "mt-0.5 flex size-5 shrink-0 items-center justify-center rounded-full border transition-colors",
            isDone ? "border-success bg-success text-white" : "border-border text-transparent"
          )}
          aria-label={t(isDone ? "workspace.markOpen" : "workspace.markDone")}
        >
          {isMutating ? <Loader2 className="size-3 animate-spin" /> : <CheckCircle2 className="size-3.5" />}
        </span>

        <div className="min-w-0 flex-1 space-y-1">
          <div className="flex flex-wrap items-center gap-1.5">
            <p className={cn("text-sm font-semibold text-text", overdue && "text-danger", isDone && "text-text-muted line-through")}>{task.title}</p>
            {overdue ? <span className="rounded-full bg-danger px-2 py-0.5 text-[10px] font-bold text-white">{t("tasks.overdue")}</span> : null}
            <PriorityBadge priority={task.priority} />
            {task.is_recurring ? <Repeat className="size-3.5 text-text-muted" aria-label={t("tasks.recurring")} /> : null}
          </div>
          {task.description ? <p className="truncate text-xs text-text-muted">{task.description}</p> : null}
          <div className="flex flex-wrap items-center gap-x-2.5 gap-y-1 text-xs text-text-muted">
            <span className="flex items-center gap-1">
              <User className="size-3" />
              {task.assignee?.full_name ?? t("tasks.unknownUser")}
            </span>
            {dueLabel ? <span className={cn(overdue && "font-semibold text-danger")}>{t("tasks.due", { date: dueLabel })}</span> : null}
          </div>
        </div>
      </Card>
    </button>
  )
}
