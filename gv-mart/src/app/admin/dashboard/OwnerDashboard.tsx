import { useState } from "react"
import { useQueries } from "@tanstack/react-query"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { TriangleAlert } from "lucide-react"
import { useSalesServiceReport } from "@/hooks/useReports"
import { useKpiTiles } from "@/hooks/useKpiTiles"
import { useTicketsList } from "@/hooks/useService"
import { useInventoryList } from "@/hooks/useInventory"
import * as reports from "@/services/reports"
import { defaultPeriodValue, periodToRange, type PeriodValue } from "@/services/reports"
import { formatCurrency } from "@/lib/sale-calc"
import { cn } from "@/lib/utils"
import { lastNMonthsEnding, monthsOfYear, todayRange, barHeights } from "./dashboardMath"
import { PeriodFilter } from "../reports/PeriodFilter"
import { KpiTileStrip } from "../kpi/KpiTileStrip"

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

  // Owner request 2026-07-29: this screen used to be permanently pinned to
  // "this month" with no way to look at a past month or year. `period` now
  // drives everything that's genuinely period-shaped (revenue, sales mix,
  // top technicians, lead conversion, the P&L trend). Today's Sales and Open
  // Tickets deliberately stay outside `period` — see their own comments below.
  const [period, setPeriod] = useState<PeriodValue>(defaultPeriodValue())
  const range = periodToRange(period)

  // P&L trend chart granularity changes meaning by mode (owner-confirmed):
  // Month mode keeps the original "7 trailing months" shape, just anchored to
  // whichever month is selected instead of always "now" — picking the
  // current month reproduces exactly today's output. Year mode shows all 12
  // months of that year, since a 7-month trailing window would silently
  // bleed into the previous year and misrepresent "year-wise". Custom range
  // falls back to 7 trailing months ending at the range's own end month.
  const months =
    period.mode === "year"
      ? monthsOfYear(period.year)
      : period.mode === "month"
        ? lastNMonthsEnding(Number(period.month.slice(0, 4)), Number(period.month.slice(5, 7)), 7)
        : lastNMonthsEnding(Number(range.to.slice(0, 4)), Number(range.to.slice(5, 7)), 7)

  const { data: salesService, isLoading: ssLoading } = useSalesServiceReport(orgId, range)
  // Server tiles (report_kpi_tiles): the strip below reads the same cached query; Needs attention reuses it for ticket / AMC counts.
  const { data: kpi } = useKpiTiles(range)
  const { data: kpiToday } = useKpiTiles(todayRange())
  const { data: tickets, isLoading: ticketsLoading } = useTicketsList(orgId, { excludeTest: true })
  const { data: spares } = useInventoryList(orgId, "spare")

  const monthlyPnl = useQueries({
    queries: months.map((m) => ({
      queryKey: ["reports", "pnl", orgId, m.range],
      queryFn: () => reports.getPnlReport(orgId, m.range),
    })),
  })

  // Open Tickets is a live queue-depth signal ("what's on my plate right
  // now"), not a historical metric — filtering it to "opened during period"
  // would silently change its meaning, so it stays unfiltered regardless of
  // `period` (matches OpsDashboard's equivalent tile).
  // Open tickets and AMC renewals now come from the server tiles (test customers excluded there); the list below only feeds Recent tickets.
  const openTicketCount = kpi?.service?.openTickets.count ?? 0
  const amcDueCount = kpi?.service?.amc.renewalWindow ?? 0
  const lowStockCount = spares?.filter((s) => s.stock_qty <= s.min_stock).length ?? 0

  const profitSeries = monthlyPnl.map((q) => q.data?.netProfitWithGst ?? 0)
  const costSeries = monthlyPnl.map((q) => q.data?.totalExpenses ?? 0)
  const profitHeights = barHeights(profitSeries)
  const costHeights = barHeights(costSeries)
  const pnlChartLoading = monthlyPnl.some((q) => q.isLoading)

  // Revenue mix by the report's own revenue classes (one invoice, one class): Sales = product invoices
  // plus counter spare sales, Service = spare invoices raised from a service visit (full invoice total,
  // which already contains the service charge, so nothing is added on top), AMC. Rental is not a slice
  // of this chart (it never was).
  const revenueOf = (type: "sales" | "service" | "amc" | "rental") => salesService?.revenueByType.find((r) => r.type === type)?.revenue ?? 0
  const productTotal = revenueOf("sales")
  const amcTotal = revenueOf("amc")
  const serviceTotal = revenueOf("service")
  const mixTotal = productTotal + serviceTotal + amcTotal || 1
  const productPct = Math.round((productTotal / mixTotal) * 100)
  const servicePct = Math.round((serviceTotal / mixTotal) * 100)
  const amcPct = Math.max(0, 100 - productPct - servicePct)

  const topTechs = [...(salesService?.technicianServiceCounts ?? [])].sort((a, b) => b.revenue - a.revenue).slice(0, 3)
  const recentTickets = [...(tickets ?? [])].slice(0, 5)

  // Human label for the currently-selected period — used wherever a badge
  // used to hardcode "This Month" (Total Revenue tile, Top Technicians).
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
          <p className="text-sm font-medium text-text-muted">{t("dashboard.masterSubtitle")}</p>
        </div>
        <div className="flex items-center gap-2.5">
          <button
            type="button"
            onClick={() => navigate("/admin/service/new")}
            className="flex items-center gap-1.5 rounded-full border border-border bg-surface px-4 py-2.5 text-sm font-bold text-text"
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

      <div className="mb-4.5 rounded-card border border-border bg-surface p-4 shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
        <PeriodFilter value={period} onChange={setPeriod} />
      </div>

      <KpiTileStrip range={range} className="mb-4.5" />

      {/* Today (IST), same server function as the tiles above so the two can never disagree. Not scoped to the period. */}
      {kpiToday?.sales ? (
        <div data-testid="kpi-today-sales" className="mb-4.5 flex flex-wrap items-baseline gap-x-4 gap-y-1 rounded-card border border-border bg-surface px-5 py-3 text-sm">
          <span className="font-semibold text-text-muted">{t("kpi.todaySales")}</span>
          <span className="text-lg font-extrabold tabular-nums text-text">{formatCurrency(kpiToday.sales.invoicedNet)}</span>
          <span className="text-xs font-semibold text-text-muted">{t("kpi.invoiced.sub", { amount: formatCurrency(kpiToday.sales.invoicedTotal) })}</span>
        </div>
      ) : null}

      <div className="mb-4.5 grid grid-cols-1 gap-4.5 lg:grid-cols-[1.55fr_1fr]">
        <div className="rounded-card border border-border bg-surface p-5.5 pb-4 shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
          <div className="mb-5 flex items-start justify-between">
            <div>
              <h3 className="mb-1 text-[17px] font-bold tracking-tight text-text">{t("dashboard.profitLoss")}</h3>
              <p className="text-xs font-medium text-text-muted">
                {period.mode === "year" ? t("dashboard.monthsOfYear", { year: period.year }) : t("dashboard.last7Months")}
              </p>
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
              <MixRow color="#F5612C" label={t("reports.salesService.revenueTypeLabel.sales")} amount={productTotal} pct={productPct} />
              <MixRow color="#1A1A1A" label={t("reports.salesService.revenueTypeLabel.service")} amount={serviceTotal} pct={servicePct} />
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
                <div key={tk.id} className={cn("grid grid-cols-[1.4fr_1.2fr_0.9fr_1fr] items-center px-5.5 py-3.25", i < recentTickets.length - 1 && "border-b border-border")}>
                  <div className="flex items-center gap-2.5">
                    <span className="flex size-7.5 items-center justify-center rounded-[9px] bg-accent-soft text-[11px] font-bold text-accent">{initials}</span>
                    <div className="leading-tight">
                      <div className="text-[13px] font-semibold text-text">{tk.customers?.name ?? "—"}</div>
                      <div className="text-[11px] font-medium text-text-muted">{tk.addresses?.area ?? "—"}</div>
                    </div>
                  </div>
                  <span className="text-[13px] font-medium text-text-muted">{tk.products?.name ?? "—"}</span>
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
              <span className="text-[11px] font-semibold text-text-muted">{periodLabel}</span>
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
                <AttentionRow
                  tone="danger"
                  title={t("dashboard.lowStockCount", { count: lowStockCount })}
                  subtitle={t("dashboard.lowStockSubtitle")}
                  onClick={() => navigate("/admin/inventory")}
                />
              )}
              {amcDueCount > 0 && (
                <AttentionRow
                  tone="info"
                  title={t("dashboard.amcDueCount", { count: amcDueCount })}
                  subtitle={t("dashboard.amcDueSubtitle")}
                  onClick={() => navigate("/admin/amc")}
                />
              )}
              {openTicketCount > 0 && (
                <AttentionRow
                  tone="warning"
                  title={t("dashboard.openTicketsCount", { count: openTicketCount })}
                  subtitle={t("dashboard.openTicketsSubtitle")}
                  onClick={() => navigate("/admin/service")}
                />
              )}
              {lowStockCount === 0 && amcDueCount === 0 && openTicketCount === 0 && (
                <p className="text-sm text-text-muted">{t("dashboard.allClear")}</p>
              )}
            </div>
          </div>

          <LifecycleWidgetCard lifecycle={kpi?.service?.lifecycle ?? null} onNavigate={navigate} />
        </div>
      </div>
    </div>
  )
}

