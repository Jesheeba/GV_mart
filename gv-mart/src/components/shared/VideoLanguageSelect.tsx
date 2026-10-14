import { useTranslation } from "react-i18next"
import { toVideoLanguage, VIDEO_LANGUAGES, type VideoLanguage } from "@/lib/videoLanguage"

/** Language picker for a video row. `null` = any language (the column is nullable and NULL keeps old rows working). */
export function VideoLanguageSelect({
  value,
  onChange,
  className = "h-9 rounded-xl border border-border bg-surface px-2 text-sm text-text outline-none",
  disabled,
}: {
  value: string | null
  onChange: (next: VideoLanguage | null) => void
  className?: string
  disabled?: boolean
}) {
  const { t } = useTranslation()
  return (
    <select
      value={value ?? ""}
      disabled={disabled}
      aria-label={t("masters.videoLanguage.label")}
      onChange={(e) => onChange(toVideoLanguage(e.target.value))}
      className={className}
    >
      <option value="">{t("masters.videoLanguage.any")}</option>
      {VIDEO_LANGUAGES.map((l) => (
        <option key={l} value={l}>
          {t(`masters.videoLanguage.${l}`)}
        </option>
      ))}
    </select>
  )
}
