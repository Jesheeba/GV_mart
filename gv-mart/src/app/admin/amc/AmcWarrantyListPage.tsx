import { useEffect, useMemo, useState, type ReactNode } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { Inbox, Plus, TriangleAlert } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Skeleton } from "@/components/ui/skeleton"
import { StatusDot, type StatusTone } from "@/components/shared/StatusDot"
import { useProfile } from "@/hooks/useProfile"
import { useAmcContracts, useRefreshAmcStatuses, useWarranties } from "@/hooks/useAmc"
import { amcPlansHooks, useSettings } from "@/hooks/useMasters"
import { pricePerYearOf } from "@/lib/amc-window"
import { cn } from "@/lib/utils"
import { SellAmcPanel } from "./SellAmcPanel"
import type { AmcContractListItem, WarrantyListItem } from "@/services/amc"
import type { AmcPlanRow } from "@/services/masters"

const AMC_STATUS_TONE: Record<string, StatusTone> = { active: "success", due_soon: "warning", expired: "danger" }
const WARRANTY_STATUS_TONE: Record<string, StatusTone> = { active: "success", due_soon: "warning", expired: "danger" }

// Tier swatch colors cycle across plans sorted by price (design line 1078-1090:
// Silver=#8A8A82, Gold=#F5612C, Platinum=#1A1A1A) — a presentational mapping
// keyed to real plan order, not a hardcoded plan name.
const TIER_COLORS = ["#8A8A82", "#F5612C", "#1A1A1A"]

// Matches the design's AMC table grid (design-template-decoded.html line 1098):
// Customer / Product / Tier / Expiry / Next svc / Status.
const AMC_GRID = "grid-cols-[1.3fr_1.5fr_0.8fr_0.9fr_0.9fr_1fr]"
// Warranties now get proactive quarterly scheduled visits too (next_service_date
// on warranties), so the table mirrors the AMC grid's Next svc column —
// Customer / Product / Serial no / Expiry / Next svc / Status.
const WARRANTY_GRID = "grid-cols-[1.2fr_1.4fr_0.9fr_0.85fr_0.85fr_0.9fr]"

function fmt(date: string | null) {
  return date ? new Date(date).toLocaleDateString("en-IN") : "—"
}

function warrantyStatus(expiryDate: string, windowDays: number): "active" | "due_soon" | "expired" {
  const today = new Date()
  const expiry = new Date(expiryDate)
  const diffDays = (expiry.getTime() - today.getTime()) / 86_400_000
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

  const tierColorByPlanId = useMemo(() => {
    const map = new Map<string, string>()
    sortedPlans.forEach((p, i) => map.set(p.id, TIER_COLORS[i % TIER_COLORS.length]))
    return map
  }, [sortedPlans])

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
        plans={sortedPlans}
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
          <span className="text-xs font-semibold text-text-muted">
            {t("amc.list.recordCount", { count: segment === "amc" ? contracts.data?.length ?? 0 : warranties.data?.length ?? 0 })}
          </span>
        </div>

        {segment === "amc" ? (
          <AmcTable
            rows={contracts.data ?? []}
            loading={contracts.isLoading}
            error={contracts.isError ? t("amc.list.loadFailed") : null}
            onRetry={() => contracts.refetch()}
            tierColorFor={(planId) => tierColorByPlanId.get(planId) ?? "#8A8A82"}
            onRowClick={(id) => navigate(`/admin/amc/${id}`)}
          />
        ) : (
          <WarrantyTable
            rows={warrantyRows}
            loading={warranties.isLoading}
            error={warranties.isError ? t("amc.list.loadFailed") : null}
            onRetry={() => warranties.refetch()}
          />
        )}
      </div>
    </div>
  )
}

function SegButton({ active, onClick, children }: { active: boolean; onClick: () => void; children: ReactNode }) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={active}
      className={cn(
        "rounded-full px-4 py-[7px] text-xs font-semibold transition-colors",
        active ? "bg-ink text-white" : "text-text-muted"
      )}
    >
      {children}
    </button>
  )
}

function PlanTierCards({
  plans,
  loading,
  activeCountByPlan,
  mostPopularPlanId,
}: {
  plans: AmcPlanRow[]
  loading: boolean
  activeCountByPlan: Map<string, number>
  mostPopularPlanId: string | null
}) {
  const { t } = useTranslation()

  if (loading) {
    return (
      <div className="grid grid-cols-1 gap-[18px] sm:grid-cols-2 lg:grid-cols-3">
        {[0, 1, 2].map((i) => (
          <Skeleton key={i} className="h-[158px] rounded-card" />
        ))}
      </div>
    )
  }

  if (plans.length === 0) {
    return (
      <div className="rounded-card border border-border bg-surface-alt p-6 text-center">
        <p className="text-sm text-text-muted">{t("amc.plans.empty")}</p>
      </div>
    )
  }

  return (
    <div className="grid grid-cols-1 gap-[18px] sm:grid-cols-2 lg:grid-cols-3">
      {plans.map((plan, i) => (
        <PlanTierCard
          key={plan.id}
          plan={plan}
          tier={i % 3}
          activeCount={activeCountByPlan.get(plan.id) ?? 0}
          mostPopular={plan.id === mostPopularPlanId}
        />
      ))}
    </div>
  )
}

