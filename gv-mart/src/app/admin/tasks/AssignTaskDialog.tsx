import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { DatePicker } from "@/components/ui/date-picker"
import { useToast } from "@/components/ui/toast-context"
import { useAssignableProfiles, useAssignTask } from "@/hooks/useTasks"
import type { PriorityLevel } from "@/services/tasks"
import { cn } from "@/lib/utils"

const PRIORITIES: PriorityLevel[] = ["normal", "urgent", "very_urgent"]

/**
 * Fully-open assignment per the approved design: the assignee picker lists
 * every staff role + technician in the org, with no hierarchy restriction —
 * a technician can assign to the master here just as validly as the reverse.
 */
export function AssignTaskDialog({ orgId, userId, onClose }: { orgId: string; userId: string; onClose: () => void }) {
  const { t } = useTranslation()
  const { toast } = useToast()
  const { data: assignableProfiles, isLoading: profilesLoading } = useAssignableProfiles(orgId)
  const assignTask = useAssignTask()

  const [title, setTitle] = useState("")
  const [description, setDescription] = useState("")
  const [assigneeId, setAssigneeId] = useState("")
  const [priority, setPriority] = useState<PriorityLevel>("normal")
  const [dueDate, setDueDate] = useState("")
  const [dueTime, setDueTime] = useState("")
  const [isRecurring, setIsRecurring] = useState(false)

  const canSubmit = title.trim().length > 0 && assigneeId.length > 0 && !assignTask.isPending

  function handleSubmit() {
    if (!canSubmit) return
    const dueAt = dueDate && dueTime ? new Date(`${dueDate}T${dueTime}`).toISOString() : null
    assignTask.mutate(
      {
        orgId,
        assignedBy: userId,
        assigneeId,
        title: title.trim(),
        description: description.trim() || null,
        priority,
        dueDate: dueDate || null,
        dueAt,
        isRecurring: isRecurring && !!dueDate,
      },
      {
        onSuccess: () => onClose(),
        onError: () => toast.error(t("common.actionFailed")),
      }
    )
  }

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent>
        <DialogTitle>{t("tasks.assignDialog.title")}</DialogTitle>
        <DialogDescription>{t("tasks.assignDialog.subtitle")}</DialogDescription>

        <div className="space-y-1.5">
          <Label htmlFor="taskTitle">{t("tasks.assignDialog.taskTitle")}</Label>
          <Input id="taskTitle" value={title} onChange={(e) => setTitle(e.target.value)} placeholder={t("tasks.assignDialog.taskTitlePlaceholder")} />
        </div>

        <div className="space-y-1.5">
          <Label htmlFor="taskDescription">{t("tasks.assignDialog.description")}</Label>
          <Input id="taskDescription" value={description} onChange={(e) => setDescription(e.target.value)} placeholder={t("tasks.assignDialog.descriptionPlaceholder")} />
        </div>

        <div className="space-y-1.5">
          <div className="flex items-center justify-between">
            <Label htmlFor="taskAssignee">{t("tasks.assignDialog.assignTo")}</Label>
            <button type="button" onClick={() => setAssigneeId(userId)} className="text-xs font-semibold text-accent hover:underline">
              {t("tasks.assignDialog.assignToMe")}
            </button>
          </div>
          <select
            id="taskAssignee"
            value={assigneeId}
            onChange={(e) => setAssigneeId(e.target.value)}
            disabled={profilesLoading}
            className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none disabled:opacity-50"
          >
            <option value="">{t("tasks.assignDialog.assignToPlaceholder")}</option>
            {(assignableProfiles ?? []).map((p) => (
              <option key={p.id} value={p.id}>
                {p.full_name} · {t(`tasks.roleLabel.${p.role}`)}
              </option>
            ))}
          </select>
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
            <Label htmlFor="taskDueDate">{t("tasks.assignDialog.dueDate")}</Label>
            <DatePicker
              id="taskDueDate"
              value={dueDate}
              onChange={(value) => {
                setDueDate(value)
                if (!value) setIsRecurring(false)
              }}
            />
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="taskDueTime">{t("tasks.assignDialog.dueTime")}</Label>
            <Input id="taskDueTime" type="time" value={dueTime} onChange={(e) => setDueTime(e.target.value)} disabled={!dueDate} />
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

        <div className="flex justify-end gap-2 pt-1">
          <Button type="button" variant="outline" onClick={onClose}>
            {t("common.cancel")}
          </Button>
          <Button type="button" onClick={handleSubmit} disabled={!canSubmit}>
            {t("tasks.assignDialog.submit")}
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  )
}
