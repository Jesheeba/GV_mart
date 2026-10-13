import { useMemo, useState, type ReactNode } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { Inbox, Plus, Search, TriangleAlert } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Skeleton } from "@/components/ui/skeleton"
import { useProfile } from "@/hooks/useProfile"
import { useInvoicesList } from "@/hooks/useSales"
import { useQuotationsList } from "@/hooks/useQuotations"
import { useSalesServiceReport } from "@/hooks/useReports"
import { getIstNow } from "@/lib/ist"
import { currentIstMonth, monthRange, previousDay } from "@/lib/salesKpi"
import type { SalesKindStats } from "@/services/reports"
import { formatCurrency } from "@/lib/sale-calc"
import { cn } from "@/lib/utils"
import type { Enums } from "@/types/database"
import { InvoiceTypeBadge, PaymentStatusBadge } from "./SalesBadges"

// Matches the design's 7-column table grid (design-template-decoded.html line 1044):
// Invoice / Customer / Items / Type / Amount / Method / Status.
const TABLE_GRID_COLS =
  "grid-cols-[minmax(90px,1fr)_minmax(130px,1.4fr)_minmax(140px,1.6fr)_minmax(70px,0.8fr)_minmax(90px,1fr)_minmax(90px,0.9fr)_minmax(100px,1fr)]"

const PAYMENT_METHOD_KEY: Record<Enums<"payment_method">, string> = {
  cash: "sales.payment.cash",
  transfer: "sales.payment.transfer",
  upi: "sales.payment.upi",
}

type TypeFilter = "all" | Enums<"invoice_type">

