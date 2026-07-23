import { useEffect, useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2 } from "lucide-react"
import { EntityCrudTable, type CrudFieldDef } from "@/components/shared/EntityCrudTable"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { amcPlansHooks, giftsHooks, sparesHooks, useAmcPlanCoveredSpares, useSetAmcPlanCoveredSpares } from "@/hooks/useMasters"
import type { AmcPlanRow } from "@/services/masters"
import { useProfile } from "@/hooks/useProfile"

const NO_GIFT = "__none__"

/** inclusions is jsonb — represented in the form as a comma-separated list. */
function inclusionsToText(inclusions: unknown): string {
  return Array.isArray(inclusions) ? inclusions.filter((x) => typeof x === "string").join(", ") : ""
}
function textToInclusions(text: string): string[] {
  return text
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean)
}

/** Fix 1: price_per_year is now the source of truth for sale-time pricing.
 * When the admin leaves one of price/price_per_year blank, derive it from
 * the other so the two never silently disagree. */
function resolvePricing(v: Record<string, string>) {
  const years = Number(v.years) || 1
  const priceRaw = v.price?.trim()
  const perYearRaw = v.price_per_year?.trim()
  const pricePerYear = perYearRaw ? Number(perYearRaw) || 0 : priceRaw ? Math.round((Number(priceRaw) / years) * 100) / 100 : 0
  const price = priceRaw ? Number(priceRaw) || 0 : Math.round(pricePerYear * years * 100) / 100
  return { price, pricePerYear }
}

function displayPricePerYear(r: AmcPlanRow): number {
  return r.price_per_year ?? Math.round((r.price / Math.max(r.years, 1)) * 100) / 100
}

export function AmcPlansTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: gifts } = giftsHooks.useList(orgId)
  const { data: rows, isLoading, isError, refetch } = amcPlansHooks.useList(orgId)
  const createMut = amcPlansHooks.useCreate()
  const updateMut = amcPlansHooks.useUpdate()
  const deleteMut = amcPlansHooks.useDelete()

  const [managingPlanId, setManagingPlanId] = useState<string | null>(null)
  const managingPlan = (rows ?? []).find((r) => r.id === managingPlanId) ?? null

  const giftOptions = useMemo(
    () => [{ value: NO_GIFT, label: t("masters.amcPlans.noGift") }, ...(gifts ?? []).map((g) => ({ value: g.id, label: g.name }))],
    [gifts, t]
  )

  const fields: CrudFieldDef[] = [
    { key: "name", label: t("masters.amcPlans.name"), type: "text", placeholder: t("masters.amcPlans.namePlaceholder") },
    { key: "years", label: t("masters.amcPlans.years"), type: "number", step: "1" },
    { key: "price_per_year", label: t("masters.amcPlans.pricePerYear"), type: "number", step: "0.01" },
    { key: "price", label: t("masters.amcPlans.price"), type: "number", step: "0.01" },
    { key: "visits_per_year", label: t("masters.amcPlans.visitsPerYear"), type: "number", step: "1" },
    { key: "gift_id", label: t("masters.amcPlans.gift"), type: "select", options: giftOptions },
    { key: "inclusions", label: t("masters.amcPlans.inclusions"), type: "text", placeholder: t("masters.amcPlans.inclusionsPlaceholder") },
  ]

  return (
    <div className="space-y-4">
      <EntityCrudTable<AmcPlanRow>
        fields={fields}
        rows={rows ?? []}
        getId={(r) => r.id}
        loading={isLoading}
        error={isError ? t("masters.loadFailed") : null}
        onRetry={() => refetch()}
        isMutating={createMut.isPending || updateMut.isPending}
        addLabel={t("masters.amcPlans.add")}
        emptyMessage={t("masters.amcPlans.empty")}
        toFormValues={(r) => ({
          name: r.name,
          years: String(r.years),
          price_per_year: r.price_per_year != null ? String(r.price_per_year) : "",
          price: String(r.price),
          visits_per_year: String(r.visits_per_year),
          gift_id: r.gift_id ?? NO_GIFT,
          inclusions: inclusionsToText(r.inclusions),
        })}
        columns={[
          { key: "name", header: t("masters.amcPlans.name"), render: (r) => <span className="font-medium text-text">{r.name}</span> },
          { key: "years", header: t("masters.amcPlans.years"), render: (r) => r.years },
          { key: "pricePerYear", header: t("masters.amcPlans.pricePerYear"), render: (r) => `₹${displayPricePerYear(r)}` },
          { key: "price", header: t("masters.amcPlans.price"), render: (r) => `₹${r.price}` },
          { key: "visits", header: t("masters.amcPlans.visitsPerYear"), render: (r) => r.visits_per_year },
          {
            key: "coveredSpares",
            header: t("masters.amcPlans.coveredSpares"),
            render: (r) => (
              <Button size="sm" variant="ghost" onClick={() => setManagingPlanId(r.id)}>
                {t("masters.amcPlans.manageCoveredSpares")}
              </Button>
            ),
          },
        ]}
        onCreate={(v) => {
          const { price, pricePerYear } = resolvePricing(v)
          return createMut.mutateAsync({
            org_id: orgId!,
            name: v.name,
            years: Number(v.years) || 1,
            price,
            price_per_year: pricePerYear,
            visits_per_year: Number(v.visits_per_year) || 4,
            gift_id: v.gift_id === NO_GIFT ? null : v.gift_id,
            inclusions: textToInclusions(v.inclusions),
          })
        }}
        onUpdate={(id, v) => {
          const { price, pricePerYear } = resolvePricing(v)
          return updateMut.mutateAsync({
            id,
            patch: {
              name: v.name,
              years: Number(v.years) || 1,
              price,
              price_per_year: pricePerYear,
              visits_per_year: Number(v.visits_per_year) || 4,
              gift_id: v.gift_id === NO_GIFT ? null : v.gift_id,
              inclusions: textToInclusions(v.inclusions),
            },
          })
        }}
        onDelete={(id) => deleteMut.mutateAsync(id)}
      />

      {managingPlan ? (
        <AmcPlanCoveredSparesPanel key={managingPlan.id} planId={managingPlan.id} planName={managingPlan.name} orgId={orgId} onClose={() => setManagingPlanId(null)} />
      ) : null}
    </div>
  )
}

