import { useMemo } from "react"
import FullCalendar from "@fullcalendar/react"
import dayGridPlugin from "@fullcalendar/daygrid"
import timeGridPlugin from "@fullcalendar/timegrid"
import listPlugin from "@fullcalendar/list"
import interactionPlugin from "@fullcalendar/interaction"
import type { EventClickArg, EventInput } from "@fullcalendar/core"
import { useTranslation } from "react-i18next"
import type { OrgTask } from "@/services/tasks"
import "./task-calendar.css"

const PRIORITY_EVENT_COLOR: Record<OrgTask["priority"], string> = {
  very_urgent: "var(--danger)",
  urgent: "var(--warning)",
  normal: "var(--success)",
}

// Only tasks with a due_date or due_at can be placed on a calendar grid at
// all — undated tasks stay visible in the List view but are silently
// dropped here rather than pinned to some arbitrary date.
function taskToEvent(task: OrgTask): EventInput | null {
  const start = task.due_at ?? (task.due_date ? `${task.due_date}T00:00:00` : null)
  if (!start) return null
  return {
    id: task.id,
    title: task.is_recurring ? `↻ ${task.title}` : task.title,
    start,
    allDay: !task.due_at,
    backgroundColor: PRIORITY_EVENT_COLOR[task.priority],
    textColor: "#fff",
    classNames: task.status === "done" ? ["gv-event-done"] : [],
  }
}

export function TaskCalendar({ tasks, onTaskClick }: { tasks: OrgTask[]; onTaskClick: (task: OrgTask) => void }) {
  const { i18n } = useTranslation()
  const events = useMemo(() => tasks.map(taskToEvent).filter((e): e is EventInput => e !== null), [tasks])
  const tasksById = useMemo(() => new Map(tasks.map((t) => [t.id, t])), [tasks])

  function handleEventClick(arg: EventClickArg) {
    const task = tasksById.get(arg.event.id)
    if (task) onTaskClick(task)
  }

  return (
    <div className="gv-calendar rounded-card border border-border bg-surface p-3 shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
      <FullCalendar
        plugins={[dayGridPlugin, timeGridPlugin, listPlugin, interactionPlugin]}
        initialView="dayGridMonth"
        headerToolbar={{ left: "prev,next today", center: "title", right: "dayGridMonth,timeGridWeek,timeGridDay,listWeek" }}
        locale={i18n.resolvedLanguage === "ta" ? "ta" : "en"}
        height="auto"
        events={events}
        eventClick={handleEventClick}
        dayMaxEventRows={4}
        firstDay={0}
      />
    </div>
  )
}
