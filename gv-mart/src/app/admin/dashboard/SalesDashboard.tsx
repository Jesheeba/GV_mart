import { useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { Plus } from "lucide-react"
import { useSalesServiceReport } from "@/hooks/useReports"
import { useLeads } from "@/hooks/useAutomation"
import { useQuotationsList } from "@/hooks/useQuotations"
import { defaultPeriodValue, periodToRange, type PeriodValue } from "@/services/reports"
import { formatCurrency } from "@/lib/sale-calc"
import { cn } from "@/lib/utils"
import { PeriodFilter } from "../reports/PeriodFilter"

const LEAD_STAGE_TONE: Record<string, string> = {
  new: "#C9C4BA",
  contacted: "#2E6BE6",
  quoted: "#E8932B",
  won: "#2FAE5F",
  lost: "#E5484D",
}

const LEAD_STAGES = ["new", "contacted", "quoted", "won"] as const

function leadName(l: { customers: { name: string } | null; name: string }) {
  return l.customers?.name ?? l.name
}

export function SalesDashboard({ orgId, firstName }: { orgId: string; firstName: string }) {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const [period, setPeriod] = useState<PeriodValue>(defaultPeriodValue())
  const range = periodToRange(period)

  const { data: salesService, isLoading: ssLoading } = useSalesServiceReport(orgId, range)
  const { data: leads, isLoading: leadsLoading } = useLeads(orgId, { dateRange: range })
  // Open Leads / Lead Pipeline are a live queue-depth signal ("what's still
  // open right now"), not a historical metric — filtering them to "created
  // during period" would silently hide older still-open leads, so they stay
  // unfiltered regardless of `period` (matches OwnerDashboard's Open Tickets).
  const { data: allLeads, isLoading: allLeadsLoading } = useLeads(orgId)
  const { data: quotations } = useQuotationsList(orgId, range)

  const openLeads = allLeads?.filter((l) => l.status !== "won" && l.status !== "lost") ?? []
  const wonLeads = leads?.filter((l) => l.status === "won").length ?? 0
  const totalLeads = leads?.length ?? 0
  const conversionPct = totalLeads ? Math.round((wonLeads / totalLeads) * 100) : 0

  const convertedQuotes = quotations?.filter((q) => q.status === "converted").length ?? 0
  const totalQuotes = quotations?.length ?? 0
  const quoteConversionPct = totalQuotes ? Math.round((convertedQuotes / totalQuotes) * 100) : 0

  const pipelineCounts = LEAD_STAGES.map((stage) => ({
    stage,
    count: allLeads?.filter((l) => l.status === stage).length ?? 0,
    sample: allLeads?.find((l) => l.status === stage) ?? null,
  }))

  const sourceCounts = new Map<string, number>()
  for (const l of leads ?? []) sourceCounts.set(l.source, (sourceCounts.get(l.source) ?? 0) + 1)
  const sourceRows = [...sourceCounts.entries()]
    .map(([source, count]) => ({ source, count, pct: totalLeads ? Math.round((count / totalLeads) * 100) : 0 }))
    .sort((a, b) => b.count - a.count)
    .slice(0, 4)

  const recentLeads = [...(leads ?? [])].slice(0, 4)

  const periodLabel =
    period.mode === "year"
      ? String(period.year)
      : period.mode === "month"
        ? new Date(Number(period.month.slice(0, 4)), Number(period.month.slice(5, 7)) - 1, 1).toLocaleDateString("en-IN", { month: "long", year: "numeric" })
        : `${new Date(range.from).toLocaleDateString("en-IN", { day: "numeric", month: "short" })} – ${new Date(range.to).toLocaleDateString("en-IN", { day: "numeric", month: "short", year: "numeric" })}`

  return (
    <div>
      <div className="mb-5 flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="mb-1.5 text-[30px] font-extrabold leading-[1.05] tracking-tight text-text">{t("dashboard.welcomeBack", { name: firstName })}</h1>
          <p className="text-sm font-medium text-text-muted">{t("dashboard.salesAdminSubtitle")}</p>
        </div>
        <div className="flex items-center gap-2.5">
          <button
            type="button"
            onClick={() => navigate("/admin/quotations/new")}
            className="rounded-full border border-[#DAD5CC] bg-surface px-4 py-2.5 text-sm font-semibold text-text"
          >
            {t("dashboard.newQuotation")}
          </button>
          <button
            type="button"
            onClick={() => navigate("/admin/leads")}
            className="flex items-center gap-1.5 rounded-full bg-ink px-[18px] py-2.75 text-sm font-bold text-white shadow-[0_10px_20px_-12px_rgba(26,26,26,0.6)]"
          >
            <Plus className="size-4" />
            {t("dashboard.newLead")}
          </button>
        </div>
      </div>

      <div className="mb-4.5 rounded-card border border-border bg-surface p-4 shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
        <PeriodFilter value={period} onChange={setPeriod} />
      </div>

      <div className="mb-4.5 grid grid-cols-1 gap-4.5 sm:grid-cols-3">
        <div className="relative flex flex-col gap-4 overflow-hidden rounded-card bg-gradient-to-br from-accent to-[#FF7E47] p-5.5 text-white shadow-[0_14px_32px_-16px_rgba(245,97,44,0.65)]">
          <div className="absolute -right-7.5 -top-7.5 size-30 rounded-full bg-white/10" />
          <span className="relative text-[13px] font-semibold text-white/90">{t("dashboard.totalRevenue")}</span>
          <div className="relative text-[31px] font-extrabold leading-none tracking-tight tabular-nums">{ssLoading ? "—" : formatCurrency(salesService?.totalRevenue ?? 0)}</div>
          <span className="relative w-fit rounded-full bg-white/25 px-2.5 py-1 text-xs font-bold">{periodLabel}</span>
        </div>
        <div className="flex flex-col gap-4 rounded-card border border-border bg-surface p-5.5 shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
          <span className="text-[13px] font-semibold text-text-muted">{t("dashboard.openLeads")}</span>
          <div className="text-[31px] font-extrabold leading-none tracking-tight tabular-nums text-text">{allLeadsLoading ? "—" : openLeads.length}</div>
          <span className="text-xs font-semibold text-text-muted">{totalLeads} {t("dashboard.leads")}</span>
        </div>
        <div className="flex flex-col gap-4 rounded-card border border-border bg-surface p-5.5 shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
          <span className="text-[13px] font-semibold text-text-muted">{t("dashboard.quotationToSale")}</span>
          <div className="text-[31px] font-extrabold leading-none tracking-tight tabular-nums text-text">{quoteConversionPct}%</div>
          <span className="text-xs font-semibold text-text-muted">{convertedQuotes} {t("dashboard.of")} {totalQuotes} {t("dashboard.won")}</span>
        </div>
      </div>

      <div className="mb-4.5 grid grid-cols-1 gap-4.5 lg:grid-cols-[1.55fr_1fr]">
        <div className="rounded-card border border-border bg-surface p-5.5 shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
          <h3 className="mb-4 text-[17px] font-bold tracking-tight text-text">{t("dashboard.leadPipeline")}</h3>
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
            {pipelineCounts.map(({ stage, count, sample }) => (
              <div key={stage} className={cn("flex flex-col gap-2.25 rounded-[14px] p-3.25", stage === "won" ? "bg-accent-soft" : "bg-surface-alt")}>
                <div className="flex items-center justify-between">
                  <span className={cn("text-xs font-bold", stage === "won" ? "text-accent" : "text-text-muted")}>{t(`leads.status.${stage}`)}</span>
                  <span className={cn("text-xs font-bold tabular-nums", stage === "won" && "text-accent")}>{count}</span>
                </div>
                {sample ? (
                  <div className="rounded-[9px] border border-border bg-surface px-2.25 py-2.25 text-[11px] font-semibold text-text">{leadName(sample)}</div>
                ) : null}
              </div>
            ))}
          </div>
        </div>

        <div className="flex flex-col justify-center rounded-card border border-border bg-surface p-5.5 shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
          <h3 className="mb-4.5 text-[17px] font-bold tracking-tight text-text">{t("dashboard.leadConversion")}</h3>
          <div className="mb-2.5 flex items-baseline justify-between">
            <span className="text-[26px] font-extrabold tabular-nums tracking-tight text-text">{conversionPct}%</span>
            <span className="text-sm font-semibold text-text-muted">{wonLeads} / {totalLeads}</span>
          </div>
          <div className="mb-2.5 h-3 overflow-hidden rounded-full bg-[#F0EBE3]">
            <div className="h-full rounded-full bg-gradient-to-r from-accent to-[#FF7E47]" style={{ width: `${conversionPct}%` }} />
          </div>
          <p className="text-xs font-medium text-text-muted">{wonLeads} {t("dashboard.leadsWonThisMonth")}</p>
        </div>
      </div>

      <div className="grid grid-cols-1 gap-4.5 lg:grid-cols-[1.55fr_1fr]">
        <div className="overflow-hidden rounded-card border border-border bg-surface shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
          <div className="px-5.5 pb-3 pt-4.5">
            <h3 className="text-[17px] font-bold tracking-tight text-text">{t("dashboard.recentLeads")}</h3>
          </div>
          <div className="grid grid-cols-[1.5fr_1.1fr_1.1fr_1fr] border-y border-border bg-surface-alt px-5.5 py-2.5">
            {[t("dashboard.tableLead"), t("dashboard.tableSource"), t("dashboard.tableInterest"), t("dashboard.tableStage")].map((h) => (
              <span key={h} className="text-[11px] font-semibold uppercase tracking-wide text-text-muted">
                {h}
              </span>
            ))}
          </div>
          {leadsLoading ? (
            <p className="p-5.5 text-sm text-text-muted">{t("common.loading")}</p>
          ) : recentLeads.length === 0 ? (
            <p className="p-5.5 text-sm text-text-muted">{t("dashboard.noLeads")}</p>
          ) : (
            recentLeads.map((l, i) => (
              <div key={l.id} className={cn("grid grid-cols-[1.5fr_1.1fr_1.1fr_1fr] items-center px-5.5 py-3.25", i < recentLeads.length - 1 && "border-b border-[#F1EDE6]")}>
                <span className="text-[13px] font-semibold text-text">{leadName(l)}</span>
                <span className="text-[13px] font-medium text-[#3A3A36]">{t(`leads.source.${l.source}`)}</span>
                <span className="text-[13px] font-medium text-[#3A3A36]">{l.enquiry_type ? t(`leads.enquiryType.${l.enquiry_type}`) : "—"}</span>
                <span className="flex items-center gap-1.5 text-xs font-semibold" style={{ color: LEAD_STAGE_TONE[l.status] }}>
                  <span className="size-1.75 rounded-full" style={{ background: LEAD_STAGE_TONE[l.status] }} />
                  {t(`leads.status.${l.status}`)}
                </span>
              </div>
            ))
          )}
        </div>

        <div className="rounded-card border border-border bg-surface p-5 shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
          <h3 className="mb-4 text-base font-bold tracking-tight text-text">{t("dashboard.sourceConversion")}</h3>
          {sourceRows.length === 0 ? (
            <p className="text-sm text-text-muted">{t("dashboard.noLeads")}</p>
          ) : (
            <div className="flex flex-col gap-3.75">
              {sourceRows.map((row) => (
                <div key={row.source}>
                  <div className="mb-1.5 flex justify-between">
                    <span className="text-xs font-semibold text-text">{t(`leads.source.${row.source}`)}</span>
                    <span className="text-xs font-bold tabular-nums text-text">{row.pct}%</span>
                  </div>
                  <div className="h-2 overflow-hidden rounded-full bg-[#F0EBE3]">
                    <div className="h-full rounded-full bg-accent" style={{ width: `${row.pct}%` }} />
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
