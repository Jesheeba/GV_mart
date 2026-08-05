import { useMemo, useState, type ReactNode } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { Inbox, Plus, TriangleAlert } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Skeleton } from "@/components/ui/skeleton"
import { useProfile } from "@/hooks/useProfile"
import { useInvoicesList } from "@/hooks/useSales"
import { useQuotationsList } from "@/hooks/useQuotations"
import { formatCurrency } from "@/lib/sale-calc"
import { cn } from "@/lib/utils"
import type { Enums } from "@/types/database"
import { InvoiceTypeBadge, PaymentStatusBadge } from "./SalesBadges"

// Matches the design's 7-column table grid (design-template-decoded.html line 1044):
// Invoice / Customer / Items / Type / Amount / Method / Status.
const TABLE_GRID_COLS = "grid-cols-[1fr_1.4fr_1.6fr_0.8fr_1fr_0.9fr_1fr]"

const PAYMENT_METHOD_KEY: Record<Enums<"payment_method">, string> = {
  cash: "sales.payment.cash",
  transfer: "sales.payment.transfer",
  upi: "sales.payment.upi",
}

type TypeFilter = "all" | Enums<"invoice_type">

function startOfDay(d: Date) {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate())
}

export function SalesListPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data, isLoading, isError, refetch } = useInvoicesList(orgId)
  const { data: quotationsData } = useQuotationsList(orgId)
  const rows = useMemo(() => data ?? [], [data])
  const quotations = useMemo(() => quotationsData ?? [], [quotationsData])

  const [typeFilter, setTypeFilter] = useState<TypeFilter>("all")

  // All figures below are derived from the real invoices/quotations already
  // fetched for this org — nothing here is mock data. The design's "Today's
  // Sales / Product Sales / Avg Ticket Value / Quotation → Sale" KPI row is
  // reproduced with honest equivalents: today vs. yesterday and this-month
  // vs. last-month deltas are computed from actual created_at timestamps,
  // and the conversion rate uses the same converted/(converted+lost) formula
  // QuotationsListPage already established.
  const stats = useMemo(() => {
    const now = new Date()
    const todayStart = startOfDay(now)
    const yesterdayStart = new Date(todayStart)
    yesterdayStart.setDate(yesterdayStart.getDate() - 1)
    const monthStart = new Date(now.getFullYear(), now.getMonth(), 1)
    const lastMonthStart = new Date(now.getFullYear(), now.getMonth() - 1, 1)

    let todayTotal = 0
    let yesterdayTotal = 0
    let monthTotal = 0
    let monthCount = 0
    let monthProductTotal = 0
    let lastMonthTotal = 0
    let lastMonthCount = 0

    for (const inv of rows) {
      const created = new Date(inv.created_at)
      if (created >= todayStart) todayTotal += inv.total
      else if (created >= yesterdayStart) yesterdayTotal += inv.total

      if (created >= monthStart) {
        monthTotal += inv.total
        monthCount += 1
        if (inv.type === "product") monthProductTotal += inv.total
      } else if (created >= lastMonthStart) {
        lastMonthTotal += inv.total
        lastMonthCount += 1
      }
    }

    const avgTicket = monthCount > 0 ? monthTotal / monthCount : 0
    const lastAvgTicket = lastMonthCount > 0 ? lastMonthTotal / lastMonthCount : 0
    const avgTicketDeltaPct = lastAvgTicket > 0 ? Math.round(((avgTicket - lastAvgTicket) / lastAvgTicket) * 1000) / 10 : null
    const vsYesterdayPct = yesterdayTotal > 0 ? Math.round(((todayTotal - yesterdayTotal) / yesterdayTotal) * 1000) / 10 : null
    const productPct = monthTotal > 0 ? Math.round((monthProductTotal / monthTotal) * 100) : 0

    const openQuotations = quotations.filter((q) => q.status === "open").length
    const convertedQuotations = quotations.filter((q) => q.status === "converted").length
    const lostQuotations = quotations.filter((q) => q.status === "lost").length
    const decidedQuotations = convertedQuotations + lostQuotations
    const conversionRate = decidedQuotations > 0 ? Math.round((convertedQuotations / decidedQuotations) * 100) : 0

    return {
      todayTotal,
      vsYesterdayPct,
      monthTotal,
      monthCount,
      monthProductTotal,
      productPct,
      avgTicket,
      avgTicketDeltaPct,
      openQuotations,
      convertedQuotations,
      decidedQuotations,
      conversionRate,
    }
  }, [rows, quotations])

  const visibleRows = useMemo(
    () => (typeFilter === "all" ? rows : rows.filter((inv) => inv.type === typeFilter)),
    [rows, typeFilter]
  )

  return (
    <div className="space-y-4 pt-2">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold text-text">{t("sales.list.title")}</h1>
          <p className="text-sm font-medium text-text-muted">
            {isLoading || isError
              ? t("sales.list.subtitle")
              : t("sales.list.stats", { amount: formatCurrency(stats.monthTotal), count: stats.monthCount, quotationsOpen: stats.openQuotations })}
          </p>
        </div>
        <div className="flex items-center gap-2.5">
          <Button variant="outline" onClick={() => navigate("/admin/quotations/new")}>
            {t("sales.list.newQuotationButton")}
          </Button>
          <Button variant="default" onClick={() => navigate("/admin/sales/new")}>
            <Plus className="size-4" />
            {t("sales.list.newSaleButton")}
          </Button>
        </div>
      </div>

      <div className="grid grid-cols-1 gap-4.5 sm:grid-cols-2 lg:grid-cols-4">
        <div className="relative flex flex-col gap-4 overflow-hidden rounded-card bg-gradient-to-br from-accent to-[#FF7E47] p-5.5 text-white shadow-[0_14px_32px_-16px_rgba(245,97,44,0.65)]">
          <div className="absolute -right-7.5 -top-7.5 size-30 rounded-full bg-white/10" />
          <span className="relative text-[13px] font-semibold text-white/90">{t("sales.list.kpi.todaySales")}</span>
          {isLoading ? (
            <Skeleton className="relative h-8 w-28 bg-white/25" />
          ) : (
            <div className="relative text-[30px] font-extrabold tabular-nums leading-none tracking-tight">
              {isError ? "—" : formatCurrency(stats.todayTotal)}
            </div>
          )}
          {isLoading ? (
            <Skeleton className="relative h-5 w-32 bg-white/25" />
          ) : (
            <span className="relative inline-flex w-fit items-center gap-1 rounded-full bg-white/25 px-2.5 py-1 text-xs font-bold">
              {isError
                ? t("sales.list.error.loadFailed")
                : stats.vsYesterdayPct === null
                ? stats.todayTotal > 0
                  ? t("sales.list.kpi.firstSaleToday")
                  : t("sales.list.kpi.noSalesToday")
                : `${stats.vsYesterdayPct >= 0 ? "▲" : "▼"} ${Math.abs(stats.vsYesterdayPct)}% ${t("sales.list.kpi.vsYesterday")}`}
            </span>
          )}
        </div>

        <SalesKpiCard
          label={t("sales.list.kpi.productSales")}
          loading={isLoading}
          value={isError ? "—" : formatCurrency(stats.monthProductTotal)}
          note={
            isError ? (
              <span className="text-xs font-semibold text-danger">{t("sales.list.error.loadFailed")}</span>
            ) : (
              <span className="text-xs font-semibold text-text-muted">{t("sales.list.kpi.ofRevenue", { pct: stats.productPct })}</span>
            )
          }
        />

        <SalesKpiCard
          label={t("sales.list.kpi.avgTicket")}
          loading={isLoading}
          value={isError ? "—" : formatCurrency(stats.avgTicket)}
          note={
            isError ? (
              <span className="text-xs font-semibold text-danger">{t("sales.list.error.loadFailed")}</span>
            ) : stats.avgTicketDeltaPct === null ? (
              <span className="text-xs font-semibold text-text-muted">{t("sales.list.kpi.invoicesThisMonth", { count: stats.monthCount })}</span>
            ) : (
              <span
                className={cn(
                  "inline-flex w-fit items-center gap-1 rounded-full px-2.5 py-1 text-xs font-bold",
                  stats.avgTicketDeltaPct >= 0 ? "bg-success/10 text-success" : "bg-danger/10 text-danger"
                )}
              >
                {stats.avgTicketDeltaPct >= 0 ? "▲" : "▼"} {Math.abs(stats.avgTicketDeltaPct)}%
              </span>
            )
          }
        />

        <SalesKpiCard
          label={t("sales.list.kpi.quotationToSale")}
          loading={isLoading}
          value={isError ? "—" : `${stats.conversionRate}%`}
          note={
            isError ? (
              <span className="text-xs font-semibold text-danger">{t("sales.list.error.loadFailed")}</span>
            ) : (
              <span className="text-xs font-semibold text-text-muted">
                {t("sales.list.kpi.convertedOf", { converted: stats.convertedQuotations, decided: stats.decidedQuotations })}
              </span>
            )
          }
        />
      </div>

      <div className="overflow-hidden rounded-card border border-border bg-surface shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
        <div className="flex items-center justify-between px-5.5 pb-3.5 pt-5">
          <h3 className="text-[17px] font-bold tracking-tight text-text">{t("sales.list.table.heading")}</h3>
          <span className="text-xs font-semibold text-text-muted">{t("sales.list.table.countThisMonth", { count: stats.monthCount })}</span>
        </div>

        <div className="flex flex-wrap gap-2 px-5.5 pb-3.5">
          <FilterChip active={typeFilter === "all"} onClick={() => setTypeFilter("all")}>
            {t("sales.list.filters.all")}
          </FilterChip>
          <FilterChip active={typeFilter === "product"} onClick={() => setTypeFilter(typeFilter === "product" ? "all" : "product")}>
            {t("sales.list.filters.product")}
          </FilterChip>
          <FilterChip active={typeFilter === "spare"} onClick={() => setTypeFilter(typeFilter === "spare" ? "all" : "spare")}>
            {t("sales.list.filters.spare")}
          </FilterChip>
          <FilterChip active={typeFilter === "amc"} onClick={() => setTypeFilter(typeFilter === "amc" ? "all" : "amc")}>
            {t("sales.list.filters.amc")}
          </FilterChip>
        </div>

        <div className={cn("grid items-center border-y border-border bg-surface-alt px-5.5 py-2.5", TABLE_GRID_COLS)}>
          {[
            t("sales.list.table.invoice"),
            t("sales.list.table.customer"),
            t("sales.list.table.items"),
            t("sales.list.table.type"),
            t("sales.list.table.amount"),
            t("sales.list.table.method"),
            t("sales.list.table.status"),
          ].map((h) => (
            <span key={h} className="text-[11px] font-semibold uppercase tracking-wide text-text-muted">
              {h}
            </span>
          ))}
        </div>

        {isError ? (
          <div className="flex flex-col items-center gap-3 py-12 text-center">
            <TriangleAlert className="size-6 text-danger" />
            <p className="text-sm text-text-muted">{t("sales.list.error.loadFailed")}</p>
            <Button variant="outline" size="sm" onClick={() => refetch()}>
              {t("common.retry")}
            </Button>
          </div>
        ) : isLoading ? (
          Array.from({ length: 6 }).map((_, i) => (
            <div key={i} className={cn("grid items-center border-b border-border px-5.5 py-3.5", TABLE_GRID_COLS)}>
              {Array.from({ length: 7 }).map((_, j) => (
                <Skeleton key={j} className="h-4 w-3/4 max-w-32" />
              ))}
            </div>
          ))
        ) : visibleRows.length === 0 ? (
          <div className="flex flex-col items-center gap-3 py-12 text-center">
            <span className="flex size-12 items-center justify-center rounded-full bg-surface-alt text-text-muted">
              <Inbox className="size-6" />
            </span>
            <h2 className="text-lg font-semibold text-text">{t("sales.list.empty.title")}</h2>
            <p className="max-w-xs text-sm text-text-muted">{t("sales.list.empty.subtitle")}</p>
            <Button variant="accent" onClick={() => navigate("/admin/sales/new")}>
              {t("sales.list.newSaleButton")}
            </Button>
          </div>
        ) : (
          visibleRows.map((inv) => (
            <div
              key={inv.id}
              onClick={() => navigate(`/admin/sales/invoices/${inv.id}`)}
              role="button"
              tabIndex={0}
              onKeyDown={(e) => {
                if (e.key === "Enter" || e.key === " ") {
                  e.preventDefault()
                  navigate(`/admin/sales/invoices/${inv.id}`)
                }
              }}
              className={cn(
                "grid cursor-pointer items-center border-b border-border px-5.5 py-3.5 outline-none last:border-b-0 hover:bg-surface-alt focus-visible:ring-3 focus-visible:ring-ring/50 focus-visible:ring-inset",
                TABLE_GRID_COLS
              )}
            >
              <span className="text-xs font-bold tabular-nums text-text">#{inv.id.slice(0, 8)}</span>
              <span className="text-[13px] font-semibold text-text">{inv.customers?.name ?? "—"}</span>
              <span className="truncate pr-2 text-[13px] font-medium text-text-muted">{inv.itemsSummary}</span>
              <span>
                <InvoiceTypeBadge type={inv.type} />
              </span>
              <span className="text-[13px] font-bold tabular-nums text-text">{formatCurrency(inv.total)}</span>
              <span className="text-[13px] font-medium text-text-muted">{inv.payment_method ? t(PAYMENT_METHOD_KEY[inv.payment_method]) : "—"}</span>
              <span className="flex flex-col items-start gap-0.5">
                <PaymentStatusBadge status={inv.payment_status} />
                {inv.payment_status !== "paid" ? (
                  <span className="text-[11px] font-medium text-warning">
                    {t("sales.list.balanceDue", { amount: formatCurrency(Math.max(0, inv.total - inv.amount_paid)) })}
                  </span>
                ) : null}
              </span>
            </div>
          ))
        )}
      </div>
    </div>
  )
}

function SalesKpiCard({ label, value, note, loading = false }: { label: string; value: ReactNode; note: ReactNode; loading?: boolean }) {
  if (loading) {
    return (
      <div className="flex flex-col gap-4 rounded-card border border-border bg-surface p-5.5 shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
        <Skeleton className="h-4 w-24" />
        <Skeleton className="h-8 w-28" />
        <Skeleton className="h-4 w-20" />
      </div>
    )
  }

  return (
    <div className="flex flex-col gap-4 rounded-card border border-border bg-surface p-5.5 shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
      <span className="text-[13px] font-semibold text-text-muted">{label}</span>
      <div className="text-[29px] font-extrabold tabular-nums leading-none tracking-tight text-text">{value}</div>
      {note}
    </div>
  )
}

function FilterChip({ active, onClick, children }: { active: boolean; onClick: () => void; children: ReactNode }) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={active}
      className={cn(
        "rounded-full border border-border px-[15px] py-2 text-xs font-bold outline-none transition-colors focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/50",
        active ? "bg-ink text-white" : "bg-surface text-text"
      )}
    >
      {children}
    </button>
  )
}
