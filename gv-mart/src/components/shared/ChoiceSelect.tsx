import { useTranslation } from "react-i18next"
import { Label } from "@/components/ui/label"
import { cn } from "@/lib/utils"

/**
 * Labelled dropdown for a fixed list of choices (owner, 2026-11-26: either/or fields are dropdowns).
 * Nothing is pre-selected: a required field starts on a disabled "Select…", an optional one on
 * "Not set", which saves as "". The error text is shown under it and linked for screen readers.
 */
export function ChoiceSelect<T extends string>({
  id,
  label,
  value,
  options,
  onChange,
  error,
  optional = false,
  className,
  labelClassName,
}: {
  id: string
  label: string
  value: T | "" | null | undefined
  options: readonly { value: T; label: string }[]
  onChange: (value: T | "") => void
  /** Already-translated message. */
  error?: string
  optional?: boolean
  className?: string
  labelClassName?: string
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
        onChange={(e) => onChange(e.target.value as T | "")}
        aria-invalid={error ? true : undefined}
        aria-describedby={error ? `${id}-error` : undefined}
        className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"
      >
        <option value="" disabled={!optional}>
          {t(optional ? "common.notSet" : "common.selectPlaceholder")}
        </option>
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
