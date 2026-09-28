import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2, Plus, Search, Trash2 } from "lucide-react"
import { Input } from "@/components/ui/input"
import { Card } from "@/components/ui/card"
import { Button } from "@/components/ui/button"
import { useProductSearch } from "@/hooks/useTechnician"

// Installation Tracking + Incentive (2026-09-25) — logs a SPECIFIC product
// as newly installed on this visit, independent of the ticket's own type
// (a technician can install a replacement unit during any visit, not only
// on ticket_type='installation' tickets — see build report). Mirrors
// SpareSelectStep's local-state-until-invoice pattern, but sources from
// `products` (what gets installed), not `spares` (what gets consumed as
// repair parts) — these are deliberately separate lists/concepts.
export type SelectedInstallation = { productId: string; name: string; qty: number }

export function InstallationSelectStep({
  orgId,
  selected,
  onChange,
}: {
  orgId: string | undefined
  selected: SelectedInstallation[]
  onChange: (next: SelectedInstallation[]) => void
}) {
  const { t } = useTranslation()
  const [term, setTerm] = useState("")
  const results = useProductSearch(orgId, term)

  function addProduct(product: { id: string; name: string }) {
    if (selected.some((s) => s.productId === product.id)) return
    onChange([...selected, { productId: product.id, name: product.name, qty: 1 }])
    setTerm("")
  }

  function setQty(productId: string, qty: number) {
    onChange(selected.map((s) => (s.productId === productId ? { ...s, qty: Math.max(1, qty) } : s)))
  }

  function remove(productId: string) {
    onChange(selected.filter((s) => s.productId !== productId))
  }

  return (
    <Card className="gap-3">
      <p className="px-1 text-sm font-semibold text-text">{t("technician.onsite.installations.title")}</p>
      <div className="relative">
        <Search className="pointer-events-none absolute left-3.5 top-1/2 size-4 -translate-y-1/2 text-text-muted" />
        <Input
          value={term}
          onChange={(e) => setTerm(e.target.value)}
          placeholder={t("technician.onsite.installations.searchPlaceholder")}
          className="pl-10"
        />
      </div>

      {term.trim() ? (
        <div className="max-h-48 space-y-1 overflow-auto rounded-xl border border-border">
          {results.isFetching ? (
            <div className="flex items-center gap-2 px-3.5 py-2.5 text-sm text-text-muted">
              <Loader2 className="size-3.5 animate-spin" /> {t("common.loading")}
            </div>
          ) : !results.data || results.data.length === 0 ? (
            <p className="px-3.5 py-2.5 text-sm text-text-muted">{t("technician.onsite.installations.empty")}</p>
          ) : (
            results.data.map((p) => (
              <button
                key={p.id}
                type="button"
                onClick={() => addProduct({ id: p.id, name: p.name })}
                className="flex w-full items-center justify-between px-3.5 py-2.5 text-left text-sm hover:bg-surface-alt"
              >
                <span className="font-medium text-text">{p.name}</span>
                <Plus className="size-3.5 text-text-muted" />
              </button>
            ))
          )}
        </div>
      ) : null}

      {selected.length === 0 ? (
        <p className="px-1 text-xs text-text-muted">{t("technician.onsite.installations.noneSelected")}</p>
      ) : (
        <div className="divide-y divide-border">
          {selected.map((s) => (
            <div key={s.productId} className="flex items-center justify-between gap-2 px-1 py-2">
              <p className="min-w-0 truncate text-sm font-medium text-text">{s.name}</p>
              <div className="flex shrink-0 items-center gap-2">
                <Input
                  type="number"
                  min={1}
                  value={s.qty}
                  onChange={(e) => setQty(s.productId, Number(e.target.value) || 1)}
                  className="h-8 w-16 px-2 text-center"
                />
                <Button type="button" variant="ghost" size="icon-sm" onClick={() => remove(s.productId)}>
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
