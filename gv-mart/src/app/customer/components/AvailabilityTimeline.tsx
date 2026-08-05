import { useTranslation } from "react-i18next"
import { Plus, X } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import type { TimeWindow } from "@/lib/booking-window"
import { largestFreeWindow, isNarrowWindow, isBookableDate } from "@/lib/booking-window"

function toMinutes(hhmm: string): number {
  const [h, m] = hhmm.split(":").map(Number)
  return (h || 0) * 60 + (m || 0)
}

/**
 * Redesigned unavailability picker (2026-08-04 restore) — a full-width
 * green/red availability bar plus freeform start/end time-range rows,
 * replacing the pre-07-31 tap-to-mark-hourly-slot grid. The geometry math
 * (largestFreeWindow/isNarrowWindow/isBookableDate) is unchanged — this
 * component only changes how the customer expresses `windows`.
 */
export function AvailabilityTimeline({
  workStart,
  workEnd,
  windows,
  onChange,
  exemptionWindows,
  narrowThresholdMinutes,
  estimatedMinutes,
}: {
  workStart: string
  workEnd: string
  windows: TimeWindow[]
  onChange: (windows: TimeWindow[]) => void
  exemptionWindows: TimeWindow[]
  narrowThresholdMinutes: number
  estimatedMinutes: number
}) {
  const { t } = useTranslation()
  const dayStart = toMinutes(workStart)
  const dayEnd = toMinutes(workEnd)
  const daySpan = Math.max(dayEnd - dayStart, 1)

  const freeWindow = largestFreeWindow(workStart, workEnd, [...windows, ...exemptionWindows])
  const narrow = isNarrowWindow(freeWindow, narrowThresholdMinutes)
  const bookableToday = isBookableDate(freeWindow, narrowThresholdMinutes, estimatedMinutes)

  function segmentStyle(w: TimeWindow) {
    const s = Math.min(Math.max(toMinutes(w.start), dayStart), dayEnd)
    const e = Math.min(Math.max(toMinutes(w.end), dayStart), dayEnd)
    if (e <= s) return null
    return {
      left: `${((s - dayStart) / daySpan) * 100}%`,
      width: `${((e - s) / daySpan) * 100}%`,
    }
  }

  function updateRow(index: number, patch: Partial<TimeWindow>) {
    onChange(windows.map((w, i) => (i === index ? { ...w, ...patch } : w)))
  }

  function removeRow(index: number) {
    onChange(windows.filter((_, i) => i !== index))
  }

  function addRow() {
    onChange([...windows, { start: workStart, end: workStart }])
  }

  return (
    <div className="space-y-3">
      <div>
        <h3 className="px-1 text-sm font-semibold text-text">{t("customerApp.bookService.unavailability.heading")}</h3>
        <p className="px-1 text-xs text-text-muted">{t("customerApp.bookService.unavailability.helper")}</p>
      </div>

      <div className="relative h-3 w-full overflow-hidden rounded-full bg-success">
        {exemptionWindows.map((w, i) => {
          const style = segmentStyle(w)
          return style ? <div key={`ex-${i}`} className="absolute inset-y-0 bg-danger/60" style={style} /> : null
        })}
        {windows.map((w, i) => {
          const style = segmentStyle(w)
          return style ? <div key={`w-${i}`} className="absolute inset-y-0 bg-danger transition-all" style={style} /> : null
        })}
      </div>
      <div className="flex items-center justify-between px-1 text-[11px] text-text-muted">
        <span>{workStart}</span>
        <span>{workEnd}</span>
      </div>

      <div className="space-y-2 px-1">
        <Label>{t("customerApp.bookService.unavailability.sectionTitle")}</Label>
        {windows.length === 0 ? (
          <p className="text-xs text-text-muted">{t("customerApp.bookService.unavailability.empty")}</p>
        ) : (
          windows.map((w, i) => (
            <div key={i} className="flex items-center gap-2">
              <Input type="time" value={w.start} onChange={(e) => updateRow(i, { start: e.target.value })} aria-label={t("customerApp.bookService.unavailability.startTime")} />
              <span className="text-xs text-text-muted">{t("customerApp.bookService.unavailability.rangeSeparator")}</span>
              <Input type="time" value={w.end} onChange={(e) => updateRow(i, { end: e.target.value })} aria-label={t("customerApp.bookService.unavailability.endTime")} />
              <button
                type="button"
                onClick={() => removeRow(i)}
                aria-label={t("customerApp.bookService.unavailability.removeTimeRange")}
                className="flex size-8 shrink-0 items-center justify-center rounded-lg text-text-muted hover:bg-surface-alt hover:text-danger"
              >
                <X className="size-4" />
              </button>
            </div>
          ))
        )}
        {windows.some((w) => w.end <= w.start) ? (
          <p className="text-xs text-danger">{t("customerApp.bookService.unavailability.invalidRange")}</p>
        ) : null}
        <Button type="button" size="sm" variant="outline" onClick={addRow} className="gap-1.5">
          <Plus className="size-3.5" />
          {t("customerApp.bookService.unavailability.addTimeRange")}
        </Button>
      </div>

      <div className="mx-1 rounded-xl border border-border bg-surface-alt px-3.5 py-2.5 text-sm">
        {freeWindow.availableFrom ? (
          <>
            <p className={narrow ? "font-medium text-warning" : "font-medium text-success"}>
              {t("customerApp.bookService.unavailability.availableWindowPreview", { from: freeWindow.availableFrom, to: freeWindow.availableTo })}
            </p>
            {narrow ? <p className="text-xs text-warning">{t("customerApp.bookService.unavailability.narrowWindowWarning")}</p> : null}
            {!bookableToday ? <p className="text-xs text-warning">{t("customerApp.bookService.unavailability.mayMoveNextDay")}</p> : null}
          </>
        ) : (
          <p className="font-medium text-danger">{t("customerApp.bookService.unavailability.fullyBlockedWarning")}</p>
        )}
      </div>
    </div>
  )
}
