import { useTranslation } from "react-i18next"
import { Download } from "lucide-react"
import { Button } from "@/components/ui/button"
import { SegButton } from "@/components/shared/SegButton"
import type { PeriodMode, PeriodValue } from "@/services/reports"
import { DateRangeFilter } from "./DateRangeFilter"

const MODES: PeriodMode[] = ["month", "year", "range"]

/** Shared Month/Year/Custom period picker — the default entry point for
 * every dashboard/report screen's date filter (see services/reports.ts's
 * PeriodValue doc comment for why this composes DateRangeFilter for Custom
 * mode instead of extending it in place). Fully controlled: callers own
 * `value: PeriodValue` and call `periodToRange(value)` once to feed their
 * existing report hooks — no query/hook signature needs to change. */
export function PeriodFilter({
  value,
  onChange,
  onExport,
  exportLabel,
}: {
  value: PeriodValue
  onChange: (value: PeriodValue) => void
  onExport?: () => void
  exportLabel?: string
}) {
  const { t } = useTranslation()
  const now = new Date()
  const currentYear = now.getFullYear()
  const years = Array.from({ length: 6 }, (_, i) => currentYear - i)

  function switchMode(mode: PeriodMode) {
    if (mode === value.mode) return
    if (mode === "month") onChange({ mode: "month", month: now.toISOString().slice(0, 7) })
    else if (mode === "year") onChange({ mode: "year", year: currentYear })
    else onChange({ mode: "range", range: { from: now.toISOString().slice(0, 10), to: now.toISOString().slice(0, 10) } })
  }

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div className="flex flex-wrap items-end gap-2.5">
          <div className="flex gap-[3px] rounded-full border border-border bg-surface-alt p-1">
            {MODES.map((mode) => (
              <SegButton key={mode} active={value.mode === mode} onClick={() => switchMode(mode)}>
                {t(`reports.filters.mode.${mode}`)}
              </SegButton>
            ))}
          </div>

          {value.mode === "month" ? (
            <div className="space-y-1">
              <label className="block text-xs font-medium text-text-muted">{t("reports.filters.mode.month")}</label>
              <input
                type="month"
                value={value.month}
                onChange={(e) => onChange({ mode: "month", month: e.target.value })}
                className="h-9 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
              />
            </div>
          ) : null}

          {value.mode === "year" ? (
            <div className="space-y-1">
              <label className="block text-xs font-medium text-text-muted">{t("reports.filters.mode.year")}</label>
              <select
                value={value.year}
                onChange={(e) => onChange({ mode: "year", year: Number(e.target.value) })}
                className="h-9 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
              >
                {years.map((y) => (
                  <option key={y} value={y}>
                    {y}
                  </option>
                ))}
              </select>
            </div>
          ) : null}
        </div>

        {onExport && value.mode !== "range" ? (
          <Button type="button" variant="outline" size="sm" onClick={onExport}>
            <Download className="size-3.5" />
            {exportLabel ?? t("reports.filters.exportCsv")}
          </Button>
        ) : null}
      </div>

      {value.mode === "range" ? (
        <DateRangeFilter
          range={value.range}
          onChange={(range) => onChange({ mode: "range", range })}
          onExport={onExport}
          exportLabel={exportLabel}
        />
      ) : null}
    </div>
  )
}
