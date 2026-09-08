import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2, Plus, Trash2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import {
  useCreateWaCustomTriggerPhrase,
  useDeleteWaCustomTriggerPhrase,
  useUpdateWaCustomTriggerPhrase,
  useWaCustomTriggerPhrases,
} from "@/hooks/useAutomation"
import { useProfile } from "@/hooks/useProfile"
import type { WaTriggerCategory } from "@/services/automation"

// 2026-08-28 (spec section 5.2) — the one manual dependency of a zero-AI
// bot: new phrasings need explicit addition. This screen lets staff add
// one without a code deploy. Deliberately additive, not a replacement for
// the hardcoded baseline (whatsapp-status-answers.ts / whatsapp-
// journeys.ts) — every phrase added here is checked ON TOP OF that
// reviewed baseline, never instead of it. Scoped to the 13 categories the
// DB enum allows — mechanics/greetings/red-flag phrases have no row shape
// here at all, so they can't be extended from this screen even by mistake.
const CATEGORIES: WaTriggerCategory[] = [
  "service_ticket",
  "purchase_history",
  "business_address",
  "business_phone",
  "business_hours",
  "emi",
  "product_availability",
  "menu_buy",
  "menu_service",
  "menu_spares",
  "menu_amc",
  "menu_account",
  "menu_expert",
]

export function PhraseManagerTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: phrases, isLoading } = useWaCustomTriggerPhrases(orgId)
  const createMut = useCreateWaCustomTriggerPhrase(orgId)
  const updateMut = useUpdateWaCustomTriggerPhrase(orgId)
  const deleteMut = useDeleteWaCustomTriggerPhrase(orgId)

  const [category, setCategory] = useState<WaTriggerCategory>("service_ticket")
  const [phrase, setPhrase] = useState("")
  const [error, setError] = useState<string | null>(null)

  async function handleAdd() {
    if (!orgId || !phrase.trim()) return
    setError(null)
    try {
      await createMut.mutateAsync({ org_id: orgId, category, phrase: phrase.trim().toLowerCase(), created_by: profile?.id ?? null })
      setPhrase("")
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    }
  }

  const sorted = [...(phrases ?? [])].sort((a, b) => a.category.localeCompare(b.category))

  return (
    <div className="space-y-3">
      <p className="text-xs text-text-muted">{t("automation.phraseManager.hint")}</p>

      <div className="flex flex-wrap items-center gap-1.5">
        <select
          value={category}
          onChange={(e) => setCategory(e.target.value as WaTriggerCategory)}
          className="h-9 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
        >
          {CATEGORIES.map((c) => (
            <option key={c} value={c}>
              {t(`automation.phraseManager.category.${c}`)}
            </option>
          ))}
        </select>
        <input
          value={phrase}
          onChange={(e) => setPhrase(e.target.value)}
          placeholder={t("automation.phraseManager.phrasePlaceholder")}
          className="h-9 flex-1 min-w-50 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
        />
        <Button size="sm" className="gap-1" disabled={!phrase.trim() || createMut.isPending} onClick={handleAdd}>
          {createMut.isPending ? <Loader2 className="size-3.5 animate-spin" /> : <Plus className="size-3.5" />}
          {t("automation.phraseManager.add")}
        </Button>
      </div>
      {error ? <p className="text-xs text-danger">{error}</p> : null}

      {isLoading ? (
        <p className="py-4 text-center text-sm text-text-muted">{t("common.loading")}</p>
      ) : sorted.length === 0 ? (
        <p className="rounded-xl border border-dashed border-border px-3 py-2.5 text-xs text-text-muted">{t("automation.phraseManager.empty")}</p>
      ) : (
        <ul className="space-y-1">
          {sorted.map((row) => (
            <li key={row.id} className="flex items-center justify-between gap-2 rounded-xl border border-border px-3 py-2">
              <span className="text-sm text-text">
                <span className="rounded-full bg-surface-alt px-2 py-0.5 text-xs font-medium text-text-muted">{t(`automation.phraseManager.category.${row.category}`)}</span>
                <span className={row.is_active ? "ml-2" : "ml-2 text-text-muted line-through"}>{row.phrase}</span>
              </span>
              <div className="flex items-center gap-1">
                <Button
                  size="xs"
                  variant="ghost"
                  disabled={updateMut.isPending}
                  onClick={() => updateMut.mutate({ id: row.id, patch: { is_active: !row.is_active } })}
                >
                  {row.is_active ? t("automation.phraseManager.deactivate") : t("automation.phraseManager.activate")}
                </Button>
                <Button size="icon-xs" variant="ghost" disabled={deleteMut.isPending} onClick={() => deleteMut.mutate(row.id)} title={t("masters.delete")}>
                  <Trash2 className="size-3.5 text-danger" />
                </Button>
              </div>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
