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
import type { Enums } from "@/types/database"

const SOURCE_OPTIONS: Enums<"lead_source">[] = ["field", "customer_app", "whatsapp", "walk_in", "referral", "other"]
const TOPIC_OPTIONS: Enums<"enquiry_type">[] = ["online", "price", "quality", "customization", "water_premium", "budget"]
const KIND_OPTIONS: Enums<"lead_kind">[] = ["service", "spare", "product", "amc"]

export function LeadsPage() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const [source, setSource] = useState<Enums<"lead_source"> | "">("")
  const [enquiryType, setEnquiryType] = useState<Enums<"enquiry_type"> | "">("")
  const [kind, setKind] = useState<Enums<"lead_kind"> | "">("")
  const leads = useLeads(orgId, { source: source || undefined, enquiryType: enquiryType || undefined, kind: kind || undefined })
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

      <div className="flex flex-wrap items-center gap-2.5">
        <select
          value={source}
          onChange={(e) => setSource(e.target.value as Enums<"lead_source"> | "")}
          className="h-9 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"
        >
          <option value="">{t("leads.filters.allSources")}</option>
          {SOURCE_OPTIONS.map((s) => (
            <option key={s} value={s}>
              {t(`leads.source.${s}`)}
            </option>
          ))}
        </select>
        <select
          value={enquiryType}
          onChange={(e) => setEnquiryType(e.target.value as Enums<"enquiry_type"> | "")}
          className="h-9 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"
        >
          <option value="">{t("leads.filters.allTopics")}</option>
          {TOPIC_OPTIONS.map((et) => (
            <option key={et} value={et}>
              {t(`leads.enquiryType.${et}`)}
            </option>
          ))}
        </select>
        <select
          value={kind}
          onChange={(e) => setKind(e.target.value as Enums<"lead_kind"> | "")}
          className="h-9 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"
        >
          <option value="">{t("leads.filters.allKinds")}</option>
          {KIND_OPTIONS.map((k) => (
            <option key={k} value={k}>
              {t(`leads.kind.${k}`)}
            </option>
          ))}
        </select>
        {source || enquiryType || kind ? (
          <button
            type="button"
            onClick={() => {
              setSource("")
              setEnquiryType("")
              setKind("")
            }}
            className="text-xs font-semibold text-text-muted hover:text-text"
          >
            {t("leads.filters.clear")}
          </button>
        ) : null}
      </div>

      <div className="flex flex-col gap-4 lg:flex-row lg:items-start">
        {/* The board needs room for 5 status columns — a fixed-width detail
            sidebar (rather than a 2:1 grid fraction) keeps the columns from
            getting cramped while the panel stays a comfortable reading width
            instead of stretching to a third of the page when nothing (or a
            single lead) is shown there. */}
        <div className="min-w-0 lg:flex-1">
          <LeadsKanban
            rows={leads.data ?? []}
            loading={leads.isLoading}
            error={leads.isError ? t("leads.loadFailed") : null}
            onRetry={() => leads.refetch()}
            onCardClick={setSelected}
          />
        </div>
        <div className="lg:w-80 lg:shrink-0">
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
