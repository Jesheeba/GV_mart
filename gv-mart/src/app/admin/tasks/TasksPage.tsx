import { useMemo, useState, type ReactNode } from "react"
import { useSearchParams } from "react-router-dom"
import { useTranslation } from "react-i18next"
import { CalendarDays, CheckCircle2, ClipboardList, List, Loader2, Plus, Repeat, Sun, User } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Skeleton } from "@/components/ui/skeleton"
import { useProfile } from "@/hooks/useProfile"
import { useOrgTasks, usePersonMinuteTotals, useSetOrgTaskStatus } from "@/hooks/useTasks"
import type { OrgTask } from "@/services/tasks"
import { PriorityBadge } from "@/app/admin/service/TicketBadges"
import { cn } from "@/lib/utils"
import { formatDate, formatDateTime } from "@/lib/formatDate"
import { type CompleteBlockReason, canCompleteTask, compareTasksOverdueFirst, completeBlockReason, isTaskOverdue } from "@/lib/task-rules"
import { getIstNow } from "@/lib/ist"
import { userColour } from "@/lib/user-colour"
import { AssignTaskDialog } from "./AssignTaskDialog"
import { TaskDetailDialog } from "./TaskDetailDialog"
import { TaskCalendar } from "./TaskCalendar"
import { MyDayTab } from "./MyDayTab"

type PrimaryFilter = "all" | "open" | "done" | "mine"
type ViewMode = "list" | "calendar" | "myDay"

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

  // /admin/workspace (the old "My Workspace" screen) redirects to /admin/tasks?view=myDay — client item 4:
  // one place, not two. The query param only sets the initial tab; switching tabs afterwards doesn't rewrite it.
  const [searchParams] = useSearchParams()
  const initialView: ViewMode = searchParams.get("view") === "myDay" ? "myDay" : "list"
  const [filter, setFilter] = useState<PrimaryFilter>("open")
  const [view, setView] = useState<ViewMode>(initialView)
  const [assignDialogOpen, setAssignDialogOpen] = useState(false)
  const [selectedTask, setSelectedTask] = useState<OrgTask | null>(null)

  const allTasks = useMemo(() => tasks ?? [], [tasks])
  const openCount = allTasks.filter((tsk) => tsk.status !== "done").length
  const doneCount = allTasks.filter((tsk) => tsk.status === "done").length
  const mineCount = allTasks.filter((tsk) => tsk.assignee_id === userId).length

  const today = getIstNow().date
  const visibleTasks = useMemo(() => {
    let rows = allTasks
    if (filter === "open") rows = allTasks.filter((tsk) => tsk.status !== "done")
    else if (filter === "done") rows = allTasks.filter((tsk) => tsk.status === "done")
    else if (filter === "mine") rows = allTasks.filter((tsk) => tsk.assignee_id === userId)
    // overdue first, then by due day, finished last
    return [...rows].sort((a, b) => compareTasksOverdueFirst(a, b, today))
  }, [allTasks, filter, userId, today])

  const canDelete = !!profile && CAN_DELETE_ROLES.has(profile.role)
  const canSeeTeamTime = !!profile && CAN_DELETE_ROLES.has(profile.role)
  const personMinuteTotals = usePersonMinuteTotals(orgId, canSeeTeamTime)
  const personNames = useMemo(() => {
    const m = new Map<string, string>()
    for (const tsk of allTasks) if (tsk.assignee) m.set(tsk.assignee.id, tsk.assignee.full_name)
    return m
  }, [allTasks])
  const teamTimeRows = useMemo(
    () =>
      (personMinuteTotals.data ?? [])
        .filter((r) => r.profile_id && r.total_minutes)
        .map((r) => ({ id: r.profile_id as string, name: personNames.get(r.profile_id as string) ?? t("tasks.unknownUser"), minutes: r.total_minutes as number }))
        .sort((a, b) => b.minutes - a.minutes),
    [personMinuteTotals.data, personNames, t]
  )

  return (
    <div className="space-y-4 pt-2">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold text-text">{t("nav.tasks")}</h1>
          <p className="text-sm text-text-muted">{t("tasks.subtitle")}</p>
        </div>
        <div className="flex items-center gap-2.5">
          <div className="flex gap-[3px] rounded-full border border-border bg-surface p-1">
            <ViewToggleButton active={view === "myDay"} onClick={() => setView("myDay")} icon={Sun} label={t("tasks.view.myDay")} />
            <ViewToggleButton active={view === "list"} onClick={() => setView("list")} icon={List} label={t("tasks.view.list")} />
            <ViewToggleButton active={view === "calendar"} onClick={() => setView("calendar")} icon={CalendarDays} label={t("tasks.view.calendar")} />
          </div>
          <Button onClick={() => setAssignDialogOpen(true)}>
            <Plus className="size-3.5" />
            {t("tasks.assignTask")}
          </Button>
        </div>
      </div>

      {view === "myDay" ? (
        <MyDayTab />
      ) : (
        <>
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

          {canSeeTeamTime && teamTimeRows.length > 0 ? (
            <Card className="gap-2 px-4 py-3">
              <p className="text-xs font-semibold text-text-muted">{t("tasks.teamTime.title")}</p>
              <div className="flex flex-wrap gap-x-4 gap-y-1">
                {teamTimeRows.map((row) => (
                  <p key={row.id} className="text-sm text-text">
                    <span className="font-medium">{row.name}</span>{" "}
                    <span className="text-text-muted">{t("tasks.teamTime.minutes", { count: row.minutes })}</span>
                  </p>
                ))}
              </div>
            </Card>
          ) : null}

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
            <TaskCalendar tasks={visibleTasks} today={today} onTaskClick={setSelectedTask} />
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
                  overdue={isTaskOverdue(tsk, today)}
                  canComplete={canCompleteTask(tsk, profile ? { id: profile.id, role: profile.role } : null)}
                  blockReason={completeBlockReason(tsk, profile ? { id: profile.id, role: profile.role } : null)}
                  onToggle={() => setStatus.mutate({ id: tsk.id, status: tsk.status === "done" ? "open" : "done" })}
                  onOpen={() => setSelectedTask(tsk)}
                />
              ))}
            </div>
          )}
        </>
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

