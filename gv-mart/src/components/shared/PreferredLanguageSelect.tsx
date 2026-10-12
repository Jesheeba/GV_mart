import { useTranslation } from "react-i18next"

export type PreferredLanguage = "en" | "ta"

/**
 * The customer's preferred language for WhatsApp messages (customers.preferred_language, migration 20261017120000).
 * Empty means English. `i18nPrefix` is "customers.form" (staff screens) or "customerApp.profile" (customer app); both
 * define preferredLanguage, preferredLanguageHint, languageEnglish, languageTamil and languageNotSet.
 */
export function PreferredLanguageSelect({
  value,
  onChange,
  i18nPrefix,
  disabled,
  id,
}: {
  value: PreferredLanguage | null | undefined
  onChange: (next: PreferredLanguage | null) => void
  i18nPrefix: "customers.form" | "customerApp.profile"
  disabled?: boolean
  id?: string
}) {
  const { t } = useTranslation()
  return (
    <div className="space-y-1">
      <label htmlFor={id} className="block text-xs text-text-muted">
        {t(`${i18nPrefix}.preferredLanguage`)}
      </label>
      <select
        id={id}
        value={value ?? ""}
        disabled={disabled}
        onChange={(e) => onChange(e.target.value === "en" || e.target.value === "ta" ? e.target.value : null)}
        className="h-9 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
      >
        <option value="">{t(`${i18nPrefix}.languageNotSet`)}</option>
        <option value="en">{t(`${i18nPrefix}.languageEnglish`)}</option>
        <option value="ta">{t(`${i18nPrefix}.languageTamil`)}</option>
      </select>
      <p className="text-[11px] text-text-muted">{t(`${i18nPrefix}.preferredLanguageHint`)}</p>
    </div>
  )
}
