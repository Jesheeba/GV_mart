import { useTranslation } from "react-i18next"
import { cn } from "@/lib/utils"
import { SUPPORTED_LANGUAGES, type SupportedLanguage } from "@/lib/i18n"

const LABELS: Record<SupportedLanguage, string> = {
  en: "EN",
  ta: "த",
}

/** Segmented pill switch — matches the Finexy "segmented black pill nav" pattern. */
export function LanguageToggle() {
  const { i18n, t } = useTranslation()
  const active = (i18n.resolvedLanguage ?? "en") as SupportedLanguage

  return (
    <div
      role="radiogroup"
      aria-label={t("common.language")}
      className="inline-flex items-center gap-0.5 rounded-full bg-surface-alt p-1"
    >
      {SUPPORTED_LANGUAGES.map((lng) => (
        <button
          key={lng}
          type="button"
          role="radio"
          aria-checked={active === lng}
          onClick={() => i18n.changeLanguage(lng)}
          className={cn(
            "min-w-8 rounded-full px-3 py-1 text-xs font-semibold transition-colors",
            active === lng
              ? "bg-ink text-white"
              : "text-text-muted hover:text-text"
          )}
        >
          {LABELS[lng]}
        </button>
      ))}
    </div>
  )
}
