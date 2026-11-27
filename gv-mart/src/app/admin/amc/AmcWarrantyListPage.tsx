import { useEffect, useMemo, useState } from "react"
import { getIstNow } from "@/lib/ist"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { Inbox, Plus, Search, TriangleAlert } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Skeleton } from "@/components/ui/skeleton"
import { StatusDot } from "@/components/shared/StatusDot"
import { SegButton } from "@/components/shared/SegButton"
import { useProfile } from "@/hooks/useProfile"
import { useAmcContracts, useRefreshAmcStatuses, useWarranties } from "@/hooks/useAmc"
import { amcPlansHooks, useSettings } from "@/hooks/useMasters"
import { groupPlansByName, pricePerYearOf } from "@/lib/amc-window"
import { AMC_STATUS_TONE } from "@/lib/amc-status"
import { formatDate } from "@/lib/formatDate"
import { cn } from "@/lib/utils"
import { SellAmcPanel } from "./SellAmcPanel"
import type { AmcContractListItem, WarrantyListItem } from "@/services/amc"
import type { AmcPlanRow } from "@/services/masters"

// Tier swatch colors by plan-name group, cheapest group first (design line 1078-1090:
// Silver=#8A8A82, Gold=#F5612C, Platinum=#1A1A1A) — a presentational mapping
// keyed to real plan order, not a hardcoded plan name. Groups past the third stay dark.
const TIER_COLORS = ["#8A8A82", "#F5612C", "#1A1A1A"]
const TIER_STYLES = [
  { card: "border border-border bg-surface-alt text-text", muted: "text-text-muted", swatch: "bg-gradient-to-br from-[#C9C4BA] to-[#A8A299]" },
  { card: "bg-gradient-to-br from-accent to-[#FF7E47] text-white", muted: "text-white/85", swatch: "bg-gradient-to-br from-accent to-[#FF7E47]" },
  { card: "bg-gradient-to-br from-ink to-[#33302C] text-white", muted: "text-white/75", swatch: "bg-gradient-to-br from-ink to-[#33302C]" },
]

// Matches the design's AMC table grid (design-template-decoded.html line 1098):
// Customer / Product / Tier / Expiry / Next svc / Status.
const AMC_GRID =
  "grid-cols-[minmax(140px,1.3fr)_minmax(110px,1.5fr)_minmax(90px,0.8fr)_minmax(90px,0.9fr)_minmax(90px,0.9fr)_minmax(90px,1fr)]"
// Warranties now get proactive quarterly scheduled visits too (next_service_date
// on warranties), so the table mirrors the AMC grid's Next svc column —
// Customer / Product / Serial no / Expiry / Next svc / Status.
const WARRANTY_GRID =
  "grid-cols-[minmax(130px,1.2fr)_minmax(110px,1.4fr)_minmax(90px,0.9fr)_minmax(90px,0.85fr)_minmax(90px,0.85fr)_minmax(90px,0.9fr)]"

function warrantyStatus(expiryDate: string, windowDays: number): "active" | "due_soon" | "expired" {
  // Both sides as date-only UTC midnights: expiryDate is a plain date, and
  // "today" must be the IST date (the server compares expiry_date to the IST date).
  const diffDays = (Date.parse(expiryDate) - Date.parse(getIstNow().date)) / 86_400_000
  if (diffDays < 0) return "expired"
  if (diffDays <= windowDays) return "due_soon"
  return "active"
}

// Compact ₹ formatting for the header stat line (design: "₹1.6L renewal at
// risk") — same ad hoc lakh-compaction OwnerDashboard.tsx already uses inline,
// generalized so small real amounts don't render as "₹0.0L".
function formatCompact(n: number) {
  if (n >= 1_00_000) return `₹${(n / 1_00_000).toFixed(1)}L`
  if (n >= 1_000) return `₹${(n / 1_000).toFixed(1)}k`
  return `₹${n.toLocaleString("en-IN")}`
}

