import { useTranslation } from "react-i18next"

/** "GST extra / GST included" segmented switch for a single bill or quotation (2026-11-26). */
export function GstModeToggle({ value, onChange }: { value: boolean; onChange: (inclusive: boolean) => void }) {
  const { t } = useTranslation()
  return (
    <div role="radiogroup" aria-label={t("sales.gst.label")} className="inline-flex rounded-full border border-border p-0.5 text-xs">
      {[false, true].map((inclusive) => (
        <button
          key={String(inclusive)}
          type="button"
          role="radio"
          aria-checked={value === inclusive}
          onClick={() => onChange(inclusive)}
          className={`rounded-full px-3 py-1 font-medium transition-colors ${value === inclusive ? "bg-ink text-white" : "text-text-muted"}`}
        >
          {t(inclusive ? "sales.gst.included" : "sales.gst.extra")}
        </button>
      ))}
    </div>
  )
}
