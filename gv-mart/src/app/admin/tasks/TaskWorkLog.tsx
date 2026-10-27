import { useState } from "react"
import { useTranslation } from "react-i18next"
import type { TFunction } from "i18next"
import { Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { DatePicker } from "@/components/ui/date-picker"
import { useAddTaskLog, useTaskLogs } from "@/hooks/useTaskLogs"
import type { TaskLog } from "@/services/taskLogs"

function describeEntry(log: TaskLog, t: TFunction): string {
  const who = log.actor_name ?? t("tasks.log.system")
  if (log.kind === "reassigned") {
    return t("tasks.log.reassigned", { who, from: log.from_name ?? t("tasks.log.nobody"), to: log.to_name ?? t("tasks.log.nobody") })
  }
  if (log.kind === "status") {
    return t("tasks.log.status", { who, from: t(`tasks.log.statusValue.${log.from_value ?? "open"}`), to: t(`tasks.log.statusValue.${log.to_value ?? "open"}`) })
  }
  if (log.kind === "due_moved") {
    return t("tasks.log.dueMoved", { who, from: log.from_value ?? "-", to: log.to_value ?? "-" })
  }
  return who
}

/** Work log of one task: notes people wrote plus the automatic reassignment / status / due-date entries. Append-only. */
export function TaskWorkLog({ orgId, taskId }: { orgId: string; taskId: string }) {
  const { t } = useTranslation()
  const logs = useTaskLogs(taskId)
  const add = useAddTaskLog()
  const [note, setNote] = useState("")
  const [minutes, setMinutes] = useState("")
  const [nextDate, setNextDate] = useState("")
  const [nextNote, setNextNote] = useState("")

  const minutesNum = minutes.trim() === "" ? null : Number(minutes)
  const minutesOk = minutesNum === null || (Number.isInteger(minutesNum) && minutesNum >= 0 && minutesNum <= 1440)
  const hasContent = note.trim() !== "" || minutesNum !== null || nextDate !== "" || nextNote.trim() !== ""

  function submit() {
    if (!hasContent || !minutesOk) return
    add.mutate(
      {
        orgId,
        taskId,
        note: note.trim() || null,
        minutesSpent: minutesNum,
        nextPlannedDate: nextDate || null,
        nextPlannedNote: nextNote.trim() || null,
      },
      {
        onSuccess: () => {
          setNote("")
          setMinutes("")
          setNextDate("")
          setNextNote("")
        },
      }
    )
  }

  return (
    <div className="space-y-2 border-t border-border pt-3">
      <p className="text-sm font-semibold text-text">{t("tasks.log.title")}</p>
      {logs.isLoading ? (
        <p className="text-xs text-text-muted">{t("common.loading")}</p>
      ) : logs.isError ? (
        <p className="text-xs text-danger">{t("tasks.log.loadFailed")}</p>
      ) : (logs.data?.length ?? 0) === 0 ? (
        <p className="text-xs text-text-muted">{t("tasks.log.empty")}</p>
      ) : (
        <ul className="max-h-48 space-y-1.5 overflow-y-auto">
          {logs.data!.map((log) => (
            <li key={log.id} className="rounded-lg border border-border px-2.5 py-1.5 text-xs">
              {log.kind === "note" ? (
                <>
                  <p className="font-medium text-text">
                    {log.actor_name ?? t("tasks.log.system")}
                    {log.minutes_spent != null ? <span className="font-normal text-text-muted"> · {t("tasks.log.minutes", { count: log.minutes_spent })}</span> : null}
                  </p>
                  {log.note ? <p className="text-text">{log.note}</p> : null}
                  {log.next_planned_date || log.next_planned_note ? (
                    <p className="text-text-muted">
                      {t("tasks.log.next")}: {log.next_planned_date ?? ""} {log.next_planned_note ?? ""}
                    </p>
                  ) : null}
                </>
              ) : (
                <p className="text-text-muted">{describeEntry(log, t)}</p>
              )}
              <p className="mt-0.5 text-[10px] text-text-muted">{new Date(log.created_at).toLocaleString()}</p>
            </li>
          ))}
        </ul>
      )}

      <div className="space-y-2 rounded-xl bg-surface-alt p-2.5">
        <Input aria-label={t("tasks.log.note")} placeholder={t("tasks.log.notePlaceholder")} value={note} onChange={(e) => setNote(e.target.value)} maxLength={2000} />
        <div className="grid grid-cols-1 gap-2 sm:grid-cols-3">
          <div className="space-y-1">
            <Label htmlFor={`logMinutes-${taskId}`} className="text-xs">{t("tasks.log.minutesSpent")}</Label>
            <Input id={`logMinutes-${taskId}`} inputMode="numeric" value={minutes} onChange={(e) => setMinutes(e.target.value.replace(/[^0-9]/g, ""))} />
          </div>
          <div className="space-y-1">
            <Label htmlFor={`logNextDate-${taskId}`} className="text-xs">{t("tasks.log.nextDate")}</Label>
            <DatePicker id={`logNextDate-${taskId}`} value={nextDate} onChange={setNextDate} />
          </div>
          <div className="space-y-1">
            <Label htmlFor={`logNextNote-${taskId}`} className="text-xs">{t("tasks.log.nextNote")}</Label>
            <Input id={`logNextNote-${taskId}`} value={nextNote} onChange={(e) => setNextNote(e.target.value)} maxLength={500} />
          </div>
        </div>
        {!minutesOk ? <p className="text-xs text-danger">{t("tasks.log.minutesInvalid")}</p> : null}
        <div className="flex justify-end">
          <Button type="button" size="sm" disabled={!hasContent || !minutesOk || add.isPending} onClick={submit}>
            {add.isPending ? <Loader2 className="size-3.5 animate-spin" /> : null}
            {t("tasks.log.add")}
          </Button>
        </div>
      </div>
    </div>
  )
}