/**
 * Product Lifecycle widget (W4 drop). Counts come straight off the same
 * `report_kpi_tiles` payload the KPI strip above already fetched (useKpiTiles(range)
 * is cached by react-query, so reading `kpi?.service?.lifecycle` here issues no
 * extra network call) — it can never disagree with the rest of the strip. Each
 * number links into LifecycleOverviewPage pre-filtered to that bucket.
 */
function LifecycleWidgetCard({
  lifecycle,
  onNavigate,
}: {
  lifecycle: { upcoming: number; due: number; overdue: number; lifetimeExpiring90d: number } | null
  onNavigate: (path: string) => void
}) {
  const { t } = useTranslation()
  return (
    <div className="rounded-card border border-border bg-surface p-5 shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
      <h3 className="mb-4 text-base font-bold tracking-tight text-text">{t("lifecycleDashboard.widget.title")}</h3>
      <div className="grid grid-cols-2 gap-3">
        <LifecycleStat label={t("lifecycleDashboard.widget.upcoming")} value={lifecycle?.upcoming ?? 0} onClick={() => onNavigate("/admin/lifecycle?status=due_soon")} />
        <LifecycleStat label={t("lifecycleDashboard.widget.due")} value={lifecycle?.due ?? 0} onClick={() => onNavigate("/admin/lifecycle?status=due")} />
        <LifecycleStat label={t("lifecycleDashboard.widget.overdue")} value={lifecycle?.overdue ?? 0} onClick={() => onNavigate("/admin/lifecycle?status=overdue")} />
        <LifecycleStat
          label={t("lifecycleDashboard.widget.lifetimeExpiring90d")}
          value={lifecycle?.lifetimeExpiring90d ?? 0}
          onClick={() => onNavigate("/admin/lifecycle?status=lifetime_expiring_90d")}
        />
      </div>
    </div>
  )
}

