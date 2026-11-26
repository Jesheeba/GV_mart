import { useTranslation } from "react-i18next"
import type { GstMode } from "@/lib/sale-calc"

const MODES: readonly GstMode[] = ["extra", "included", "none"]

/** Per-bill GST switch: GST extra / GST included / No GST (2026-11-26; no-gst-bill adds "No GST"). */
export function GstModeToggle({ value, onChange }: { value: GstMode; onChange: (mode: GstMode) => void }) {
  const { t } = useTranslation()
  return (
    <div role="radiogroup" aria-label={t("sales.gst.label")} className="inline-flex rounded-full border border-border p-0.5 text-xs">
      {MODES.map((mode) => (
        <button
          key={mode}
          type="button"
          role="radio"
          aria-checked={value === mode}
          onClick={() => onChange(mode)}
          className={`rounded-full px-3 py-1 font-medium transition-colors ${value === mode ? "bg-ink text-white" : "text-text-muted"}`}
        >
          {t(`sales.gst.${mode}`)}
        </button>
      ))}
    </div>
  )
}
