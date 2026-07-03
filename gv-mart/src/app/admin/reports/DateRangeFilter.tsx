import { useTranslation } from "react-i18next"
import { Download } from "lucide-react"
import { Button } from "@/components/ui/button"
import type { DateRange } from "@/services/reports"

/** Shared date-range + CSV export bar reused by every Reports tab. */
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
          <input
            type="date"
            value={range.from}
            max={range.to}
            onChange={(e) => onChange({ ...range, from: e.target.value })}
            className="h-9 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
          />
        </div>
        <div className="space-y-1">
          <label className="block text-xs font-medium text-text-muted">{t("reports.filters.to")}</label>
          <input
            type="date"
            value={range.to}
            min={range.from}
            onChange={(e) => onChange({ ...range, to: e.target.value })}
            className="h-9 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
          />
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
