import { useQueries } from "@tanstack/react-query"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { IndianRupee, ReceiptText, Target, TriangleAlert } from "lucide-react"
import { usePnlReport, useSalesServiceReport } from "@/hooks/useReports"
import { useTicketsList } from "@/hooks/useService"
import { useLeads } from "@/hooks/useAutomation"
import { useInventoryList } from "@/hooks/useInventory"
import { useAmcContracts } from "@/hooks/useAmc"
import * as reports from "@/services/reports"
import { formatCurrency } from "@/lib/sale-calc"
import { cn } from "@/lib/utils"
import { lastNMonths, thisMonthRange, todayRange, barHeights } from "./dashboardMath"

const TICKET_STATUS_TONE: Record<string, string> = {
  open: "#E8932B",
  assigned: "#2E6BE6",
  in_progress: "#E8932B",
  completed: "#2FAE5F",
  cancelled: "#8A8A82",
}

export function OwnerDashboard({ orgId, firstName }: { orgId: string; firstName: string }) {
  const { t } = useTranslation()
  const navigate = useNavigate()

  const range = thisMonthRange()
  const months = lastNMonths(7)

  const { data: pnl, isLoading: pnlLoading } = usePnlReport(orgId, range)
  const { data: salesService, isLoading: ssLoading } = useSalesServiceReport(orgId, range)
  const { data: todaySales } = useSalesServiceReport(orgId, todayRange())
  const { data: tickets, isLoading: ticketsLoading } = useTicketsList(orgId, {})
  const { data: leads } = useLeads(orgId)
  const { data: spares } = useInventoryList(orgId, "spare")
  const { data: amcContracts } = useAmcContracts(orgId)

  const monthlyPnl = useQueries({
    queries: months.map((m) => ({
      queryKey: ["reports", "pnl", orgId, m.range],
      queryFn: () => reports.getPnlReport(orgId, m.range),
    })),
  })

  const openTickets = tickets?.filter((tk) => tk.status !== "completed" && tk.status !== "cancelled") ?? []
  const wonLeads = leads?.filter((l) => l.status === "won").length ?? 0
  const conversionPct = leads?.length ? Math.round((wonLeads / leads.length) * 100) : 0
  const lowStockCount = spares?.filter((s) => s.stock_qty <= s.min_stock).length ?? 0
  const amcDueSoon = amcContracts?.filter((c) => c.status === "due_soon") ?? []

  const profitSeries = monthlyPnl.map((q) => q.data?.netProfitWithGst ?? 0)
  const costSeries = monthlyPnl.map((q) => q.data?.totalExpenses ?? 0)
  const profitHeights = barHeights(profitSeries)
  const costHeights = barHeights(costSeries)
  const pnlChartLoading = monthlyPnl.some((q) => q.isLoading)

  const productTotal = salesService?.invoiceTypeRatio.find((r) => r.type === "product")?.total ?? 0
  const amcTotal = salesService?.invoiceTypeRatio.find((r) => r.type === "amc")?.total ?? 0
  const spareInvoiceTotal = salesService?.invoiceTypeRatio.find((r) => r.type === "spare")?.total ?? 0
  const serviceVisitTotal = salesService?.technicianServiceCounts.reduce((sum, tc) => sum + tc.revenue, 0) ?? 0
  const serviceTotal = spareInvoiceTotal + serviceVisitTotal
  const mixTotal = productTotal + serviceTotal + amcTotal || 1
  const productPct = Math.round((productTotal / mixTotal) * 100)
  const servicePct = Math.round((serviceTotal / mixTotal) * 100)
  const amcPct = Math.max(0, 100 - productPct - servicePct)

  const topTechs = [...(salesService?.technicianServiceCounts ?? [])].sort((a, b) => b.revenue - a.revenue).slice(0, 3)
  const recentTickets = [...(tickets ?? [])].slice(0, 5)

  return (
    <div>
      <div className="mb-5 flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="mb-1.5 text-[30px] font-extrabold leading-[1.05] tracking-tight text-text">{t("dashboard.welcomeBack", { name: firstName })}</h1>
          <p className="text-sm font-medium text-text-muted">{t("dashboard.masterSubtitle")}</p>
        </div>
        <div className="flex items-center gap-2.5">
          <button
            type="button"
            onClick={() => navigate("/admin/service/new")}
            className="flex items-center gap-1.5 rounded-full border border-[#DAD5CC] bg-surface px-4 py-2.5 text-sm font-bold text-text"
          >
            <TriangleAlert className="size-4 text-accent" />
            {t("dashboard.newComplaint")}
          </button>
          <button
            type="button"
            onClick={() => navigate("/admin/sales/new")}
            className="flex items-center gap-1.5 rounded-full bg-ink px-[18px] py-2.75 text-sm font-bold text-white shadow-[0_10px_20px_-12px_rgba(26,26,26,0.6)]"
          >
            {t("dashboard.newSale")}
          </button>
        </div>
      </div>

      <div className="mb-4.5 grid grid-cols-1 gap-4.5 sm:grid-cols-2 lg:grid-cols-4">
        <div className="relative flex flex-col gap-4.5 overflow-hidden rounded-card bg-gradient-to-br from-accent to-[#FF7E47] p-5.5 text-white shadow-[0_14px_32px_-16px_rgba(245,97,44,0.65)]">
          <div className="absolute -right-7.5 -top-7.5 size-30 rounded-full bg-white/10" />
          <div className="relative flex items-center justify-between">
            <span className="text-[13px] font-semibold text-white/90">{t("dashboard.totalRevenue")}</span>
            <span className="flex size-8.5 items-center justify-center rounded-[11px] bg-white/20">
              <IndianRupee className="size-4.5" />
            </span>
          </div>
          <div className="relative text-[33px] font-extrabold tabular-nums leading-none tracking-tight">
            {pnlLoading ? "—" : formatCurrency(pnl?.revenueWithGst ?? 0)}
          </div>
          <div className="relative flex items-center gap-2 text-xs">
            <span className="rounded-full bg-white/25 px-2.5 py-1 font-bold">{t("common.thisMonth")}</span>
          </div>
        </div>

        <DashCard
          label={t("dashboard.openTickets")}
          value={ticketsLoading ? "—" : String(openTickets.length)}
          icon={<TriangleAlert className="size-4.5" />}
          note={<span className="rounded-full bg-[#FCF1DF] px-2.5 py-1 text-xs font-bold text-[#E8932B]">{openTickets.length} {t("dashboard.open")}</span>}
        />
        <DashCard
          label={t("dashboard.todaysSales")}
          value={formatCurrency(todaySales?.totalRevenue ?? 0)}
          icon={<ReceiptText className="size-4.5" />}
          note={<span className="rounded-full bg-[#E7F6ED] px-2.5 py-1 text-xs font-bold text-success">{t("common.today")}</span>}
        />
        <DashCard
          label={t("dashboard.leadConversion")}
          value={`${conversionPct}%`}
          icon={<Target className="size-4.5" />}
          note={<span className="text-xs font-medium text-text-muted">{leads?.length ?? 0} {t("dashboard.leads")}</span>}
        />
      </div>

      <div className="mb-4.5 grid grid-cols-1 gap-4.5 lg:grid-cols-[1.55fr_1fr]">
        <div className="rounded-card border border-border bg-surface p-5.5 pb-4 shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
          <div className="mb-5 flex items-start justify-between">
            <div>
              <h3 className="mb-1 text-[17px] font-bold tracking-tight text-text">{t("dashboard.profitLoss")}</h3>
              <p className="text-xs font-medium text-text-muted">{t("dashboard.last7Months")}</p>
            </div>
            <div className="flex items-center gap-4 text-xs font-semibold text-text">
              <span className="flex items-center gap-1.5"><span className="size-2.25 rounded-[3px] bg-accent" />{t("dashboard.profit")}</span>
              <span className="flex items-center gap-1.5"><span className="size-2.25 rounded-[3px] bg-ink" />{t("dashboard.cost")}</span>
            </div>
          </div>
          <div className="flex h-[188px] items-end justify-between gap-5.5 border-b border-border px-1">
            {months.map((m, i) => (
              <div key={m.label} className="flex h-full flex-1 flex-col items-center justify-end">
                <div className="flex h-full items-end gap-1.25">
                  <div className="w-3.25 rounded-t-[5px] bg-accent transition-[height]" style={{ height: `${pnlChartLoading ? 4 : profitHeights[i]}%` }} />
                  <div className="w-3.25 rounded-t-[5px] bg-ink transition-[height]" style={{ height: `${pnlChartLoading ? 4 : costHeights[i]}%` }} />
                </div>
              </div>
            ))}
          </div>
          <div className="flex justify-between pt-2.5">
            {months.map((m, i) => (
              <span key={m.label} className={cn("flex-1 text-center text-[11px] font-semibold text-text-muted", i === months.length - 1 && "font-bold text-text")}>
                {m.label}
              </span>
            ))}
          </div>
        </div>

        <div className="flex flex-col rounded-card border border-border bg-surface p-5.5 shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
          <h3 className="mb-0.5 text-[17px] font-bold tracking-tight text-text">{t("dashboard.salesVsService")}</h3>
          <p className="mb-3.5 text-xs font-medium text-text-muted">{t("dashboard.revenueMix")}</p>
          <div className="flex flex-1 items-center gap-5">
            <div
              className="relative size-32 shrink-0 rounded-full"
              style={{ background: ssLoading ? "#F0EBE3" : `conic-gradient(#F5612C 0 ${productPct}%, #1A1A1A ${productPct}% ${productPct + servicePct}%, #E8C9BB ${productPct + servicePct}% 100%)` }}
            >
              <div className="absolute inset-[17px] flex flex-col items-center justify-center rounded-full bg-surface">
                <div className="text-[22px] font-extrabold tabular-nums tracking-tight text-text">{ssLoading ? "—" : `₹${(mixTotal / 1_00_000).toFixed(1)}L`}</div>
                <div className="text-[10px] font-medium text-text-muted">{t("dashboard.total")}</div>
              </div>
            </div>
            <div className="flex flex-1 flex-col gap-3.5">
              <MixRow color="#F5612C" label={t("dashboard.productSales")} amount={productTotal} pct={productPct} />
              <MixRow color="#1A1A1A" label={t("dashboard.serviceAndSpares")} amount={serviceTotal} pct={servicePct} />
              <MixRow color="#E8C9BB" label={t("dashboard.amcContracts")} amount={amcTotal} pct={amcPct} />
            </div>
          </div>
        </div>
      </div>

      <div className="grid grid-cols-1 gap-4.5 lg:grid-cols-[1.55fr_1fr]">
        <div className="overflow-hidden rounded-card border border-border bg-surface shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
          <div className="flex items-center justify-between px-5.5 pb-3.5 pt-5">
            <h3 className="text-[17px] font-bold tracking-tight text-text">{t("dashboard.recentTickets")}</h3>
            <button type="button" onClick={() => navigate("/admin/service")} className="text-xs font-bold text-accent">
              {t("common.viewAll")}
            </button>
          </div>
          <div className="grid grid-cols-[1.4fr_1.2fr_0.9fr_1fr] border-y border-border bg-surface-alt px-5.5 py-2">
            {[t("dashboard.tableCustomer"), t("dashboard.tableProduct"), t("dashboard.tableType"), t("dashboard.tableStatus")].map((h) => (
              <span key={h} className="text-[11px] font-semibold uppercase tracking-wide text-text-muted">
                {h}
              </span>
            ))}
          </div>
          {ticketsLoading ? (
            <p className="p-5.5 text-sm text-text-muted">{t("common.loading")}</p>
          ) : recentTickets.length === 0 ? (
            <p className="p-5.5 text-sm text-text-muted">{t("dashboard.noTickets")}</p>
          ) : (
            recentTickets.map((tk, i) => {
              const initials = (tk.customers?.name ?? "—").split(" ").map((p) => p[0]).slice(0, 2).join("").toUpperCase()
              return (
                <div key={tk.id} className={cn("grid grid-cols-[1.4fr_1.2fr_0.9fr_1fr] items-center px-5.5 py-3.25", i < recentTickets.length - 1 && "border-b border-[#F1EDE6]")}>
                  <div className="flex items-center gap-2.5">
                    <span className="flex size-7.5 items-center justify-center rounded-[9px] bg-accent-soft text-[11px] font-bold text-accent">{initials}</span>
                    <div className="leading-tight">
                      <div className="text-[13px] font-semibold text-text">{tk.customers?.name ?? "—"}</div>
                      <div className="text-[11px] font-medium text-text-muted">{tk.addresses?.area ?? "—"}</div>
                    </div>
                  </div>
                  <span className="text-[13px] font-medium text-[#3A3A36]">{tk.products?.name ?? "—"}</span>
                  <span>
                    <span className="rounded-full bg-info/10 px-2.5 py-1 text-[11px] font-bold text-info">{tk.type ? t(`service.type.${tk.type}`) : "—"}</span>
                  </span>
                  <span className="flex items-center gap-1.5 text-xs font-semibold" style={{ color: TICKET_STATUS_TONE[tk.status] ?? "#8A8A82" }}>
                    <span className="size-1.75 rounded-full" style={{ background: TICKET_STATUS_TONE[tk.status] ?? "#8A8A82" }} />
                    {t(`service.status.${tk.status}`)}
                  </span>
                </div>
              )
            })
          )}
        </div>

        <div className="flex flex-col gap-4.5">
          <div className="rounded-card border border-border bg-surface p-5 shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
            <div className="mb-4 flex items-center justify-between">
              <h3 className="text-base font-bold tracking-tight text-text">{t("dashboard.topTechnicians")}</h3>
              <span className="text-[11px] font-semibold text-text-muted">{t("common.thisMonth")}</span>
            </div>
            {ssLoading ? (
              <p className="text-sm text-text-muted">{t("common.loading")}</p>
            ) : topTechs.length === 0 ? (
              <p className="text-sm text-text-muted">{t("dashboard.noTechnicianActivity")}</p>
            ) : (
              <div className="flex flex-col gap-3.5">
                {topTechs.map((tc, i) => {
                  const initials = tc.technicianName.split(" ").map((p) => p[0]).slice(0, 2).join("").toUpperCase()
                  return (
                    <div key={tc.technicianId} className="flex items-center gap-3">
                      <span className={cn("w-3.5 text-[13px] font-extrabold", i === 0 ? "text-accent" : "text-text-muted")}>{i + 1}</span>
                      <span className="flex size-8.5 items-center justify-center rounded-full bg-ink text-xs font-bold text-white">{initials}</span>
                      <div className="flex-1 leading-tight">
                        <div className="text-[13px] font-semibold text-text">{tc.technicianName}</div>
                        <div className="text-[11px] font-medium text-text-muted">{tc.count} {t("dashboard.jobs")}</div>
                      </div>
                      <span className="text-[13px] font-bold tabular-nums text-text">{formatCurrency(tc.revenue)}</span>
                    </div>
                  )
                })}
              </div>
            )}
          </div>

          <div className="rounded-card border border-border bg-surface p-5 shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
            <h3 className="mb-4 text-base font-bold tracking-tight text-text">{t("dashboard.needsAttention")}</h3>
            <div className="flex flex-col gap-3">
              {lowStockCount > 0 && (
                <AttentionRow tone="danger" title={t("dashboard.lowStockCount", { count: lowStockCount })} subtitle={t("dashboard.lowStockSubtitle")} />
              )}
              {amcDueSoon.length > 0 && (
                <AttentionRow tone="info" title={t("dashboard.amcDueCount", { count: amcDueSoon.length })} subtitle={t("dashboard.amcDueSubtitle")} />
              )}
              {openTickets.length > 0 && (
                <AttentionRow tone="warning" title={t("dashboard.openTicketsCount", { count: openTickets.length })} subtitle={t("dashboard.openTicketsSubtitle")} />
              )}
              {lowStockCount === 0 && amcDueSoon.length === 0 && openTickets.length === 0 && (
                <p className="text-sm text-text-muted">{t("dashboard.allClear")}</p>
              )}
            </div>
          </div>
        </div>
      </div>
    </div>
  )
}

