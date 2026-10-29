import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { useSearchParams } from "react-router-dom"
import { Inbox, TriangleAlert } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Skeleton } from "@/components/ui/skeleton"
import { StatusDot } from "@/components/shared/StatusDot"
import { SegButton } from "@/components/shared/SegButton"
import { useProfile } from "@/hooks/useProfile"
import {
  useLifecycleOverview,
  type LifecycleExpiringProductRow,
  type LifecyclePartScheduleRow,
  type LifecycleStatusFilter,
} from "@/hooks/useLifecycleOverview"
import { lifecycleStatusTone } from "@/lib/lifecycle-status"
import { formatDate } from "@/lib/formatDate"
import { cn } from "@/lib/utils"

type LifecycleTab = LifecycleStatusFilter | "lifetime_expiring_90d"
const TABS: LifecycleTab[] = ["due_soon", "due", "overdue", "lifetime_expiring_90d"]

const SCHEDULE_GRID = "grid-cols-[minmax(140px,1.3fr)_minmax(110px,1.3fr)_minmax(110px,1fr)_minmax(90px,0.9fr)_minmax(90px,1fr)]"
const EXPIRY_GRID = "grid-cols-[minmax(140px,1.3fr)_minmax(110px,1.3fr)_minmax(90px,0.9fr)_minmax(90px,1fr)]"

function isLifecycleTab(value: string | null): value is LifecycleTab {
  return !!value && (TABS as string[]).includes(value)
}

/**
 * Filtered list page the "Product Lifecycle" widget's 4 numbers link into
 * (W4 drop). Three tabs read `customer_part_schedules` by status; the fourth
 * ("Lifetime expiring") reads `customer_installed_products` directly for
 * products whose `lifetime_expiry_date` falls in the next 90 days — a
 * separate list, not a part schedule.
 */
export function LifecycleOverviewPage() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id
  const [searchParams, setSearchParams] = useSearchParams()
  const initialTab = searchParams.get("status")
  const [tab, setTab] = useState<LifecycleTab>(isLifecycleTab(initialTab) ? initialTab : "due_soon")
  const [search, setSearch] = useState("")

  const { data, isLoading, isError, refetch } = useLifecycleOverview(orgId, tab)

  const changeTab = (next: LifecycleTab) => {
    setTab(next)
    setSearchParams((prev) => {
      const params = new URLSearchParams(prev)
      params.set("status", next)
      return params
    })
  }

  const searchTerm = search.trim().toLowerCase()
  const isLifetimeTab = tab === "lifetime_expiring_90d"

  const filteredSchedules = useMemo(() => {
    if (isLifetimeTab) return []
    return ((data ?? []) as LifecyclePartScheduleRow[]).filter((row) => {
      if (!searchTerm) return true
      const customerName = (row.customer_installed_products?.customers?.name ?? "").toLowerCase()
      const productName = (row.customer_installed_products?.products?.name ?? "").toLowerCase()
      const label = (row.label ?? "").toLowerCase()
      return customerName.includes(searchTerm) || productName.includes(searchTerm) || label.includes(searchTerm)
    })
  }, [data, isLifetimeTab, searchTerm])

  const filteredExpiring = useMemo(() => {
    if (!isLifetimeTab) return []
    return ((data ?? []) as LifecycleExpiringProductRow[]).filter((row) => {
      if (!searchTerm) return true
      const customerName = (row.customers?.name ?? "").toLowerCase()
      const productName = (row.products?.name ?? "").toLowerCase()
      return customerName.includes(searchTerm) || productName.includes(searchTerm)
    })
  }, [data, isLifetimeTab, searchTerm])

  const recordCount = isLifetimeTab ? filteredExpiring.length : filteredSchedules.length

  return (
    <div className="space-y-4 pt-2">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold text-text">{t("lifecycleDashboard.overview.title")}</h1>
          <p className="text-sm font-medium text-text-muted">{t("lifecycleDashboard.overview.subtitle")}</p>
        </div>
      </div>

      <div className="overflow-hidden rounded-card border border-border bg-surface shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
        <div className="flex flex-wrap items-center justify-between gap-2 px-[22px] py-4">
          <div className="flex flex-wrap gap-[3px] rounded-full border border-border bg-surface-alt p-1">
            {TABS.map((value) => (
              <SegButton key={value} active={tab === value} onClick={() => changeTab(value)}>
                {t(`lifecycleDashboard.overview.tab.${value}`)}
              </SegButton>
            ))}
          </div>
          <div className="flex items-center gap-2.5">
            <div className="flex w-56 items-center gap-2.25 rounded-full border border-border bg-surface-alt px-3.5 py-2">
              <input
                type="text"
                value={search}
                onChange={(e) => setSearch(e.target.value)}
                placeholder={t("lifecycleDashboard.overview.search")}
                className="w-full bg-transparent text-xs font-medium text-text outline-none placeholder:text-text-muted"
              />
            </div>
            <span className="text-xs font-semibold text-text-muted">
              {t("lifecycleDashboard.overview.recordCount", { count: recordCount })}
            </span>
          </div>
        </div>

        {isLifetimeTab ? (
          <ExpiringTable rows={filteredExpiring} loading={isLoading} error={isError} onRetry={() => refetch()} />
        ) : (
          <ScheduleTable rows={filteredSchedules} loading={isLoading} error={isError} onRetry={() => refetch()} />
        )}
      </div>
    </div>
  )
}

