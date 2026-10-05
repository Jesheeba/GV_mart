import { useTranslation } from "react-i18next"
import { CalendarClock, TriangleAlert } from "lucide-react"
import { Button } from "@/components/ui/button"
import { DatePicker } from "@/components/ui/date-picker"
import { Input } from "@/components/ui/input"
import { cn } from "@/lib/utils"
import {
  DATE_CHIPS,
  TIME_CHIPS,
  formatIstDate,
  formatIstDateTime,
  getIstNow,
  isFutureIst,
  isoDow,
  resolveDateChip,
  suggestWorkingDay,
  toIso,
  type DateChip,
  type NextFollowupValue,
} from "@/lib/lead-followups"

const chipBase = "rounded-full border px-3 py-1.5 text-xs font-semibold transition-colors"
const chipOn = "border-ink bg-ink text-white"
const chipOff = "border-border bg-surface text-text hover:bg-surface-alt"
const chipDisabled = "cursor-not-allowed opacity-40"

/**
 * Step 3 of the Log Outcome sheet (also used by Reschedule and Reopen):
 * quick date chips + time chips (or an exact time), all in IST. A date that
 * falls on a non-working day gets a "use the next working day?" banner, but
 * can be kept (a customer may ask for a Sunday).
 */
export function NextFollowupPicker({
  value,
  onChange,
  workDays,
  workEnd,
  keepNonWorking,
  onKeepNonWorking,
}: {
  value: NextFollowupValue
  onChange: (v: NextFollowupValue) => void
  workDays: number[]
  workEnd: string
  /** The date the user explicitly chose to keep despite it being a non-working day. */
  keepNonWorking: string | null
  onKeepNonWorking: (date: string | null) => void
}) {
  const { t, i18n } = useTranslation()
  const lang = i18n.language
  const now = getIstNow()

  const chipDates = DATE_CHIPS.map((c) => ({ chip: c, resolved: c === "custom" ? null : resolveDateChip(c, now, workEnd) }))
  const activeChip: DateChip | null = !value.date
    ? null
    : (chipDates.find((c) => c.resolved && c.resolved.date === value.date && (c.resolved.time === undefined || c.resolved.time === value.time))?.chip ?? "custom")

  const activeTimeKey = value.exact ? "exact" : (TIME_CHIPS.find((c) => c.time === value.time)?.key ?? null)

  const nonWorkingSuggestion = value.date && keepNonWorking !== value.date ? suggestWorkingDay(value.date, workDays) : null
  const hasWhen = !!value.date && !!value.time
  const inPast = hasWhen && !isFutureIst(value.date!, value.time!)

  function pickChip(chip: DateChip) {
    if (chip === "custom") {
      onChange({ ...value, date: value.date ?? now.date })
      return
    }
    const r = resolveDateChip(chip, now, workEnd)
    if (!r) return
    onChange({ date: r.date, time: r.time ?? value.time ?? "10:00", exact: r.time ? false : value.exact })
  }

  return (
    <div className="space-y-2.5">
      <div className="flex flex-wrap gap-1.5">
        {chipDates.map(({ chip, resolved }) => {
          const unavailable = chip !== "custom" && !resolved
          return (
            <button
              key={chip}
              type="button"
              disabled={unavailable}
              onClick={() => pickChip(chip)}
              aria-pressed={activeChip === chip}
              className={cn(chipBase, activeChip === chip ? chipOn : chipOff, unavailable && chipDisabled)}
            >
              {t(`leads.followup.chip.${chip}`)}
            </button>
          )
        })}
      </div>

      {activeChip === "custom" ? (
        <DatePicker value={value.date ?? ""} min={now.date} onChange={(d) => onChange({ ...value, date: d })} aria-label={t("leads.followup.pickDate")} />
      ) : null}

      <div className="flex flex-wrap items-center gap-1.5">
        {TIME_CHIPS.map((c) => (
          <button
            key={c.key}
            type="button"
            onClick={() => onChange({ ...value, time: c.time, exact: false })}
            aria-pressed={activeTimeKey === c.key}
            className={cn(chipBase, activeTimeKey === c.key ? chipOn : chipOff)}
          >
            {t(`leads.followup.time.${c.key}`)}
          </button>
        ))}
        <button
          type="button"
          onClick={() => onChange({ ...value, exact: true, time: value.exact ? value.time : null })}
          aria-pressed={activeTimeKey === "exact"}
          className={cn(chipBase, activeTimeKey === "exact" ? chipOn : chipOff)}
        >
          {t("leads.followup.time.exact")}
        </button>
        {value.exact ? (
          <Input
            type="time"
            aria-label={t("leads.followup.time.exact")}
            value={value.time ?? ""}
            onChange={(e) => onChange({ ...value, time: e.target.value || null })}
            className="h-8 w-32"
          />
        ) : null}
      </div>

      {nonWorkingSuggestion ? (
        <div className="flex flex-wrap items-center gap-2 rounded-xl border border-warning/40 bg-warning/10 px-3 py-2 text-xs text-text">
          <TriangleAlert className="size-3.5 shrink-0 text-warning" />
          <span className="min-w-0 flex-1">
            {t("leads.followup.nonWorkingDay", { day: t(`leads.followup.weekday.${isoDow(value.date!)}`), suggested: formatIstDate(nonWorkingSuggestion, lang) })}
          </span>
          <Button size="xs" variant="outline" onClick={() => onChange({ ...value, date: nonWorkingSuggestion })}>
            {t("leads.followup.useSuggested")}
          </Button>
          <Button size="xs" variant="ghost" onClick={() => onKeepNonWorking(value.date)}>
            {t("leads.followup.keepDay")}
          </Button>
        </div>
      ) : null}

      <p className={cn("flex items-center gap-1.5 text-xs", inPast ? "text-danger" : "text-text-muted")}>
        <CalendarClock className="size-3.5" />
        {hasWhen
          ? inPast
            ? t("leads.followup.inPast")
            : t("leads.followup.willBeSetFor", { when: formatIstDateTime(toIso(value.date!, value.time!), lang) })
          : t("leads.followup.pickWhen")}
      </p>
    </div>
  )
}

