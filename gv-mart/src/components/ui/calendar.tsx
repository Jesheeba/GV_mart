import { useEffect, useMemo, useRef, useState, type KeyboardEvent } from "react"
import { useTranslation } from "react-i18next"
import { ChevronLeft, ChevronRight } from "lucide-react"
import { cn } from "@/lib/utils"

/**
 * Task 4 (2026-07-30) — the one shared calendar component for the whole
 * app, replacing every native `<input type="date">` (see DatePicker, which
 * wraps this in a Popover trigger for drop-in use at existing call sites).
 * Hand-rolled date-grid logic — no date library exists in this project yet
 * (checked node_modules) and a month grid doesn't need one.
 */

function toDateOnly(d: Date) {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate())
}
function isSameDay(a: Date | null | undefined, b: Date | null | undefined) {
  if (!a || !b) return false
  return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate()
}
function startOfMonth(d: Date) {
  return new Date(d.getFullYear(), d.getMonth(), 1)
}
function addMonths(d: Date, n: number) {
  return new Date(d.getFullYear(), d.getMonth() + n, 1)
}
function addDays(d: Date, n: number) {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate() + n)
}

const WEEKDAY_LABELS = ["S", "M", "T", "W", "T", "F", "S"]

export type CalendarProps = {
  value: Date | null
  onSelect: (date: Date) => void
  minDate?: Date
  maxDate?: Date
  /** Extra per-date disable logic beyond min/max (e.g. admin exemption windows). */
  isDateDisabled?: (date: Date) => boolean
  className?: string
}

