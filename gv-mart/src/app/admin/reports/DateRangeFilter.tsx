import { useTranslation } from "react-i18next"
import { Download } from "lucide-react"
import { Button } from "@/components/ui/button"
import { DatePicker } from "@/components/ui/date-picker"
import { dateRangePresets, dateRangeForPreset, type DateRange } from "@/services/reports"

/** Shared date-range + presets + CSV export bar reused by every Reports tab.
 * F2: quick-select presets (this month / previous month / this year /
 * all-time) sit alongside the existing manual from/to pickers — picking one
 * just computes a range and feeds it through the same onChange the date
 * inputs already use, so callers need no changes. */
export function DateRangeFilter({
  range,
  onChange,
  onExport,
  exportLabel,
}: {
  range: DateRange
  onChange: (range: DateRange) => void
  onExport?: () => void
  exportLabel?: string
}) {
  const { t } = useTranslation()
  return (
    <div className="flex flex-wrap items-end justify-between gap-3">
      <div className="flex flex-wrap items-end gap-2">
        <div className="space-y-1">
          <label className="block text-xs font-medium text-text-muted">{t("reports.filters.from")}</label>
          <DatePicker value={range.from} max={range.to} onChange={(v) => onChange({ ...range, from: v })} className="h-9 w-36" />
        </div>
        <div className="space-y-1">
          <label className="block text-xs font-medium text-text-muted">{t("reports.filters.to")}</label>
          <DatePicker value={range.to} min={range.from} onChange={(v) => onChange({ ...range, to: v })} className="h-9 w-36" />
        </div>
        <div className="flex flex-wrap items-center gap-1.5 pb-0.5">
          {dateRangePresets.map((preset) => (
            <button
              key={preset}
              type="button"
              onClick={() => onChange(dateRangeForPreset(preset))}
              className="rounded-full border border-border bg-surface-alt px-3 py-1.5 text-xs font-medium text-text-muted transition-colors hover:bg-border/50 hover:text-text"
            >
              {t(`reports.filters.presets.${preset}`)}
            </button>
          ))}
        </div>
      </div>
      {onExport ? (
        <Button type="button" variant="outline" size="sm" onClick={onExport}>
          <Download className="size-3.5" />
          {exportLabel ?? t("reports.filters.exportCsv")}
        </Button>
      ) : null}
    </div>
  )
}
