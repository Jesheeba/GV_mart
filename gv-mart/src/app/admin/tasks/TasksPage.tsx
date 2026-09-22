import { useMemo, useState, type ReactNode } from "react"
import { useTranslation } from "react-i18next"
import { CheckCircle2, ClipboardList, Loader2, Plus, User } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Skeleton } from "@/components/ui/skeleton"
import { useProfile } from "@/hooks/useProfile"
import { useOrgTasks, useSetOrgTaskStatus } from "@/hooks/useTasks"
import type { OrgTask } from "@/services/tasks"
import { PriorityBadge } from "@/app/admin/service/TicketBadges"
import { cn } from "@/lib/utils"
import { AssignTaskDialog } from "./AssignTaskDialog"

type PrimaryFilter = "all" | "open" | "done" | "mine"

export function TasksPage() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id
  const userId = profile?.id

  const { data: tasks, isLoading, isError, refetch } = useOrgTasks(orgId)
  const setStatus = useSetOrgTaskStatus()

  const [filter, setFilter] = useState<PrimaryFilter>("open")
  const [dialogOpen, setDialogOpen] = useState(false)

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

  return (
    <div className="space-y-4 pt-2">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold text-text">{t("nav.tasks")}</h1>
          <p className="text-sm text-text-muted">{t("tasks.subtitle")}</p>
        </div>
        <Button onClick={() => setDialogOpen(true)}>
          <Plus className="size-3.5" />
          {t("tasks.assignTask")}
        </Button>
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
            />
          ))}
        </div>
      )}

      {dialogOpen && orgId && userId ? <AssignTaskDialog orgId={orgId} userId={userId} onClose={() => setDialogOpen(false)} /> : null}
    </div>
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

function TaskRow({ task, onToggle, isMutating }: { task: OrgTask; onToggle: () => void; isMutating: boolean }) {
  const { t } = useTranslation()
  const isDone = task.status === "done"
  const dueLabel = task.due_at
    ? new Date(task.due_at).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" })
    : task.due_date
      ? new Date(`${task.due_date}T00:00:00`).toLocaleDateString(undefined, { dateStyle: "medium" })
      : null

  return (
    <div className={cn("flex items-start gap-3 rounded-xl border border-border bg-surface px-4 py-3", isDone && "opacity-60")}>
      <button
        type="button"
        onClick={onToggle}
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