function LifecycleStat({ label, value, onClick }: { label: string; value: number; onClick: () => void }) {
  return (
    <button
      type="button"
      onClick={onClick}
      className="flex flex-col items-start gap-0.5 rounded-lg px-2 py-1.5 text-left transition-colors hover:bg-surface-alt/60 -mx-2"
    >
      <span className="text-[22px] font-extrabold tabular-nums leading-none text-text">{value}</span>
      <span className="text-[11px] font-semibold text-text-muted">{label}</span>
    </button>
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

function AttentionRow({
  tone,
  title,
  subtitle,
  onClick,
}: {
  tone: "danger" | "warning" | "info"
  title: string
  subtitle: string
  onClick?: () => void
}) {
  const toneClass = tone === "danger" ? "bg-danger/10 text-danger" : tone === "warning" ? "bg-warning/10 text-warning" : "bg-info/10 text-info"
  return (
    <button
      type="button"
      onClick={onClick}
      className="flex items-start gap-2.75 rounded-lg text-left transition-colors hover:bg-surface-alt/60 -mx-1 px-1 py-0.5"
    >
      <span className={cn("flex size-7.5 shrink-0 items-center justify-center rounded-[9px]", toneClass)}>
        <TriangleAlert className="size-4" />
      </span>
      <div className="leading-tight">
        <div className="text-[13px] font-semibold text-text">{title}</div>
        <div className="text-[11px] font-medium text-text-muted">{subtitle}</div>
      </div>
    </button>
  )
}
