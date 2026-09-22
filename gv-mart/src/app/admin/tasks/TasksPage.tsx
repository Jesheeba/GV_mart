import { useMemo, useState, type ReactNode } from "react"
import { useTranslation } from "react-i18next"
import { CalendarDays, CheckCircle2, ClipboardList, List, Loader2, Plus, Repeat, User } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Skeleton } from "@/components/ui/skeleton"
import { useProfile } from "@/hooks/useProfile"
import { useOrgTasks, useSetOrgTaskStatus } from "@/hooks/useTasks"
import type { OrgTask } from "@/services/tasks"
import { PriorityBadge } from "@/app/admin/service/TicketBadges"
import { cn } from "@/lib/utils"
import { AssignTaskDialog } from "./AssignTaskDialog"
import { TaskDetailDialog } from "./TaskDetailDialog"
import { TaskCalendar } from "./TaskCalendar"

type PrimaryFilter = "all" | "open" | "done" | "mine"
type ViewMode = "list" | "calendar"

// Delete is ops-only under RLS (tasks_delete_ops) — mirrored here so the
// button isn't even shown to a role that would just get rejected by the DB.
const CAN_DELETE_ROLES = new Set(["master", "operation_admin"])

export function TasksPage() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id
  const userId = profile?.id

  const { data: tasks, isLoading, isError, refetch } = useOrgTasks(orgId)
  const setStatus = useSetOrgTaskStatus()

  const [filter, setFilter] = useState<PrimaryFilter>("open")
  const [view, setView] = useState<ViewMode>("list")
  const [assignDialogOpen, setAssignDialogOpen] = useState(false)
  const [selectedTask, setSelectedTask] = useState<OrgTask | null>(null)

  const allTasks = useMemo(() => tasks ?? [], [tasks])
  const openCount = allTasks.filter((tsk) => tsk.status !== "done").length
  const doneCount = allTasks.filter((tsk) => tsk.status === "done").length
  const mineCount = allTasks.filter((tsk) => tsk.assignee_id === userId).length

  const visibleTasks = useMemo(() => {
    if (filter === "open") return allTasks.filter((tsk) => tsk.status !== "done")
    if (filter === "done") return allTasks.filter((tsk) => tsk.status === "done")
    if (filter === "mine") return allTasks.filter((tsk) => tsk.assignee_id === userId)
    return allTasks
  }, [allTasks, filter, userId])

  const canDelete = !!profile && CAN_DELETE_ROLES.has(profile.role)

  return (
    <div className="space-y-4 pt-2">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold text-text">{t("nav.tasks")}</h1>
          <p className="text-sm text-text-muted">{t("tasks.subtitle")}</p>
        </div>
        <div className="flex items-center gap-2.5">
          <div className="flex gap-[3px] rounded-full border border-border bg-surface p-1">
            <ViewToggleButton active={view === "list"} onClick={() => setView("list")} icon={List} label={t("tasks.view.list")} />
            <ViewToggleButton active={view === "calendar"} onClick={() => setView("calendar")} icon={CalendarDays} label={t("tasks.view.calendar")} />
          </div>
          <Button onClick={() => setAssignDialogOpen(true)}>
            <Plus className="size-3.5" />
            {t("tasks.assignTask")}
          </Button>
        </div>
      </div>

      <div className="flex flex-wrap items-center gap-2.5">
        <FilterChip active={filter === "open"} onClick={() => setFilter("open")}>
          {t("tasks.filters.open")} · {openCount}
        </FilterChip>
        <FilterChip active={filter === "mine"} onClick={() => setFilter("mine")}>
          {t("tasks.filters.mine")} · {mineCount}
        </FilterChip>
        <FilterChip active={filter === "done"} onClick={() => setFilter("done")}>
          {t("tasks.filters.done")} · {doneCount}
        </FilterChip>
        <FilterChip active={filter === "all"} onClick={() => setFilter("all")}>
          {t("tasks.filters.all")} · {allTasks.length}
        </FilterChip>
      </div>

      {isError ? (
        <Card className="items-center gap-2 py-8 text-center">
          <p className="text-sm text-danger">{t("tasks.loadFailed")}</p>
          <Button type="button" variant="outline" size="sm" onClick={() => refetch()}>
            {t("common.retry")}
          </Button>
        </Card>
      ) : isLoading ? (
        <div className="space-y-2">
          {Array.from({ length: 4 }).map((_, i) => (
            <Skeleton key={i} className="h-16 w-full rounded-xl" />
          ))}
        </div>
      ) : view === "calendar" ? (
        <TaskCalendar tasks={visibleTasks} onTaskClick={setSelectedTask} />
      ) : visibleTasks.length === 0 ? (
        <Card className="items-center gap-2 py-10 text-center">
          <ClipboardList className="size-6 text-text-muted" />
          <p className="text-sm text-text-muted">{t("tasks.empty")}</p>
        </Card>
      ) : (
        <div className="space-y-2">
          {visibleTasks.map((tsk) => (
            <TaskRow
              key={tsk.id}
              task={tsk}
              isMutating={setStatus.isPending && setStatus.variables?.id === tsk.id}
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

function ViewToggleButton({ active, onClick, icon: Icon, label }: { active: boolean; onClick: () => void; icon: typeof List; label: string }) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={active}
      title={label}
      className={cn(
        "flex items-center gap-1.5 rounded-full px-3.5 py-[7px] text-xs font-semibold transition-colors",
        active ? "bg-ink text-white" : "text-text-muted"
      )}
    >
      <Icon className="size-3.5" /> {label}
    </button>
  )
}

function FilterChip({ active, onClick, children }: { active: boolean; onClick: () => void; children: ReactNode }) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={cn(
        "rounded-full border border-border px-[15px] py-2 text-xs font-bold transition-colors",
        active ? "bg-ink text-white" : "bg-surface text-ink"
      )}
    >
      {children}
    </button>
  )
}

function TaskRow({ task, onToggle, isMutating, onOpen }: { task: OrgTask; onToggle: () => void; isMutating: boolean; onOpen: () => void }) {
  const { t } = useTranslation()
  const isDone = task.status === "done"
  const dueLabel = task.due_at
    ? new Date(task.due_at).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" })
    : task.due_date
      ? new Date(`${task.due_date}T00:00:00`).toLocaleDateString(undefined, { dateStyle: "medium" })
      : null

  return (
    <div
      role="button"
      tabIndex={0}
      onClick={onOpen}
      onKeyDown={(e) => {
        if (e.key === "Enter" || e.key === " ") onOpen()
      }}
      className={cn("flex cursor-pointer items-start gap-3 rounded-xl border border-border bg-surface px-4 py-3 hover:bg-surface-alt", isDone && "opacity-60")}
    >
      <button
        type="button"
        onClick={(e) => {
          e.stopPropagation()
          onToggle()
        }}
        disabled={isMutating}
        className={cn(
          "mt-0.5 flex size-5 shrink-0 items-center justify-center rounded-full border transition-colors",
          isDone ? "border-success bg-success text-white" : "border-border text-transparent hover:border-ink"
        )}
        aria-label={t(isDone ? "workspace.markOpen" : "workspace.markDone")}
      >
        {isMutating ? <Loader2 className="size-3 animate-spin" /> : <CheckCircle2 className="size-3.5" />}
      </button>

      <div className="min-w-0 flex-1 space-y-1">
        <div className="flex flex-wrap items-center gap-2">
          <p className={cn("text-sm font-semibold text-text", isDone && "text-text-muted line-through")}>{task.title}</p>
          <PriorityBadge priority={task.priority} />
          {task.is_recurring ? <Repeat className="size-3.5 text-text-muted" aria-label={t("tasks.recurring")} /> : null}
        </div>
        {task.description ? <p className="truncate text-xs text-text-muted">{task.description}</p> : null}
        <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-text-muted">
          <span className="flex items-center gap-1">
            <User className="size-3" />
            {task.assignee?.full_name ?? t("tasks.unknownUser")}
          </span>
          {task.assigner ? <span>{t("tasks.assignedBy", { name: task.assigner.full_name })}</span> : null}
          {dueLabel ? <span>{t("tasks.due", { date: dueLabel })}</span> : null}
        </div>
      </div>
    </div>
  )
}