export function AmcWarrantyListPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id
  const [showSellAmc, setShowSellAmc] = useState(false)
  const [segment, setSegment] = useState<"amc" | "warranty">("amc")
  const [search, setSearch] = useState("")

  const { data: settings } = useSettings(orgId)
  const windowDays = settings ? settings.amc_book_window_days : 15

  const contracts = useAmcContracts(orgId)
  const warranties = useWarranties(orgId)
  const { data: plans, isLoading: plansLoading } = amcPlansHooks.useList(orgId)
  const refreshStatuses = useRefreshAmcStatuses(orgId)

  useEffect(() => {
    if (orgId) refreshStatuses.mutate()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [orgId])

  const warrantyRows = useMemo(
    () => (warranties.data ?? []).map((w) => ({ ...w, computedStatus: warrantyStatus(w.expiry_date, windowDays) })),
    [warranties.data, windowDays]
  )

  // Plan tier cards: sort by price so the cheapest plan lands in the
  // "silver" visual slot and the priciest in the "platinum" slot, echoing
  // the design's tiering — every number rendered is computed below from
  // real amc_plans / amc_contracts rows, nothing is hardcoded.
  const sortedPlans = useMemo(() => [...(plans ?? [])].sort((a, b) => a.price - b.price), [plans])

  const activeCountByPlan = useMemo(() => {
    const map = new Map<string, number>()
    for (const c of contracts.data ?? []) {
      if (c.status !== "active") continue
      map.set(c.plan_id, (map.get(c.plan_id) ?? 0) + 1)
    }
    return map
  }, [contracts.data])

  const mostPopularPlanId = useMemo(() => {
    if (sortedPlans.length < 2) return null
    let best: string | null = null
    let bestCount = 0
    let tie = false
    for (const p of sortedPlans) {
      const count = activeCountByPlan.get(p.id) ?? 0
      if (count > bestCount) {
        best = p.id
        bestCount = count
        tie = false
      } else if (count === bestCount && count > 0) {
        tie = true
      }
    }
    return bestCount > 0 && !tie ? best : null
  }, [sortedPlans, activeCountByPlan])

  // One column per plan name (Silver / Gold / ...), each a single colour.
  const planGroups = useMemo(
    () => groupPlansByName(sortedPlans).map((g, i) => ({ ...g, tier: Math.min(i, TIER_COLORS.length - 1) })),
    [sortedPlans]
  )
  const tierColorByPlanId = useMemo(() => {
    const map = new Map<string, string>()
    for (const g of planGroups) for (const p of g.plans) map.set(p.id, TIER_COLORS[g.tier])
    return map
  }, [planGroups])

  const searchTerm = search.trim().toLowerCase()
  const filteredContracts = useMemo(
    () =>
      (contracts.data ?? []).filter(
        (c) =>
          !searchTerm ||
          (c.customers?.name ?? "").toLowerCase().includes(searchTerm) ||
          (c.customers?.mobile ?? "").includes(searchTerm) ||
          (c.products?.name ?? "").toLowerCase().includes(searchTerm)
      ),
    [contracts.data, searchTerm]
  )
  const filteredWarrantyRows = useMemo(
    () =>
      warrantyRows.filter(
        (w) =>
          !searchTerm ||
          (w.customers?.name ?? "").toLowerCase().includes(searchTerm) ||
          (w.customers?.mobile ?? "").includes(searchTerm) ||
          (w.products?.name ?? "").toLowerCase().includes(searchTerm)
      ),
    [warrantyRows, searchTerm]
  )

  const activeContractsCount = useMemo(() => (contracts.data ?? []).filter((c) => c.status === "active").length, [contracts.data])
  const dueSoonContracts = useMemo(() => (contracts.data ?? []).filter((c) => c.status === "due_soon"), [contracts.data])
  const renewalAtRisk = useMemo(
    () => dueSoonContracts.reduce((sum, c) => sum + (c.amc_plans ? pricePerYearOf(c.amc_plans) : 0), 0),
    [dueSoonContracts]
  )

  return (
    <div className="space-y-4 pt-2">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold text-text">{t("nav.amcWarranty")}</h1>
          <p className="text-sm font-medium text-text-muted">
            {contracts.isLoading
              ? t("common.loading")
              : t("amc.list.stats", {
                  active: activeContractsCount,
                  dueSoon: dueSoonContracts.length,
                  days: windowDays,
                  atRisk: formatCompact(renewalAtRisk),
                })}
          </p>
        </div>
        <Button onClick={() => setShowSellAmc((v) => !v)}>
          <Plus className="size-4" />
          {t("amc.sellAmc.title")}
        </Button>
      </div>

      {showSellAmc ? (
        <SellAmcPanel
          onClose={() => setShowSellAmc(false)}
          onSold={() => {
            setShowSellAmc(false)
            contracts.refetch()
          }}
        />
      ) : null}

      <PlanTierCards
        groups={planGroups}
        loading={plansLoading}
        activeCountByPlan={activeCountByPlan}
        mostPopularPlanId={mostPopularPlanId}
      />

      <div className="overflow-hidden rounded-card border border-border bg-surface shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
        <div className="flex flex-wrap items-center justify-between gap-2 px-[22px] py-4">
          <div className="flex gap-[3px] rounded-full border border-border bg-surface-alt p-1">
            <SegButton active={segment === "amc"} onClick={() => setSegment("amc")}>
              {t("amc.tabs.amc")}
            </SegButton>
            <SegButton active={segment === "warranty"} onClick={() => setSegment("warranty")}>
              {t("amc.tabs.warranty")}
            </SegButton>
          </div>
          <div className="flex items-center gap-2.5">
            <div className="flex w-56 items-center gap-2.25 rounded-full border border-border bg-surface-alt px-3.5 py-2">
              <Search className="size-3.75 shrink-0 text-text-muted" />
              <input
                type="text"
                value={search}
                onChange={(e) => setSearch(e.target.value)}
                placeholder={t("amc.list.search")}
                className="w-full bg-transparent text-xs font-medium text-text outline-none placeholder:text-text-muted"
              />
            </div>
            <span className="text-xs font-semibold text-text-muted">
              {t("amc.list.recordCount", { count: segment === "amc" ? filteredContracts.length : filteredWarrantyRows.length })}
            </span>
          </div>
        </div>

        {segment === "amc" ? (
          <AmcTable
            rows={filteredContracts}
            loading={contracts.isLoading}
            error={contracts.isError ? t("amc.list.loadFailed") : null}
            onRetry={() => contracts.refetch()}
            tierColorFor={(planId) => tierColorByPlanId.get(planId) ?? "#8A8A82"}
            onRowClick={(id) => navigate(`/admin/amc/${id}`)}
          />
        ) : (
          <WarrantyTable
            rows={filteredWarrantyRows}
            loading={warranties.isLoading}
            error={warranties.isError ? t("amc.list.loadFailed") : null}
            onRetry={() => warranties.refetch()}
          />
        )}
      </div>
    </div>
  )
}