function PlanTierCard({
  plan,
  tier,
  activeCount,
  mostPopular,
}: {
  plan: AmcPlanRow
  tier: number
  activeCount: number
  mostPopular: boolean
}) {
  const { t } = useTranslation()
  const base = "relative flex min-h-[158px] flex-col justify-between overflow-hidden rounded-card p-5.5"
  const servicesLabel = t("amc.plans.servicesPerYear", { count: plan.visits_per_year })
  const activeLabel = `${t("amc.plans.activeCount", { count: activeCount })}${mostPopular ? ` · ${t("amc.plans.mostPopular")}` : ""}`

  if (tier === 1) {
    return (
      <div className={cn(base, "bg-gradient-to-br from-accent to-[#FF7E47] text-white shadow-[0_14px_32px_-16px_rgba(245,97,44,.6)]")}>
        <div className="absolute -right-7.5 -top-7.5 size-30 rounded-full bg-white/10" />
        <div className="relative flex items-start justify-between">
          <div>
            <div className="text-[15px] font-bold">{plan.name}</div>
            <div className="text-xs font-medium text-white/85">{servicesLabel}</div>
          </div>
          <span className="h-6 w-8.5 shrink-0 rounded-[5px] bg-white/35" />
        </div>
        <div className="relative">
          <div className="text-[26px] font-extrabold tracking-tight">
            ₹{pricePerYearOf(plan).toLocaleString("en-IN")}
            <span className="text-[13px] font-semibold text-white/85">{t("amc.plans.perYear")}</span>
          </div>
          <div className="mt-1 text-xs font-semibold text-white/90">{activeLabel}</div>
        </div>
      </div>
    )
  }

  if (tier === 2) {
    return (
      <div className={cn(base, "bg-gradient-to-br from-ink to-[#33302C] text-white shadow-[0_14px_30px_-18px_rgba(26,26,26,.6)]")}>
        <div className="absolute -right-6 -top-6 size-27.5 rounded-full bg-accent/[.18]" />
        <div className="relative flex items-start justify-between">
          <div>
            <div className="text-[15px] font-bold">{plan.name}</div>
            <div className="text-xs font-medium text-white/75">{servicesLabel}</div>
          </div>
          <span className="h-6 w-8.5 shrink-0 rounded-[5px] bg-gradient-to-br from-accent to-[#FF7E47]" />
        </div>
        <div className="relative">
          <div className="text-[26px] font-extrabold tracking-tight">
            ₹{pricePerYearOf(plan).toLocaleString("en-IN")}
            <span className="text-[13px] font-semibold text-white/75">{t("amc.plans.perYear")}</span>
          </div>
          <div className="mt-1 text-xs font-semibold text-white/85">{activeLabel}</div>
        </div>
      </div>
    )
  }

  return (
    <div className={cn(base, "border border-border bg-surface-alt")}>
      <div className="flex items-start justify-between">
        <div>
          <div className="text-[15px] font-bold text-text">{plan.name}</div>
          <div className="text-xs font-medium text-text-muted">{servicesLabel}</div>
        </div>
        <span className="h-6 w-8.5 shrink-0 rounded-[5px] bg-gradient-to-br from-[#C9C4BA] to-[#A8A299]" />
      </div>
      <div>
        <div className="text-[26px] font-extrabold tracking-tight text-text">
          ₹{pricePerYearOf(plan).toLocaleString("en-IN")}
          <span className="text-[13px] font-semibold text-text-muted">{t("amc.plans.perYear")}</span>
        </div>
        <div className="mt-1 text-xs font-semibold text-text-muted">{activeLabel}</div>
      </div>
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
    <div>
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
          <div key={i} className={cn("grid items-center border-b border-[#F1EDE6] px-[22px] py-[14px]", AMC_GRID)}>
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
              className={cn("grid cursor-pointer items-center border-b border-[#F1EDE6] px-[22px] py-[14px] last:border-b-0 hover:bg-[#FAF8F4]", AMC_GRID)}
            >
              <div className="leading-tight">
                <div className="text-[13px] font-semibold text-text">{c.customers?.name ?? "—"}</div>
                <div className="text-[11px] font-medium text-text-muted">{c.customers?.mobile ?? "—"}</div>
              </div>
              <span className="text-[13px] font-medium text-[#3A3A36]">{c.products?.name ?? "—"}</span>
              <span className="inline-flex items-center gap-1.5 text-xs font-bold" style={{ color: tierColor }}>
                <span className="size-1.75 shrink-0 rounded-[2px]" style={{ background: tierColor }} />
                {c.amc_plans?.name ?? "—"}
              </span>
              <span className="text-[13px] font-medium tabular-nums text-[#3A3A36]">{fmt(c.expiry_date)}</span>
              <span className="text-[13px] font-medium tabular-nums text-[#3A3A36]">{fmt(c.next_service_date)}</span>
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
    <div>
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
          <div key={i} className={cn("grid items-center border-b border-[#F1EDE6] px-[22px] py-[14px]", WARRANTY_GRID)}>
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
          <div key={w.id} className={cn("grid items-center border-b border-[#F1EDE6] px-[22px] py-[14px] last:border-b-0 hover:bg-[#FAF8F4]", WARRANTY_GRID)}>
            <div className="leading-tight">
              <div className="text-[13px] font-semibold text-text">{w.customers?.name ?? "—"}</div>
              <div className="text-[11px] font-medium text-text-muted">{w.customers?.mobile ?? "—"}</div>
            </div>
            <span className="text-[13px] font-medium text-[#3A3A36]">{w.products?.name ?? "—"}</span>
            <span className="text-[13px] font-medium tabular-nums text-[#3A3A36]">{w.serial_no ?? "—"}</span>
            <span className="text-[13px] font-medium tabular-nums text-[#3A3A36]">{fmt(w.expiry_date)}</span>
            <span className="text-[13px] font-medium tabular-nums text-[#3A3A36]">{fmt(w.next_service_date)}</span>
            <StatusDot tone={WARRANTY_STATUS_TONE[w.computedStatus] ?? "neutral"} label={t(`amc.status.${w.computedStatus}`)} />
          </div>
        ))
      )}
    </div>
  )
}
