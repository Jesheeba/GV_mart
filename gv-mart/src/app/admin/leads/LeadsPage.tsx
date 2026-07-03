import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { Plus, Target, TrendingUp, Trophy } from "lucide-react"
import { Button } from "@/components/ui/button"
import { KpiCard } from "@/components/shared/KpiCard"
import { useProfile } from "@/hooks/useProfile"
import { useLeads } from "@/hooks/useAutomation"
import { LeadsKanban } from "./LeadsKanban"
import { LeadDetailPanel } from "./LeadDetailPanel"
import { NewLeadForm } from "./NewLeadForm"
import type { LeadListItem } from "@/services/automation"

export function LeadsPage() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const leads = useLeads(orgId)
  const [showNew, setShowNew] = useState(false)
  const [selected, setSelected] = useState<LeadListItem | null>(null)

  const stats = useMemo(() => {
    const rows = leads.data ?? []
    const won = rows.filter((r) => r.status === "won").length
    const lost = rows.filter((r) => r.status === "lost").length
    const closed = won + lost
    const conversionRate = closed > 0 ? Math.round((won / closed) * 100) : 0
    const bySource = new Map<string, number>()
    for (const r of rows) bySource.set(r.source, (bySource.get(r.source) ?? 0) + 1)
    const topSource = [...bySource.entries()].sort((a, b) => b[1] - a[1])[0]
    return { total: rows.length, won, conversionRate, topSource }
  }, [leads.data])

  return (
    <div className="space-y-4 pt-2">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold text-text">{t("nav.leads")}</h1>
          <p className="text-sm text-text-muted">{t("leads.subtitle")}</p>
        </div>
        <Button variant="accent" onClick={() => setShowNew((v) => !v)}>
          <Plus className="size-4" />
          {t("leads.new.title")}
        </Button>
      </div>

      <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
        <KpiCard label={t("leads.kpi.total")} value={stats.total} icon={<Target className="size-4" />} loading={leads.isLoading} />
        <KpiCard label={t("leads.kpi.won")} value={stats.won} icon={<Trophy className="size-4" />} loading={leads.isLoading} />
        <KpiCard
          label={t("leads.kpi.conversionRate")}
          value={`${stats.conversionRate}%`}
          icon={<TrendingUp className="size-4" />}
          loading={leads.isLoading}
        />
      </div>

      {showNew ? <NewLeadForm onClose={() => setShowNew(false)} onCreated={() => { setShowNew(false); leads.refetch() }} /> : null}

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-3">
        <div className="lg:col-span-2">
          <LeadsKanban
            rows={leads.data ?? []}
            loading={leads.isLoading}
            error={leads.isError ? t("leads.loadFailed") : null}
            onRetry={() => leads.refetch()}
            onCardClick={setSelected}
          />
        </div>
        <div>
          {selected ? (
            <LeadDetailPanel lead={selected} onClose={() => setSelected(null)} />
          ) : (
            <div className="rounded-subcard border border-dashed border-border p-6 text-center text-sm text-text-muted">
              {t("leads.detail.selectHint")}
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