/** Fix 2: lets an admin mark exactly which spares are free on a given AMC
 * plan's visits — everything else on an AMC ticket bills at normal price
 * even when the visit itself is otherwise non-chargeable (enforced
 * server-side in create_service_invoice, this is just the admin picker). */
function AmcPlanCoveredSparesPanel({
  planId,
  planName,
  orgId,
  onClose,
}: {
  planId: string
  planName: string
  orgId: string | undefined
  onClose: () => void
}) {
  const { t } = useTranslation()
  const { data: spares } = sparesHooks.useList(orgId)
  const { data: coveredIds, isLoading } = useAmcPlanCoveredSpares(planId)
  const setCovered = useSetAmcPlanCoveredSpares()
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const [term, setTerm] = useState("")

  useEffect(() => {
    if (coveredIds) setSelected(new Set(coveredIds))
  }, [coveredIds])

  function toggle(id: string) {
    setSelected((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  const filtered = (spares ?? []).filter((s) => s.name.toLowerCase().includes(term.trim().toLowerCase()))

  return (
    <Card className="gap-3 px-5">
      <div className="flex items-center justify-between">
        <h2 className="text-sm font-semibold text-text">
          {t("masters.amcPlans.coveredSparesTitle")} — {planName}
        </h2>
        <Button size="sm" variant="ghost" onClick={onClose}>
          {t("common.cancel")}
        </Button>
      </div>
      <p className="px-1 text-xs text-text-muted">{t("masters.amcPlans.coveredSparesHint")}</p>
      <Input value={term} onChange={(e) => setTerm(e.target.value)} placeholder={t("masters.amcPlans.searchSpares")} />
      {isLoading ? (
        <p className="px-1 text-sm text-text-muted">{t("common.loading")}</p>
      ) : (
        <div className="max-h-64 space-y-1 overflow-auto rounded-xl border border-border p-2">
          {filtered.length === 0 ? (
            <p className="px-2 py-2 text-sm text-text-muted">{t("masters.amcPlans.noSpares")}</p>
          ) : (
            filtered.map((s) => (
              <label key={s.id} className="flex items-center gap-2 px-2 py-1.5 text-sm text-text">
                <input type="checkbox" checked={selected.has(s.id)} onChange={() => toggle(s.id)} className="size-4" />
                <span className="flex-1">{s.name}</span>
                {s.sku ? <span className="text-xs text-text-muted">{s.sku}</span> : null}
              </label>
            ))
          )}
        </div>
      )}
      <p className="px-1 text-xs text-text-muted">{t("masters.amcPlans.coveredSparesCount", { count: selected.size })}</p>
      {setCovered.isError ? <p className="rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{(setCovered.error as Error).message}</p> : null}
      <div className="flex justify-end">
        <Button
          size="sm"
          disabled={setCovered.isPending}
          onClick={() => setCovered.mutate({ planId, spareIds: Array.from(selected) }, { onSuccess: onClose })}
        >
          {setCovered.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("common.save")}
        </Button>
      </div>
    </Card>
  )
}