export function SalesListPage() {
  const { t, i18n } = useTranslation()
  const navigate = useNavigate()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data, isLoading, isError, refetch } = useInvoicesList(orgId)
  const { data: quotationsData } = useQuotationsList(orgId)
  const rows = useMemo(() => data ?? [], [data])
  const quotations = useMemo(() => quotationsData ?? [], [quotationsData])

  const [typeFilter, setTypeFilter] = useState<TypeFilter>("all")
  const [search, setSearch] = useState("")

  // Tiles come from report_sales_service (the same numbers as Reports): IST day and month windows, the report's invoice set
  // (flagged test customers excluded) and no 1,000-row cap. The type chips and the search below narrow the TABLE only.
  const todayIst = getIstNow().date
  const thisMonth = currentIstMonth()
  const [month, setMonth] = useState(thisMonth)
  const todayRange = useMemo(() => ({ from: todayIst, to: todayIst }), [todayIst])
  const yesterdayRange = useMemo(() => ({ from: previousDay(todayIst), to: previousDay(todayIst) }), [todayIst])
  const monthRng = useMemo(() => monthRange(month), [month])
  const thisMonthRng = useMemo(() => monthRange(thisMonth), [thisMonth])
  const todayQ = useSalesServiceReport(orgId, todayRange)
  const yesterdayQ = useSalesServiceReport(orgId, yesterdayRange)
  const monthQ = useSalesServiceReport(orgId, monthRng)
  const thisMonthQ = useSalesServiceReport(orgId, thisMonthRng)

  const stats = useMemo(() => {
    const todayTotal = todayQ.data?.totalRevenue ?? 0
    const todayCollected = todayQ.data?.totalCollected ?? 0
    const yesterdayTotal = yesterdayQ.data?.totalRevenue ?? 0
    const vsYesterdayPct = yesterdayTotal > 0 ? Math.round(((todayTotal - yesterdayTotal) / yesterdayTotal) * 1000) / 10 : null
    const monthCount = (thisMonthQ.data?.revenueByType ?? []).reduce((n, r) => n + r.count, 0)
    const monthTotal = thisMonthQ.data?.totalRevenue ?? 0

    const openQuotations = quotations.filter((q) => q.status === "open").length
    const convertedQuotations = quotations.filter((q) => q.status === "converted").length
    const lostQuotations = quotations.filter((q) => q.status === "lost").length
    const decidedQuotations = convertedQuotations + lostQuotations
    const conversionRate = decidedQuotations > 0 ? Math.round((convertedQuotations / decidedQuotations) * 100) : 0

    return { todayTotal, todayCollected, vsYesterdayPct, monthTotal, monthCount, openQuotations, convertedQuotations, decidedQuotations, conversionRate }
  }, [todayQ.data, yesterdayQ.data, thisMonthQ.data, quotations])
  const monthLabel = new Date(`${month}-01T00:00:00Z`).toLocaleDateString(i18n.language.startsWith("ta") ? "ta-IN" : "en-IN", {
    month: "short",
    year: "numeric",
    timeZone: "UTC",
  })
  const kpiLoading = todayQ.isLoading || monthQ.isLoading
  const kpiError = todayQ.isError || monthQ.isError
  const kindUnavailable = !kpiLoading && !kpiError && !!todayQ.data && !todayQ.data.byKind

  const searchTerm = search.trim().toLowerCase()
  const visibleRows = useMemo(
    () =>
      rows
        .filter((inv) => typeFilter === "all" || inv.type === typeFilter)
        .filter(
          (inv) =>
            !searchTerm ||
            (inv.customers?.name ?? "").toLowerCase().includes(searchTerm) ||
            (inv.customers?.mobile ?? "").includes(searchTerm) ||
            inv.itemsSummary.toLowerCase().includes(searchTerm)
        ),
    [rows, typeFilter, searchTerm]
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

      <div className="flex flex-wrap items-center justify-end gap-2">
        <label htmlFor="sales-kpi-month" className="text-xs font-semibold text-text-muted">
          {t("sales.list.kpi.monthPicker")}
        </label>
        <input
          id="sales-kpi-month"
          type="month"
          value={month}
          max={thisMonth}
          onChange={(e) => e.target.value && setMonth(e.target.value)}
          className="h-9 rounded-lg border border-border bg-surface px-2.5 text-sm font-medium text-text outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/50"
        />
      </div>

      <div className="grid grid-cols-1 gap-4.5 sm:grid-cols-2 xl:grid-cols-5">
        <div className="relative flex flex-col gap-4 overflow-hidden rounded-card bg-gradient-to-br from-accent to-[#FF7E47] p-5.5 text-white shadow-[0_14px_32px_-16px_rgba(245,97,44,0.65)]">
          <div className="absolute -right-7.5 -top-7.5 size-30 rounded-full bg-white/10" />
          <span className="relative flex flex-wrap items-baseline gap-x-2 text-[13px] font-semibold text-white/90">
            {t("sales.list.kpi.todaySales")}
            <span className="rounded-full bg-white/20 px-2 py-0.5 text-[11px] font-bold">{t("sales.list.kpi.allTypes")}</span>
          </span>
          {kpiLoading ? (
            <Skeleton className="relative h-8 w-28 bg-white/25" />
          ) : (
            <div className="relative text-[30px] font-extrabold tabular-nums leading-none tracking-tight">
              {kpiError ? "—" : formatCurrency(stats.todayTotal)}
            </div>
          )}
          {kpiLoading ? (
            <Skeleton className="relative h-5 w-32 bg-white/25" />
          ) : (
            <div className="relative flex flex-wrap items-center gap-2">
              <span className="inline-flex w-fit items-center gap-1 rounded-full bg-white/25 px-2.5 py-1 text-xs font-bold">
                {kpiError
                  ? t("sales.list.error.loadFailed")
                  : stats.vsYesterdayPct === null
                  ? stats.todayTotal > 0
                    ? t("sales.list.kpi.firstSaleToday")
                    : t("sales.list.kpi.noSalesToday")
                  : `${stats.vsYesterdayPct >= 0 ? "▲" : "▼"} ${Math.abs(stats.vsYesterdayPct)}% ${t("sales.list.kpi.vsYesterday")}`}
              </span>
              {!kpiError ? (
                <span className="text-xs font-semibold text-white/90">
                  {t("reports.collectedLabel")}: {formatCurrency(stats.todayCollected)}
                </span>
              ) : null}
            </div>
          )}
        </div>

        <KindKpiCard
          label={t("sales.list.kpi.kind.product")}
          loading={kpiLoading}
          error={kpiError}
          today={todayQ.data?.byKind?.product}
          month={monthQ.data?.byKind?.product}
          unavailable={kindUnavailable}
          monthLabel={monthLabel}
        />

        <KindKpiCard
          label={t("sales.list.kpi.kind.spare")}
          loading={kpiLoading}
          error={kpiError}
          today={todayQ.data?.byKind?.spareCounter}
          month={monthQ.data?.byKind?.spareCounter}
          unavailable={kindUnavailable}
          monthLabel={monthLabel}
          serviceNote={monthQ.data?.byKind?.service}
        />

        <KindKpiCard
          label={t("sales.list.kpi.kind.amc")}
          loading={kpiLoading}
          error={kpiError}
          today={todayQ.data?.byKind?.amc}
          month={monthQ.data?.byKind?.amc}
          unavailable={kindUnavailable}
          monthLabel={monthLabel}
        />

        <SalesKpiCard
          label={t("sales.list.kpi.quotationToSale")}
          loading={kpiLoading}
          value={kpiError ? "—" : `${stats.conversionRate}%`}
          note={
            kpiError ? (
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

        <div className="flex flex-wrap items-center justify-between gap-2 px-5.5 pb-3.5">
          <div className="flex flex-wrap gap-2">
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
          <div className="flex w-64 items-center gap-2.25 rounded-full border border-border bg-surface-alt px-3.5 py-2">
            <Search className="size-3.75 shrink-0 text-text-muted" />
            <input
              type="text"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder={t("sales.list.search")}
              className="w-full bg-transparent text-xs font-medium text-text outline-none placeholder:text-text-muted"
            />
          </div>
        </div>

        <div className="overflow-x-auto">
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
    </div>
  )
}

/** Product / Spares / AMC tile: today's invoiced value with invoice count and average ticket, then the selected month the same way. */
function KindKpiCard({
  label,
  today,
  month,
  monthLabel,
  loading,
  error,
  unavailable,
  serviceNote,
}: {
  label: string
  today: SalesKindStats | undefined
  month: SalesKindStats | undefined
  monthLabel: string
  loading: boolean
  error: boolean
  /** report_sales_service has no by_kind yet (migration not applied): show dashes, never wrong numbers. */
  unavailable: boolean
  /** Spares only: technician service invoices, shown beside (never inside) the spares figures. */
  serviceNote?: SalesKindStats
}) {
  const { t } = useTranslation()
  const dash = "—"
  const avg = (k: SalesKindStats | undefined) => (k && k.avgTicket != null ? formatCurrency(k.avgTicket) : dash)
  const note = error ? (
    <span className="text-xs font-semibold text-danger">{t("sales.list.error.loadFailed")}</span>
  ) : unavailable ? (
    <span className="text-xs font-semibold text-text-muted">{t("sales.list.kpi.unavailable")}</span>
  ) : (
    <div className="flex flex-col gap-2 text-xs font-semibold text-text-muted">
      <div>
        {t("sales.list.kpi.invoiceCount", { count: today?.count ?? 0 })} · {t("sales.list.kpi.avgTicketShort", { amount: avg(today) })}
        {today && today.count > 0 ? ` · ${t("reports.collectedLabel")}: ${formatCurrency(today.collected)}` : ""}
      </div>
      <div className="border-t border-border pt-2">
        <span className="text-text">{monthLabel}</span>: {formatCurrency(month?.total ?? 0)} · {t("sales.list.kpi.invoiceCount", { count: month?.count ?? 0 })} ·{" "}
        {t("sales.list.kpi.avgTicketShort", { amount: avg(month) })}
      </div>
      {serviceNote ? (
        <div className="font-medium">{t("sales.list.kpi.serviceNote", { count: serviceNote.count, amount: formatCurrency(serviceNote.total) })}</div>
      ) : null}
    </div>
  )
  return (
    <SalesKpiCard
      label={`${label} · ${t("sales.list.kpi.today")}`}
      loading={loading}
      value={error || unavailable ? dash : formatCurrency(today?.total ?? 0)}
      note={note}
    />
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
