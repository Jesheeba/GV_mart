import { useState } from "react"
import { useTranslation } from "react-i18next"
import { CalendarIcon } from "lucide-react"
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover"
import { Calendar } from "@/components/ui/calendar"
import { cn } from "@/lib/utils"

function parseDateOnly(value: string | undefined | null): Date | null {
  if (!value) return null
  const [y, m, d] = value.split("-").map(Number)
  if (!y || !m || !d) return null
  return new Date(y, m - 1, d)
}

function formatDateOnly(date: Date): string {
  const y = date.getFullYear()
  const m = String(date.getMonth() + 1).padStart(2, "0")
  const d = String(date.getDate()).padStart(2, "0")
  return `${y}-${m}-${d}`
}

/**
 * Task 4 (2026-07-30) — the one shared calendar UI, used everywhere a date
 * needs picking. Deliberately shaped as a drop-in for the native
 * `<input type="date">` it replaces (`value`/`onChange` as "YYYY-MM-DD"
 * strings, `min`/`max` the same) so existing call sites swap with a minimal
 * diff instead of a data-model change.
 */
export function DatePicker({
  id,
  value,
  onChange,
  min,
  max,
  isDateDisabled,
  disabled,
  className,
  "aria-invalid": ariaInvalid,
  "aria-label": ariaLabel,
}: {
  id?: string
  value: string
  onChange: (value: string) => void
  min?: string
  max?: string
  isDateDisabled?: (date: Date) => boolean
  disabled?: boolean
  className?: string
  "aria-invalid"?: boolean
  "aria-label"?: string
}) {
  const { t } = useTranslation()
  const [open, setOpen] = useState(false)
  const selected = parseDateOnly(value)

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger
        id={id}
        type="button"
        disabled={disabled}
        aria-invalid={ariaInvalid}
        aria-label={ariaLabel}
        className={cn(
          "flex h-10 w-full items-center gap-2 rounded-xl border border-border bg-surface px-3 text-left text-sm text-text outline-none transition-colors hover:bg-surface-alt/60 focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30 disabled:cursor-not-allowed disabled:opacity-50 aria-invalid:border-danger",
          className
        )}
      >
        <CalendarIcon className="size-4 shrink-0 text-text-muted" />
        <span className={cn("truncate", !selected && "text-text-muted")}>
          {selected ? selected.toLocaleDateString(undefined, { dateStyle: "medium" }) : t("common.selectDate")}
        </span>
      </PopoverTrigger>
      <PopoverContent align="start" className="w-auto border-0 bg-transparent p-0 shadow-none ring-0">
        <Calendar
          value={selected}
          onSelect={(date) => {
            onChange(formatDateOnly(date))
            setOpen(false)
          }}
          minDate={parseDateOnly(min) ?? undefined}
          maxDate={parseDateOnly(max) ?? undefined}
          isDateDisabled={isDateDisabled}
        />
      </PopoverContent>
    </Popover>
  )
}
