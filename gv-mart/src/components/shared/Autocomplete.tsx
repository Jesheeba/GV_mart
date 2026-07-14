import { useState, type ReactNode } from "react"
import { Loader2 } from "lucide-react"
import { Input } from "@/components/ui/input"
import { cn } from "@/lib/utils"

/**
 * Search-autocomplete — suggests existing matches as you type (design
 * system §8 shared component list). Generic over the suggestion item type.
 */
export function Autocomplete<T>({
  id,
  value,
  onChange,
  suggestions,
  loading,
  placeholder,
  getLabel,
  getKey,
  onSelect,
  emptyMessage,
  icon,
  className,
  inputClassName,
}: {
  id?: string
  value: string
  onChange: (value: string) => void
  suggestions: T[]
  loading?: boolean
  placeholder?: string
  getLabel: (item: T) => ReactNode
  getKey: (item: T) => string
  onSelect: (item: T) => void
  emptyMessage: string
  icon?: ReactNode
  className?: string
  /** Overrides the input's own classes (e.g. a pill-shaped search box) instead of the wrapper's. */
  inputClassName?: string
}) {
  const [open, setOpen] = useState(false)

  return (
    <div className={cn("relative", className)}>
      {icon ? <span className="pointer-events-none absolute left-3.5 top-1/2 -translate-y-1/2 text-text-muted">{icon}</span> : null}
      <Input
        id={id}
        value={value}
        onChange={(e) => {
          onChange(e.target.value)
          setOpen(true)
        }}
        onFocus={() => setOpen(true)}
        onBlur={() => setTimeout(() => setOpen(false), 150)}
        placeholder={placeholder}
        className={cn(icon && "pl-10", inputClassName)}
        autoComplete="off"
      />
      {open && value.trim() ? (
        <div className="absolute z-20 mt-1 max-h-56 w-full overflow-auto rounded-xl border border-border bg-surface shadow-lg">
          {loading ? (
            <div className="flex items-center gap-2 px-3.5 py-2.5 text-sm text-text-muted">
              <Loader2 className="size-3.5 animate-spin" /> …
            </div>
          ) : suggestions.length === 0 ? (
            <div className="px-3.5 py-2.5 text-sm text-text-muted">{emptyMessage}</div>
          ) : (
            suggestions.map((item) => (
              <button
                key={getKey(item)}
                type="button"
                className="block w-full px-3.5 py-2.5 text-left text-sm text-text hover:bg-surface-alt"
                onMouseDown={(e) => e.preventDefault()}
                onClick={() => {
                  onSelect(item)
                  setOpen(false)
                }}
              >
                {getLabel(item)}
              </button>
            ))
          )}
        </div>
      ) : null}
    </div>
  )
}