export function Calendar({ value, onSelect, minDate, maxDate, isDateDisabled, className }: CalendarProps) {
  const { t } = useTranslation()
  const [visibleMonth, setVisibleMonth] = useState(() => startOfMonth(value ?? new Date()))
  const [focusedDate, setFocusedDate] = useState<Date>(() => value ?? new Date())

  // Keep the visible month in sync if the controlled value changes from
  // outside (e.g. a draft restored from localStorage).
  useEffect(() => {
    if (value) setVisibleMonth(startOfMonth(value))
  }, [value])

  // Roving tabindex needs DOM focus to actually follow `focusedDate`, not
  // just the tabIndex attribute — otherwise the popover's own autofocus
  // (Base UI focuses the first focusable descendant, which is the "previous
  // month" button here) leaves keyboard arrows/Enter acting on that button
  // instead of a date cell. Re-running on every `focusedDate` change (mount
  // included) covers both the initial open and keyboard navigation; it does
  // NOT depend on `visibleMonth`, so clicking the prev/next chevrons with a
  // mouse doesn't yank focus away from the button just clicked.
  const dayButtonRefs = useRef(new Map<string, HTMLButtonElement>())
  useEffect(() => {
    dayButtonRefs.current.get(focusedDate.toDateString())?.focus()
  }, [focusedDate])

  const today = toDateOnly(new Date())

  const weeks = useMemo(() => {
    const first = startOfMonth(visibleMonth)
    const startOffset = first.getDay()
    const gridStart = addDays(first, -startOffset)
    const days = Array.from({ length: 42 }, (_, i) => addDays(gridStart, i))
    const result: Date[][] = []
    for (let i = 0; i < 6; i++) result.push(days.slice(i * 7, i * 7 + 7))
    return result
  }, [visibleMonth])

  function isDisabled(d: Date) {
    if (minDate && toDateOnly(d) < toDateOnly(minDate)) return true
    if (maxDate && toDateOnly(d) > toDateOnly(maxDate)) return true
    return !!isDateDisabled?.(d)
  }

  function selectDate(d: Date) {
    if (isDisabled(d)) return
    setFocusedDate(d)
    onSelect(d)
  }

  function handleKeyDown(e: KeyboardEvent<HTMLDivElement>) {
    let delta = 0
    if (e.key === "ArrowLeft") delta = -1
    else if (e.key === "ArrowRight") delta = 1
    else if (e.key === "ArrowUp") delta = -7
    else if (e.key === "ArrowDown") delta = 7
    else if (e.key === "Enter" || e.key === " ") {
      e.preventDefault()
      selectDate(focusedDate)
      return
    } else if (e.key === "PageUp") {
      e.preventDefault()
      setVisibleMonth((m) => addMonths(m, -1))
      return
    } else if (e.key === "PageDown") {
      e.preventDefault()
      setVisibleMonth((m) => addMonths(m, 1))
      return
    } else {
      return
    }
    e.preventDefault()
    const next = addDays(focusedDate, delta)
    setFocusedDate(next)
    if (next.getMonth() !== visibleMonth.getMonth() || next.getFullYear() !== visibleMonth.getFullYear()) {
      setVisibleMonth(startOfMonth(next))
    }
  }

  return (
    <div className={cn("w-full select-none rounded-2xl border border-border bg-surface p-3 shadow-lg", className)}>
      <div className="mb-2 flex items-center justify-between px-0.5">
        <button
          type="button"
          onClick={() => setVisibleMonth((m) => addMonths(m, -1))}
          aria-label={t("common.previousMonth")}
          className="rounded-full p-1.5 text-text-muted transition-colors hover:bg-surface-alt"
        >
          <ChevronLeft className="size-4" />
        </button>
        <span className="text-sm font-semibold text-text">
          {visibleMonth.toLocaleDateString(undefined, { month: "long", year: "numeric" })}
        </span>
        <button
          type="button"
          onClick={() => setVisibleMonth((m) => addMonths(m, 1))}
          aria-label={t("common.nextMonth")}
          className="rounded-full p-1.5 text-text-muted transition-colors hover:bg-surface-alt"
        >
          <ChevronRight className="size-4" />
        </button>
      </div>

      <div role="grid" aria-label={visibleMonth.toLocaleDateString(undefined, { month: "long", year: "numeric" })} onKeyDown={handleKeyDown} className="outline-none">
        <div className="grid grid-cols-7 gap-1 pb-1" role="row">
          {WEEKDAY_LABELS.map((w, i) => (
            <span key={i} role="columnheader" className="flex h-7 items-center justify-center text-[11px] font-medium text-text-muted">
              {w}
            </span>
          ))}
        </div>
        {weeks.map((week, wi) => (
          <div key={wi} role="row" className="grid grid-cols-7 gap-1">
            {week.map((day) => {
              const inMonth = day.getMonth() === visibleMonth.getMonth()
              const isToday = isSameDay(day, today)
              const isSelected = isSameDay(day, value)
              const isFocused = isSameDay(day, focusedDate)
              const disabled = isDisabled(day)
              return (
                <button
                  key={day.toISOString()}
                  ref={(el) => {
                    const key = day.toDateString()
                    if (el) dayButtonRefs.current.set(key, el)
                    else dayButtonRefs.current.delete(key)
                  }}
                  type="button"
                  role="gridcell"
                  tabIndex={isFocused ? 0 : -1}
                  disabled={disabled}
                  onClick={() => selectDate(day)}
                  onFocus={() => setFocusedDate(day)}
                  aria-current={isToday ? "date" : undefined}
                  aria-selected={isSelected}
                  className={cn(
                    "flex h-8 w-8 items-center justify-center rounded-full text-xs font-medium transition-all duration-150",
                    !inMonth && "text-text-muted/40",
                    inMonth && !disabled && !isSelected && "text-text hover:bg-accent-soft",
                    disabled && "cursor-not-allowed text-text-muted/30 line-through",
                    isToday && !isSelected && "border border-accent/60 font-semibold text-accent",
                    isSelected && "bg-accent text-white shadow-sm"
                  )}
                >
                  {day.getDate()}
                </button>
              )
            })}
          </div>
        ))}
      </div>
    </div>
  )
}
