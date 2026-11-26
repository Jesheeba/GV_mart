import { useTranslation } from "react-i18next"
import { Label } from "@/components/ui/label"
import { cn } from "@/lib/utils"

/**
 * Labelled dropdown for a fixed list of choices — the one control for every either/or data-entry field
 * (owner, 2026-11-26; build-docs/features/choice-dropdowns-not-set.md). The first option is always "Not set"
 * (value ""), and nothing is pre-selected. Whether "Not set" may be saved is the form's validation, not this
 * component's: an optional field saves it as empty, a required one shows `error` and blocks Save.
 */
export function ChoiceSelect<T extends string>({
  id,
  label,
  value,
  options,
  onChange,
  error,
  disabled,
  className,
  labelClassName,
  emptyLabel,
}: {
  id: string
  label: string
  value: T | "" | null | undefined
  options: readonly { value: T; label: string }[]
  onChange: (value: T | "") => void
  /** Already-translated message. */
  error?: string
  disabled?: boolean
  className?: string
  labelClassName?: string
  /** Override "Not set" only where empty has a real meaning ("Any", "Every day"). */
  emptyLabel?: string
}) {
  const { t } = useTranslation()
  return (
    <div className={cn("space-y-1.5", className)}>
      <Label htmlFor={id} className={labelClassName}>
        {label}
      </Label>
      <select
        id={id}
        value={value ?? ""}
        disabled={disabled}
        onChange={(e) => onChange(e.target.value as T | "")}
        aria-invalid={error ? true : undefined}
        aria-describedby={error ? `${id}-error` : undefined}
        className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30 disabled:opacity-60"
      >
        <option value="">{emptyLabel ?? t("common.notSet")}</option>
        {options.map((o) => (
          <option key={o.value} value={o.value}>
            {o.label}
          </option>
        ))}
      </select>
      {error ? (
        <p id={`${id}-error`} role="alert" className="text-xs text-danger">
          {error}
        </p>
      ) : null}
    </div>
  )
}
