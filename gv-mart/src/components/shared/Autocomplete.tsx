import { useId, useState, type ReactNode } from "react"
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
  openOnFocus,
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
  /**
   * Show the full suggestion list on focus, before any text is typed —
   * i.e. behave like a real dropdown. Off by default: most callers here
   * back onto a server-side/open-ended search (customers, addresses,
   * products) where an empty query has no meaningful "show everything"
   * result. Only turn this on for a bounded, pre-filtered suggestion set
   * (e.g. complaint types for an already-selected product).
   */
  openOnFocus?: boolean
}) {
  const [open, setOpen] = useState(false)
  const [activeIndex, setActiveIndex] = useState(-1)
  const listboxId = useId()
  const showList = open && (openOnFocus || value.trim().length > 0)
  const activeOptionId = activeIndex >= 0 && activeIndex < suggestions.length ? `${listboxId}-option-${activeIndex}` : undefined

  const selectItem = (item: T) => {
    onSelect(item)
    setOpen(false)
    setActiveIndex(-1)
  }

  return (
    <div className={cn("relative", className)}>
      {icon ? <span className="pointer-events-none absolute left-3.5 top-1/2 -translate-y-1/2 text-text-muted">{icon}</span> : null}
      <Input
        id={id}
        value={value}
        onChange={(e) => {
          onChange(e.target.value)
          setOpen(true)
          setActiveIndex(-1)
        }}
        onFocus={() => setOpen(true)}
        onBlur={() => setTimeout(() => setOpen(false), 150)}
        onKeyDown={(e) => {
          if (!showList || suggestions.length === 0) return
          if (e.key === "ArrowDown") {
            e.preventDefault()
            setActiveIndex((i) => (i + 1) % suggestions.length)
          } else if (e.key === "ArrowUp") {
            e.preventDefault()
            setActiveIndex((i) => (i <= 0 ? suggestions.length - 1 : i - 1))
          } else if (e.key === "Enter") {
            if (activeIndex >= 0 && activeIndex < suggestions.length) {
              e.preventDefault()
              selectItem(suggestions[activeIndex])
            }
          } else if (e.key === "Escape") {
            setOpen(false)
            setActiveIndex(-1)
          }
        }}
        placeholder={placeholder}
        className={cn(icon && "pl-10", inputClassName)}
        autoComplete="off"
        role="combobox"
        aria-expanded={showList}
        aria-controls={listboxId}
        aria-autocomplete="list"
        aria-activedescendant={activeOptionId}
      />
      {showList ? (
        <div id={listboxId} role="listbox" className="absolute z-20 mt-1 max-h-56 w-full overflow-auto rounded-xl border border-border bg-surface shadow-lg">
          {loading ? (
            <div className="flex items-center gap-2 px-3.5 py-2.5 text-sm text-text-muted">
              <Loader2 className="size-3.5 animate-spin" /> …
            </div>
          ) : suggestions.length === 0 ? (
            <div className="px-3.5 py-2.5 text-sm text-text-muted">{emptyMessage}</div>
          ) : (
            suggestions.map((item, index) => (
              <button
                key={getKey(item)}
                id={`${listboxId}-option-${index}`}
                role="option"
                aria-selected={index === activeIndex}
                type="button"
                className={cn(
                  "block w-full px-3.5 py-2.5 text-left text-sm text-text hover:bg-surface-alt",
                  index === activeIndex && "bg-surface-alt"
                )}
                onMouseDown={(e) => e.preventDefault()}
                onMouseEnter={() => setActiveIndex(index)}
                onClick={() => selectItem(item)}
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