function TaskRow({
  task,
  onToggle,
  isMutating,
  onOpen,
  overdue,
  canComplete,
  blockReason,
}: {
  task: OrgTask
  onToggle: () => void
  isMutating: boolean
  onOpen: () => void
  overdue: boolean
  canComplete: boolean
  blockReason: CompleteBlockReason | null
}) {
  const { t } = useTranslation()
  const isDone = task.status === "done"
  const dueLabel = task.due_at
    ? formatDateTime(task.due_at)
    : task.due_date
      ? formatDate(task.due_date)
      : null

  // A clickable row (whole-row "open detail") used to wrap the per-task
  // toggle button in a `role="button"` div — a focusable element nested
  // inside another focusable element, which axe flags (nested-interactive)
  // and which also makes Tab/Enter behavior ambiguous for keyboard and
  // screen-reader users (ADMIN-002). The toggle and the "open" action are
  // now siblings inside a plain, non-interactive row instead: the toggle
  // keeps its own <button>, and a second <button> covers the rest of the
  // row for opening the task.
  return (
    <div
      className={cn(
        "flex items-start gap-3 rounded-xl border bg-surface px-4 py-3 hover:bg-surface-alt",
        overdue ? "border-danger bg-danger/5" : "border-border",
        isDone && "opacity-60"
      )}
      data-overdue={overdue ? "true" : undefined}
    >
      <button
        type="button"
        onClick={onToggle}
        disabled={isMutating || !canComplete}
        title={!canComplete && !isDone ? t(`tasks.cannotFinish.${blockReason ?? "not_assignee"}`, { name: task.assignee?.full_name ?? t("tasks.unknownUser") }) : undefined}
        className={cn(
          !canComplete && "cursor-not-allowed opacity-40",
          "mt-0.5 flex size-5 shrink-0 items-center justify-center rounded-full border transition-colors",
          isDone ? "border-success bg-success text-white" : "border-border text-transparent hover:border-ink"
        )}
        aria-label={t(isDone ? "workspace.markOpen" : "workspace.markDone")}
      >
        {isMutating ? <Loader2 className="size-3 animate-spin" /> : <CheckCircle2 className="size-3.5" />}
      </button>

      <button type="button" onClick={onOpen} className="min-w-0 flex-1 space-y-1 text-left">
        <div className="flex flex-wrap items-center gap-2">
          <p className={cn("text-sm font-semibold text-text", overdue && "text-danger", isDone && "text-text-muted line-through")}>{task.title}</p>
          {overdue ? <span className="rounded-full bg-danger px-2 py-0.5 text-[10px] font-bold text-white">{t("tasks.overdue")}</span> : null}
          <PriorityBadge priority={task.priority} />
          {task.is_recurring ? <Repeat className="size-3.5 text-text-muted" aria-label={t("tasks.recurring")} /> : null}
        </div>
        {task.description ? <p className="truncate text-xs text-text-muted">{task.description}</p> : null}
        <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-text-muted">
          <span className="flex items-center gap-1">
            <span
              aria-hidden="true"
              className="size-2.5 shrink-0 rounded-full border border-border"
              style={task.assignee ? { backgroundColor: userColour(task.assignee.id, task.assignee.task_color) } : undefined}
            />
            <User className="size-3" />
            {task.assignee?.full_name ?? t("tasks.unknownUser")}
          </span>
          {task.assigner ? <span>{t("tasks.assignedBy", { name: task.assigner.full_name })}</span> : null}
          {dueLabel ? <span className={cn(overdue && "font-semibold text-danger")}>{t("tasks.due", { date: dueLabel })}</span> : null}
        </div>
        {!isDone && blockReason === "po_needs_master" ? <p className="text-xs font-medium text-warning">{t("tasks.cannotFinish.po_needs_master")}</p> : null}
      </button>
    </div>
  )
}