function PlanTierCards({
  groups,
  loading,
  activeCountByPlan,
  mostPopularPlanId,
}: {
  groups: { name: string; plans: AmcPlanRow[]; tier: number }[]
  loading: boolean
  activeCountByPlan: Map<string, number>
  mostPopularPlanId: string | null
}) {
  const { t } = useTranslation()
  const columns = "grid items-start gap-4 grid-cols-[repeat(auto-fit,minmax(190px,1fr))]"

  if (loading) {
    return (
      <div className={columns}>
        {[0, 1, 2].map((i) => (
          <div key={i} className="space-y-2">
            <Skeleton className="h-4 w-20" />
            <Skeleton className="h-[72px] rounded-xl" />
            <Skeleton className="h-[72px] rounded-xl" />
          </div>
        ))}
      </div>
    )
  }

  if (groups.length === 0) {
    return (
      <div className="rounded-card border border-border bg-surface-alt p-6 text-center">
        <p className="text-sm text-text-muted">{t("amc.plans.empty")}</p>
      </div>
    )
  }

  return (
    <div className={columns}>
      {groups.map((group) => {
        const style = TIER_STYLES[group.tier]
        return (
          <section key={group.name} aria-label={group.name} className="space-y-2">
            <h3 className="flex items-center gap-2 px-1 text-sm font-bold text-text">
              <span className={cn("size-3 shrink-0 rounded-[3px]", style.swatch)} />
              {group.name}
            </h3>
            {group.plans.map((plan) => {
              const activeCount = activeCountByPlan.get(plan.id) ?? 0
              return (
                <div key={plan.id} className={cn("rounded-xl px-3.5 py-3", style.card)}>
                  <div className="text-xl font-extrabold tracking-tight">
                    ₹{pricePerYearOf(plan).toLocaleString("en-IN")}
                    <span className={cn("text-xs font-semibold", style.muted)}>{t("amc.plans.perYear")}</span>
                  </div>
                  <div className={cn("mt-0.5 text-xs font-medium", style.muted)}>
                    {t("amc.plans.years", { count: plan.years })} · {t("amc.plans.servicesPerYear", { count: plan.visits_per_year })}
                  </div>
                  <div className="mt-0.5 text-xs font-semibold">
                    {t("amc.plans.activeCount", { count: activeCount })}
                    {plan.id === mostPopularPlanId ? ` · ${t("amc.plans.mostPopular")}` : ""}
                  </div>
                </div>
              )
            })}
          </section>
        )
      })}
    </div>
  )
}