function DashCard({ label, value, icon, note }: { label: string; value: string; icon: React.ReactNode; note: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-4.5 rounded-card border border-border bg-surface p-5.5 shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
      <div className="flex items-center justify-between">
        <span className="text-[13px] font-semibold text-text-muted">{label}</span>
        <span className="flex size-8.5 items-center justify-center rounded-[11px] bg-surface-alt text-text">{icon}</span>
      </div>
      <div className="text-[31px] font-extrabold tabular-nums leading-none tracking-tight text-text">{value}</div>
      <div className="flex items-center gap-2">{note}</div>
    </div>
  )
}

function MixRow({ color, label, amount, pct }: { color: string; label: string; amount: number; pct: number }) {
  return (
    <div>
      <div className="mb-0.5 flex items-center gap-1.75">
        <span className="size-2.25 rounded-[3px]" style={{ background: color }} />
        <span className="text-xs font-semibold text-text-muted">{label}</span>
      </div>
      <div className="pl-4 text-[15px] font-bold tabular-nums text-text">
        ₹{(amount / 1_00_000).toFixed(1)}L · {pct}%
      </div>
    </div>
  )
}

function AttentionRow({ tone, title, subtitle }: { tone: "danger" | "warning" | "info"; title: string; subtitle: string }) {
  const toneClass = tone === "danger" ? "bg-[#FCEAEA] text-danger" : tone === "warning" ? "bg-[#FCF1DF] text-warning" : "bg-[#E6EEFC] text-info"
  return (
    <div className="flex items-start gap-2.75">
      <span className={cn("flex size-7.5 shrink-0 items-center justify-center rounded-[9px]", toneClass)}>
        <TriangleAlert className="size-4" />
      </span>
      <div className="leading-tight">
        <div className="text-[13px] font-semibold text-text">{title}</div>
        <div className="text-[11px] font-medium text-text-muted">{subtitle}</div>
      </div>
    </div>
  )
}
