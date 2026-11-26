import { useMemo, useState, type ReactNode } from "react"
import { useTranslation } from "react-i18next"
import { Search } from "lucide-react"
import { Autocomplete } from "@/components/shared/Autocomplete"
import { matchesAllWords } from "@/lib/productSearch"

type SpareOption = { id: string; name: string }

/**
 * Type-to-search spare picker. Replaces native <select>s that listed every
 * spare (170+ rows, all starting "ROS …"): a native select's type-ahead
 * treats Space as "open/confirm", so staff could never type past the first
 * word. Matches every typed word in any order, like the product picker.
 */
export function SparePicker<T extends SpareOption>({
  spares,
  value,
  onChange,
  placeholder,
  renderMeta,
  className,
  inputClassName,
}: {
  spares: T[]
  /** Selected spare id, "" when none. */
  value: string
  onChange: (spareId: string) => void
  placeholder: string
  /** Extra text after the name in each suggestion (price, stock…). */
  renderMeta?: (spare: T) => ReactNode
  className?: string
  inputClassName?: string
}) {
  const { t } = useTranslation()
  const [query, setQuery] = useState("")
  const selected = value ? spares.find((s) => s.id === value) : undefined
  const suggestions = useMemo(() => spares.filter((s) => matchesAllWords(s.name, query)), [spares, query])

  return (
    <Autocomplete
      value={selected ? selected.name : query}
      onChange={(v) => {
        setQuery(v)
        if (value) onChange("")
      }}
      onSelect={(s) => {
        setQuery("")
        onChange(s.id)
      }}
      suggestions={suggestions}
      openOnFocus
      icon={<Search className="size-4" />}
      placeholder={placeholder}
      emptyMessage={t("common.noData")}
      getKey={(s) => s.id}
      getLabel={(s) => (
        <span>
          {s.name}
          {renderMeta ? <span className="text-text-muted"> — {renderMeta(s)}</span> : null}
        </span>
      )}
      className={className}
      inputClassName={inputClassName}
    />
  )
}