function AmcTable({
  rows,
  loading,
  error,
  onRetry,
  tierColorFor,
  onRowClick,
}: {
  rows: AmcContractListItem[]
  loading: boolean
  error: string | null
  onRetry: () => void
  tierColorFor: (planId: string) => string
  onRowClick: (id: string) => void
}) {
  const { t } = useTranslation()
  const headers = [
    t("amc.list.customer"),
    t("amc.list.product"),
    t("amc.list.tier"),
    t("amc.list.expiry"),
    t("amc.list.nextSvc"),
    t("amc.list.status"),
  ]

  return (
    <div className="overflow-x-auto">
      <div className={cn("grid items-center border-y border-border bg-surface-alt px-[22px] py-[10px]", AMC_GRID)}>
        {headers.map((h) => (
          <span key={h} className="text-[11px] font-semibold uppercase tracking-wide text-text-muted">
            {h}
          </span>
        ))}
      </div>

      {error ? (
        <div className="flex flex-col items-center gap-3 py-12 text-center">
          <TriangleAlert className="size-6 text-danger" />
          <p className="text-sm text-text-muted">{error}</p>
          <Button variant="outline" size="sm" onClick={onRetry}>
            {t("common.retry")}
          </Button>
        </div>
      ) : loading ? (
        Array.from({ length: 6 }).map((_, i) => (
          <div key={i} className={cn("grid items-center border-b border-border px-[22px] py-[14px]", AMC_GRID)}>
            {headers.map((h) => (
              <Skeleton key={h} className="h-4 w-3/4 max-w-32" />
            ))}
          </div>
        ))
      ) : rows.length === 0 ? (
        <div className="flex flex-col items-center gap-2 py-12 text-center">
          <Inbox className="size-6 text-text-muted" />
          <p className="text-sm text-text-muted">{t("amc.list.emptyAmc")}</p>
        </div>
      ) : (
        rows.map((c) => {
          const tierColor = tierColorFor(c.plan_id)
          return (
            <div
              key={c.id}
              role="button"
              tabIndex={0}
              onClick={() => onRowClick(c.id)}
              onKeyDown={(e) => {
                if (e.key === "Enter" || e.key === " ") onRowClick(c.id)
              }}
              className={cn("grid cursor-pointer items-center border-b border-border px-[22px] py-[14px] last:border-b-0 hover:bg-surface-alt", AMC_GRID)}
            >
              <div className="leading-tight">
                <div className="text-[13px] font-semibold text-text">{c.customers?.name ?? "—"}</div>
                <div className="text-[11px] font-medium text-text-muted">{c.customers?.mobile ?? "—"}</div>
              </div>
              <span className="text-[13px] font-medium text-text">{c.products?.name ?? "—"}</span>
              <span className="inline-flex items-center gap-1.5 text-xs font-bold" style={{ color: tierColor }}>
                <span className="size-1.75 shrink-0 rounded-[2px]" style={{ background: tierColor }} />
                {c.amc_plans?.name ?? "—"}
              </span>
              <span className="text-[13px] font-medium tabular-nums text-text">{formatDate(c.expiry_date)}</span>
              <span className="text-[13px] font-medium tabular-nums text-text">{formatDate(c.next_service_date)}</span>
              <StatusDot tone={AMC_STATUS_TONE[c.status] ?? "neutral"} label={t(`amc.status.${c.status}`)} />
            </div>
          )
        })
      )}
    </div>
  )
}

