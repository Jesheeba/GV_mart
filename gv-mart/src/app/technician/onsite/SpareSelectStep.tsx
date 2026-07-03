import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2, Plus, Search, Trash2 } from "lucide-react"
import { Input } from "@/components/ui/input"
import { Card } from "@/components/ui/card"
import { Button } from "@/components/ui/button"
import { useSpareSearch } from "@/hooks/useTechnician"
import { formatCurrency } from "@/lib/sale-calc"

export type SelectedSpare = { spareId: string; name: string; sku: string | null; price: number; qty: number }

export function SpareSelectStep({
  orgId,
  selected,
  onChange,
}: {
  orgId: string | undefined
  selected: SelectedSpare[]
  onChange: (next: SelectedSpare[]) => void
}) {
  const { t } = useTranslation()
  const [term, setTerm] = useState("")
  const results = useSpareSearch(orgId, term)

  function addSpare(spare: { id: string; name: string; sku: string | null; price: number }) {
    if (selected.some((s) => s.spareId === spare.id)) return
    onChange([...selected, { spareId: spare.id, name: spare.name, sku: spare.sku, price: Number(spare.price), qty: 1 }])
    setTerm("")
  }

  function setQty(spareId: string, qty: number) {
    onChange(selected.map((s) => (s.spareId === spareId ? { ...s, qty: Math.max(1, qty) } : s)))
  }

  function remove(spareId: string) {
    onChange(selected.filter((s) => s.spareId !== spareId))
  }

  return (
    <Card className="gap-3">
      <p className="px-1 text-sm font-semibold text-text">{t("technician.onsite.spares.title")}</p>
      <div className="relative">
        <Search className="pointer-events-none absolute left-3.5 top-1/2 size-4 -translate-y-1/2 text-text-muted" />
        <Input value={term} onChange={(e) => setTerm(e.target.value)} placeholder={t("technician.onsite.spares.searchPlaceholder")} className="pl-10" />
      </div>
      {term.trim() ? (
        <div className="max-h-48 space-y-1 overflow-auto rounded-xl border border-border">
          {results.isFetching ? (
            <div className="flex items-center gap-2 px-3.5 py-2.5 text-sm text-text-muted">
              <Loader2 className="size-3.5 animate-spin" /> {t("common.loading")}
            </div>
          ) : !results.data || results.data.length === 0 ? (
            <p className="px-3.5 py-2.5 text-sm text-text-muted">{t("technician.onsite.spares.empty")}</p>
          ) : (
            results.data.map((s) => (
              <button
                key={s.id}
                type="button"
                onClick={() => addSpare({ id: s.id, name: s.name, sku: s.sku, price: Number(s.price) })}
                className="flex w-full items-center justify-between px-3.5 py-2.5 text-left text-sm hover:bg-surface-alt"
              >
                <span>
                  <span className="font-medium text-text">{s.name}</span>{" "}
                  <span className="text-text-muted">{s.sku}</span>
                </span>
                <span className="flex items-center gap-1.5 text-text-muted">
                  {formatCurrency(Number(s.price))}
                  <Plus className="size-3.5" />
                </span>
              </button>
            ))
          )}
        </div>
      ) : null}

      {selected.length === 0 ? (
        <p className="px-1 text-xs text-text-muted">{t("technician.onsite.spares.noneSelected")}</p>
      ) : (
        <div className="divide-y divide-border">
          {selected.map((s) => (
            <div key={s.spareId} className="flex items-center justify-between gap-2 px-1 py-2">
              <div className="min-w-0">
                <p className="truncate text-sm font-medium text-text">{s.name}</p>
                <p className="text-xs text-text-muted">{formatCurrency(s.price)} × {s.qty}</p>
              </div>
              <div className="flex shrink-0 items-center gap-2">
                <Input
                  type="number"
                  min={1}
                  value={s.qty}
                  onChange={(e) => setQty(s.spareId, Number(e.target.value) || 1)}
                  className="h-8 w-16 px-2 text-center"
                />
                <Button type="button" variant="ghost" size="icon-sm" onClick={() => remove(s.spareId)}>
                  <Trash2 className="size-3.5 text-danger" />
                </Button>
              </div>
            </div>
          ))}
        </div>
      )}
    </Card>
  )
}