function ScheduleTable({
  rows,
  loading,
  error,
  onRetry,
}: {
  rows: LifecyclePartScheduleRow[]
  loading: boolean
  error: boolean
  onRetry: () => void
}) {
  const { t } = useTranslation()
  const headers = [
    t("lifecycleDashboard.overview.customer"),
    t("lifecycleDashboard.overview.product"),
    t("lifecycleDashboard.overview.part"),
    t("lifecycleDashboard.overview.dueDate"),
    t("lifecycleDashboard.overview.status"),
  ]

  return (
    <div className="overflow-x-auto">
      <div className={cn("grid items-center border-y border-border bg-surface-alt px-[22px] py-[10px]", SCHEDULE_GRID)}>
        {headers.map((h) => (
          <span key={h} className="text-[11px] font-semibold uppercase tracking-wide text-text-muted">
            {h}
          </span>
        ))}
      </div>

      {error ? (
        <div className="flex flex-col items-center gap-3 py-12 text-center">
          <TriangleAlert className="size-6 text-danger" />
          <p className="text-sm text-text-muted">{t("lifecycleDashboard.overview.loadFailed")}</p>
          <Button variant="outline" size="sm" onClick={onRetry}>
            {t("common.retry")}
          </Button>
        </div>
      ) : loading ? (
        Array.from({ length: 6 }).map((_, i) => (
          <div key={i} className={cn("grid items-center border-b border-border px-[22px] py-[14px]", SCHEDULE_GRID)}>
            {headers.map((h) => (
              <Skeleton key={h} className="h-4 w-3/4 max-w-32" />
            ))}
          </div>
        ))
      ) : rows.length === 0 ? (
        <div className="flex flex-col items-center gap-2 py-12 text-center">
          <Inbox className="size-6 text-text-muted" />
          <p className="text-sm text-text-muted">{t("lifecycleDashboard.overview.empty")}</p>
        </div>
      ) : (
        rows.map((row) => {
          const installed = row.customer_installed_products
          return (
            <div key={row.id} className={cn("grid items-center border-b border-border px-[22px] py-[14px] last:border-b-0", SCHEDULE_GRID)}>
              <div className="leading-tight">
                <div className="text-[13px] font-semibold text-text">{installed?.customers?.name ?? "—"}</div>
              </div>
              <span className="text-[13px] font-medium text-text">{installed?.products?.name ?? "—"}</span>
              <span className="text-[13px] font-medium text-text">{row.label ?? "—"}</span>
              <span className="text-[13px] font-medium tabular-nums text-text">{formatDate(row.next_due_date)}</span>
              <StatusDot tone={lifecycleStatusTone(row.status)} label={t(`lifecycleDashboard.overview.statusLabel.${row.status}`, row.status)} />
            </div>
          )
        })
      )}
    </div>
  )
}

function ExpiringTable({
  rows,
  loading,
  error,
  onRetry,
}: {
  rows: LifecycleExpiringProductRow[]
  loading: boolean
  error: boolean
  onRetry: () => void
}) {
  const { t } = useTranslation()
  const headers = [
    t("lifecycleDashboard.overview.customer"),
    t("lifecycleDashboard.overview.product"),
    t("lifecycleDashboard.overview.lifetimeExpiry"),
    t("lifecycleDashboard.overview.status"),
  ]

  return (
    <div className="overflow-x-auto">
      <div className={cn("grid items-center border-y border-border bg-surface-alt px-[22px] py-[10px]", EXPIRY_GRID)}>
        {headers.map((h) => (
          <span key={h} className="text-[11px] font-semibold uppercase tracking-wide text-text-muted">
            {h}
          </span>
        ))}
      </div>

      {error ? (
        <div className="flex flex-col items-center gap-3 py-12 text-center">
          <TriangleAlert className="size-6 text-danger" />
          <p className="text-sm text-text-muted">{t("lifecycleDashboard.overview.loadFailed")}</p>
          <Button variant="outline" size="sm" onClick={onRetry}>
            {t("common.retry")}
          </Button>
        </div>
      ) : loading ? (
        Array.from({ length: 6 }).map((_, i) => (
          <div key={i} className={cn("grid items-center border-b border-border px-[22px] py-[14px]", EXPIRY_GRID)}>
            {headers.map((h) => (
              <Skeleton key={h} className="h-4 w-3/4 max-w-32" />
            ))}
          </div>
        ))
      ) : rows.length === 0 ? (
        <div className="flex flex-col items-center gap-2 py-12 text-center">
          <Inbox className="size-6 text-text-muted" />
          <p className="text-sm text-text-muted">{t("lifecycleDashboard.overview.emptyExpiring")}</p>
        </div>
      ) : (
        rows.map((row) => (
          <div key={row.id} className={cn("grid items-center border-b border-border px-[22px] py-[14px] last:border-b-0", EXPIRY_GRID)}>
            <div className="leading-tight">
              <div className="text-[13px] font-semibold text-text">{row.customers?.name ?? "—"}</div>
            </div>
            <span className="text-[13px] font-medium text-text">{row.products?.name ?? "—"}</span>
            <span className="text-[13px] font-medium tabular-nums text-text">{formatDate(row.lifetime_expiry_date)}</span>
            <StatusDot tone="warning" label={t("lifecycleDashboard.overview.statusLabel.lifetime_expiring_90d")} />
          </div>
        ))
      )}
    </div>
  )
}