function WarrantyTable({
  rows,
  loading,
  error,
  onRetry,
}: {
  rows: (WarrantyListItem & { computedStatus: string })[]
  loading: boolean
  error: string | null
  onRetry: () => void
}) {
  const { t } = useTranslation()
  const headers = [
    t("amc.list.customer"),
    t("amc.list.product"),
    t("amc.list.serialNo"),
    t("amc.list.expiry"),
    t("amc.list.nextSvc"),
    t("amc.list.status"),
  ]

  return (
    <div className="overflow-x-auto">
      <div className={cn("grid items-center border-y border-border bg-surface-alt px-[22px] py-[10px]", WARRANTY_GRID)}>
        {headers.map((h) => (
          <span key={h} className="text-[11px] font-semibold uppercase tracking-wide text-text-muted">
            {h}
          </span>
        ))}
      </div>

      {error ? (
        <div className="flex flex-col items-center gap-3 py-12 text-center">
          <TriangleAlert className="size-6 text-danger" />
          <p className="text-sm text-text-muted">{error}</p>
          <Button variant="outline" size="sm" onClick={onRetry}>
            {t("common.retry")}
          </Button>
        </div>
      ) : loading ? (
        Array.from({ length: 6 }).map((_, i) => (
          <div key={i} className={cn("grid items-center border-b border-border px-[22px] py-[14px]", WARRANTY_GRID)}>
            {headers.map((h) => (
              <Skeleton key={h} className="h-4 w-3/4 max-w-32" />
            ))}
          </div>
        ))
      ) : rows.length === 0 ? (
        <div className="flex flex-col items-center gap-2 py-12 text-center">
          <Inbox className="size-6 text-text-muted" />
          <p className="text-sm text-text-muted">{t("amc.list.emptyWarranty")}</p>
        </div>
      ) : (
        rows.map((w) => (
          <div key={w.id} className={cn("grid items-center border-b border-border px-[22px] py-[14px] last:border-b-0 hover:bg-surface-alt", WARRANTY_GRID)}>
            <div className="leading-tight">
              <div className="text-[13px] font-semibold text-text">{w.customers?.name ?? "—"}</div>
              <div className="text-[11px] font-medium text-text-muted">{w.customers?.mobile ?? "—"}</div>
            </div>
            <span className="text-[13px] font-medium text-text">{w.products?.name ?? "—"}</span>
            <span className="text-[13px] font-medium tabular-nums text-text">{w.serial_no ?? "—"}</span>
            <span className="text-[13px] font-medium tabular-nums text-text">{formatDate(w.expiry_date)}</span>
            <span className="text-[13px] font-medium tabular-nums text-text">{formatDate(w.next_service_date)}</span>
            <StatusDot tone={AMC_STATUS_TONE[w.computedStatus as keyof typeof AMC_STATUS_TONE] ?? "neutral"} label={t(`amc.status.${w.computedStatus}`)} />
          </div>
        ))
      )}
    </div>
  )
}
