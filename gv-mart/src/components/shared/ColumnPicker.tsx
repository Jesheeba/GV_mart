import { useTranslation } from "react-i18next"
import { Columns3 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover"

export type ColumnPickerOption<K extends string> = { key: K; label: string }

/** "Columns" dropdown for a report — tick/untick fields from the report's
 * fixed catalog. Pair with useColumnPrefs. */
export function ColumnPicker<K extends string>({
  options,
  visible,
  onToggle,
  onReset,
}: {
  options: ColumnPickerOption<K>[]
  visible: Set<K>
  onToggle: (key: K) => void
  onReset: () => void
}) {
  const { t } = useTranslation()
  return (
    <Popover>
      <PopoverTrigger render={<Button type="button" variant="outline" size="sm" className="print:hidden" />}>
        <Columns3 className="size-4" />
        {t("reports.columns.button")}
      </PopoverTrigger>
      <PopoverContent align="end" className="w-60 space-y-2">
        <p className="text-xs font-semibold text-text">{t("reports.columns.title")}</p>
        <div className="space-y-1.5">
          {options.map((o) => (
            <label key={o.key} className="flex items-center gap-2 text-sm text-text">
              <input type="checkbox" checked={visible.has(o.key)} onChange={() => onToggle(o.key)} className="size-4" />
              <span>{o.label}</span>
            </label>
          ))}
        </div>
        <button type="button" onClick={onReset} className="text-xs text-accent underline">
          {t("reports.columns.reset")}
        </button>
      </PopoverContent>
    </Popover>
  )
}
