import { useTranslation } from "react-i18next"
import { CheckCircle2, ListPlus, Pencil, RotateCcw, User } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import type { IssueTask, MeetingIssue } from "@/services/huddle"

export type IssueCardProps = {
  issue: MeetingIssue
  names: Map<string, string>
  tasks: IssueTask[]
  /** Technicians (and any read-only context) pass no handlers — no controls render. */
  onEdit?: () => void
  onToggleStatus?: () => void
  onCreateTask?: () => void
  busy?: boolean
}

export function IssueCard({ issue, names, tasks, onEdit, onToggleStatus, onCreateTask, busy }: IssueCardProps) {
  const { t } = useTranslation()
  const solved = issue.status === "solved"
  const owner = issue.owner_id ? names.get(issue.owner_id) : null
  const raisedBy = issue.raised_by ? names.get(issue.raised_by) : null
  const editable = !!(onEdit || onToggleStatus || onCreateTask)

  return (
    <Card className="gap-2.5" data-testid="huddle-issue">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <p className="min-w-0 flex-1 text-sm font-semibold text-text">{issue.description}</p>
        <Badge variant={solved ? "success" : "warning"}>{t(`huddle.status.${issue.status}`)}</Badge>
      </div>

      <p className="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-text-muted">
        <span>{t("huddle.raisedOn", { date: issue.date_raised })}</span>
        {raisedBy && <span>{t("huddle.raisedBy", { name: raisedBy })}</span>}
        {owner && (
          <span className="inline-flex items-center gap-1">
            <User className="size-3" />
            {t("huddle.ownerLabel", { name: owner })}
          </span>
        )}
        {solved && issue.date_solved && <span>{t("huddle.solvedOn", { date: issue.date_solved })}</span>}
      </p>

      {issue.root_cause && (
        <div className="text-sm">
          <span className="font-medium text-text">{t("huddle.rootCause")}: </span>
          <span className="text-text-muted">{issue.root_cause}</span>
        </div>
      )}
      {issue.solution && (
        <div className="text-sm">
          <span className="font-medium text-text">{t("huddle.solution")}: </span>
          <span className="text-text-muted">{issue.solution}</span>
        </div>
      )}

      {tasks.length > 0 && (
        <ul className="space-y-1 rounded-xl bg-surface-alt px-3 py-2 text-xs text-text-muted">
          {tasks.map((tsk) => (
            <li key={tsk.id} className="flex flex-wrap items-center gap-x-2">
              <span className="font-medium text-text">{tsk.title}</span>
              {tsk.assignee && <span>· {tsk.assignee.full_name}</span>}
              {tsk.due_date && <span>· {t("huddle.dueOn", { date: tsk.due_date })}</span>}
              <span>· {tsk.status === "done" ? t("huddle.taskDone") : t("huddle.taskOpen")}</span>
            </li>
          ))}
        </ul>
      )}

      {editable && (
        <div className="flex flex-wrap gap-2 pt-1">
          {onEdit && (
            <Button type="button" size="sm" variant="outline" onClick={onEdit}>
              <Pencil className="size-3.5" />
              {t("huddle.edit")}
            </Button>
          )}
          {onCreateTask && (
            <Button type="button" size="sm" variant="outline" onClick={onCreateTask}>
              <ListPlus className="size-3.5" />
              {t("huddle.createTask")}
            </Button>
          )}
          {onToggleStatus && (
            <Button type="button" size="sm" variant={solved ? "outline" : "default"} disabled={busy} onClick={onToggleStatus}>
              {solved ? <RotateCcw className="size-3.5" /> : <CheckCircle2 className="size-3.5" />}
              {solved ? t("huddle.reopen") : t("huddle.markSolved")}
            </Button>
          )}
        </div>
      )}
    </Card>
  )
}
