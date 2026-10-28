import { useEffect, useRef, useState } from "react"
import { createPortal } from "react-dom"
import { Bell, ChevronLeft, Search } from "lucide-react"
import { NavLink, Outlet, useNavigate } from "react-router-dom"
import { useTranslation } from "react-i18next"
import { cn } from "@/lib/utils"
import { ADMIN_NAV } from "./nav"
import { useProfile } from "@/hooks/useProfile"
import { useUnreadNotificationCount } from "@/hooks/useSystemPages"
import { canWorkFollowups, useFollowupCounts } from "@/hooks/useLeadFollowups"
import { CallReturnPrompt } from "./leads/CallReturnPrompt"
import { useCustomerAutocomplete } from "@/hooks/useCustomers"
import { useTicketSearch, useServiceTicketsRealtimeInvalidate } from "@/hooks/useService"
import { useTechniciansOpenVisits, useTechniciansWithLocation } from "@/hooks/useTechniciansAdmin"
import { useSettings } from "@/hooks/useMasters"
import { useDebouncedValue } from "@/hooks/useDebouncedValue"
import { useToast } from "@/components/ui/toast-context"
import { Autocomplete } from "@/components/shared/Autocomplete"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { LanguageToggle } from "@/components/shared/LanguageToggle"
import { UserMenu } from "@/components/shared/UserMenu"
import { computeJobOverrun } from "@/lib/job-overrun"
import { notifyJobOverrunAlert } from "@/services/techniciansAdmin"
import { PoApprovalPromptModal } from "./purchase/PoApprovalPromptModal"
import { PoReceiptPromptModal } from "./purchase/PoReceiptPromptModal"

// Header search bar (ADM shell) — scoped to exactly what's fast + useful to
// jump to from anywhere: a customer by name/mobile (reusing the same
// autocompleteCustomers query the New Sale / New Complaint / Quotation
// customer pickers already use) or a service ticket by complaint text or its
// short #id prefix (see service.ts#searchTicketsQuick). Deliberately not
// wired up to invoices — no quick invoice search exists anywhere else in the
// app to reuse, and inventing one is out of scope for wiring up this input.
type GlobalSearchResult =
  | { kind: "customer"; id: string; name: string; mobile: string }
  | { kind: "ticket"; id: string; complaint: string | null; customerName: string | null }

function AdminGlobalSearch({ orgId }: { orgId: string }) {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const [term, setTerm] = useState("")
  const debouncedTerm = useDebouncedValue(term, 300)
  const customerResults = useCustomerAutocomplete(orgId, debouncedTerm)
  const ticketResults = useTicketSearch(orgId, debouncedTerm)

  const suggestions: GlobalSearchResult[] = [
    ...(customerResults.data ?? []).map((c) => ({ kind: "customer" as const, id: c.id, name: c.name, mobile: c.mobile })),
    ...(ticketResults.data ?? []).map((tk) => ({
      kind: "ticket" as const,
      id: tk.id,
      complaint: tk.name_of_complaint,
      customerName: tk.customers?.name ?? null,
    })),
  ]

  return (
    <Autocomplete
      id="admin-global-search"
      value={term}
      onChange={setTerm}
      suggestions={suggestions}
      loading={term.trim() !== debouncedTerm.trim() || customerResults.isFetching || ticketResults.isFetching}
      icon={<Search className="size-4" />}
      placeholder={t("shell.searchPlaceholder")}
      emptyMessage={t("shell.searchEmpty")}
      getKey={(r) => `${r.kind}:${r.id}`}
      getLabel={(r) =>
        r.kind === "customer" ? (
          <span>
            <span className="font-medium">{r.name}</span> <span className="text-text-muted">{r.mobile}</span>
          </span>
        ) : (
          <span>
            <span className="font-medium">#{r.id.slice(0, 8)}</span>{" "}
            <span className="text-text-muted">{r.complaint ?? r.customerName ?? ""}</span>
          </span>
        )
      }
      onSelect={(r) => {
        setTerm("")
        navigate(r.kind === "customer" ? `/admin/customers/${r.id}` : `/admin/service/${r.id}`)
      }}
      className="relative min-w-0 flex-1 max-w-md"
      inputClassName="h-10 w-full rounded-full border border-border bg-surface pl-10 pr-4 text-sm text-text outline-none placeholder:text-text-muted focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/20"
    />
  )
}

const SIDEBAR_COLLAPSED_KEY = "gv_mart_admin_sidebar_collapsed"

function getInitialSidebarCollapsed(): boolean {
  try {
    const stored = localStorage.getItem(SIDEBAR_COLLAPSED_KEY)
    if (stored !== null) return stored === "true"
  } catch {
    // ignore — localStorage can throw in private browsing / blocked storage
  }
  // No saved preference yet: default to collapsed on phone-width viewports
  // so the sidebar doesn't eat the screen on first load.
  return typeof window !== "undefined" && window.innerWidth < 640
}

export function AdminShell() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const [sidebarCollapsed, setSidebarCollapsed] = useState(getInitialSidebarCollapsed)
  useEffect(() => {
    try {
      localStorage.setItem(SIDEBAR_COLLAPSED_KEY, String(sidebarCollapsed))
    } catch {
      // ignore
    }
  }, [sidebarCollapsed])
  // Collapsed-sidebar hover tooltip, portalled to <body> — the sidebar's
  // own overflow-y-auto (needed so the 20+ item nav list scrolls on short
  // viewports) forces overflow-x to auto too per the CSS spec's "one axis
  // visible, the other not" rule, which would otherwise clip an
  // absolutely-positioned tooltip the moment it pokes past the sidebar's
  // right edge.
  const [hoveredNavTooltip, setHoveredNavTooltip] = useState<{ label: string; top: number; left: number } | null>(null)
  useEffect(() => {
    if (sidebarCollapsed) return
    setHoveredNavTooltip(null)
  }, [sidebarCollapsed])
  const { data: profile, isLoading, isError, refetch } = useProfile()
  const { data: unreadCount } = useUnreadNotificationCount(profile?.org_id, profile?.id, profile?.role)
  const { data: followupCounts } = useFollowupCounts(profile?.role)
  useServiceTicketsRealtimeInvalidate(profile?.org_id)

  // Job-overrun popup: this used to run only inside TechniciansMapPage, so an
  // admin not on that specific page never saw it. Mounted here instead (every
  // admin route renders AdminShell) so the toast — and the underlying
  // `job_overrun` notification row — fire app-wide, the moment any
  // technician's open visit crosses estimate + OVERRUN_BUFFER_MINUTES,
  // regardless of which screen the admin is currently on.
  const { toast } = useToast()
  const { data: openVisits } = useTechniciansOpenVisits(profile?.org_id)
  const { data: techniciansWithLocation } = useTechniciansWithLocation(profile?.org_id)
  const { data: settings } = useSettings(profile?.org_id)
  const notifiedVisitIdsRef = useRef<Set<string>>(new Set())
  useEffect(() => {
    const orgId = profile?.org_id
    if (!orgId || !openVisits) return
    function checkOverruns() {
      const nowMs = Date.now()
      for (const [techId, visit] of openVisits!) {
        const overrun = computeJobOverrun(
          { timerStart: visit.timerStart, timerEnd: visit.timerEnd, estimatedDurationMinutes: visit.allowedDurationMinutes },
          nowMs,
          settings?.job_overrun_buffer_minutes
        )
        if (!overrun.isOverrun || notifiedVisitIdsRef.current.has(visit.visitId)) continue
        notifiedVisitIdsRef.current.add(visit.visitId)
        toast.error(
          t("shell.jobOverrunAlert", {
            name: visit.customerName ?? t("shell.notifications"),
            minutes: Math.round(overrun.overrunByMinutes!),
            estimate: visit.estimatedDurationMinutes ?? "—",
          })
        )
        const loc = (techniciansWithLocation ?? []).find((tech) => tech.id === techId)?.latestLocation
        void notifyJobOverrunAlert(
          orgId!,
          visit,
          overrun.overrunByMinutes!,
          loc ? { lat: loc.lat, lng: loc.lng, recordedAt: loc.recorded_at } : null
        )
      }
    }
    checkOverruns()
    const interval = setInterval(checkOverruns, 15_000)
    return () => clearInterval(interval)
  }, [profile?.org_id, openVisits, techniciansWithLocation, toast, t])

  if (isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError || !profile) {
    return <FullPageError message={t("auth.profileLoadError")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  const items = ADMIN_NAV.filter((item) => item.roles.includes(profile.role))

  return (
    <div className="flex h-screen overflow-hidden bg-bg print:block print:h-auto print:overflow-visible">
      {/* On phone-width viewports, an expanded sidebar overlays content
          instead of squeezing it — this backdrop closes it on outside tap. */}
      {!sidebarCollapsed ? (
        <div
          className="fixed inset-0 z-30 hidden bg-ink/30 max-sm:block"
          onClick={() => setSidebarCollapsed(true)}
          aria-hidden="true"
        />
      ) : null}

      {/* Its own independently-scrolling region — never moves when the main
          content scrolls, and (if the nav list ever outgrows the viewport)
          scrolls internally instead of dragging header/content with it. */}
      <aside
        className={cn(
          "relative my-4 ml-4 flex h-[calc(100vh-2rem)] shrink-0 flex-col gap-2 overflow-y-auto rounded-card border border-border bg-surface py-4 transition-[width] duration-200 ease-in-out print:hidden",
          sidebarCollapsed ? "w-16 items-center px-2" : "w-64 items-stretch px-3",
          // Expanded + phone-width: float above the page instead of pushing
          // the main content down to a sliver.
          !sidebarCollapsed && "max-sm:fixed max-sm:inset-y-4 max-sm:left-4 max-sm:z-40 max-sm:shadow-xl"
        )}
      >
        <button
          type="button"
          onClick={() => setSidebarCollapsed((c) => !c)}
          aria-label={sidebarCollapsed ? t("shell.sidebarExpand") : t("shell.sidebarCollapse")}
          title={sidebarCollapsed ? t("shell.sidebarExpand") : t("shell.sidebarCollapse")}
          className="absolute -right-3 top-7 z-10 flex size-6 shrink-0 items-center justify-center rounded-full border border-border bg-surface text-text-muted shadow-sm transition-colors hover:bg-surface-alt hover:text-text"
        >
          <ChevronLeft className={cn("size-3.5 transition-transform duration-200", sidebarCollapsed && "rotate-180")} />
        </button>

        <span
          className={cn(
            "mb-2 flex size-9 shrink-0 items-center justify-center rounded-md border border-border bg-white p-1",
            !sidebarCollapsed && "self-start"
          )}
        >
          <img src="/logo-icon.svg" alt="GV Mart" className="size-full object-contain" />
        </span>
        <nav className={cn("flex flex-1 flex-col gap-1", sidebarCollapsed ? "items-center" : "items-stretch")}>
          {items.map((item) => {
            const Icon = item.icon
            return (
              <NavLink
                key={item.key}
                to={item.path}
                end={item.end}
                aria-label={t(item.labelKey)}
                onMouseEnter={(e) => {
                  if (!sidebarCollapsed) return
                  const rect = e.currentTarget.getBoundingClientRect()
                  setHoveredNavTooltip({ label: t(item.labelKey), top: rect.top + rect.height / 2, left: rect.right + 8 })
                }}
                onMouseLeave={() => setHoveredNavTooltip(null)}
                onFocus={(e) => {
                  if (!sidebarCollapsed) return
                  const rect = e.currentTarget.getBoundingClientRect()
                  setHoveredNavTooltip({ label: t(item.labelKey), top: rect.top + rect.height / 2, left: rect.right + 8 })
                }}
                onBlur={() => setHoveredNavTooltip(null)}
                className={({ isActive }) =>
                  cn(
                    "relative flex shrink-0 items-center rounded-xl transition-colors",
                    sidebarCollapsed ? "size-10 justify-center" : "h-10 w-full gap-3 px-3",
                    isActive ? "bg-ink text-white" : "text-text-muted hover:bg-surface-alt hover:text-text"
                  )
                }
              >
                <span className="relative flex shrink-0">
                  <Icon className="size-5" />
                  {item.key === "myDay" && followupCounts?.total ? (
                    <span
                      data-testid="myday-badge"
                      className={cn(
                        "absolute -right-2 -top-2 flex min-w-4 items-center justify-center rounded-full px-1 text-[9px] font-bold leading-4 text-white",
                        followupCounts.overdue > 0 ? "bg-danger" : "bg-accent"
                      )}
                      title={t("leads.myDay.badgeTitle", { overdue: followupCounts.overdue, today: followupCounts.today })}
                    >
                      {followupCounts.total > 99 ? "99+" : followupCounts.total}
                    </span>
                  ) : null}
                </span>
                {!sidebarCollapsed ? <span className="truncate text-sm font-medium">{t(item.labelKey)}</span> : null}
              </NavLink>
            )
          })}
        </nav>
      </aside>

      {hoveredNavTooltip
        ? createPortal(
            <span
              role="tooltip"
              style={{ top: hoveredNavTooltip.top, left: hoveredNavTooltip.left }}
              className="pointer-events-none fixed z-50 -translate-y-1/2 whitespace-nowrap rounded-lg bg-ink px-2.5 py-1.5 text-xs font-medium text-white shadow-lg"
            >
              {hoveredNavTooltip.label}
            </span>,
            document.body
          )
        : null}

      <div className="flex min-w-0 flex-1 flex-col overflow-hidden print:block print:overflow-visible">
        <header className="flex shrink-0 items-center gap-3 px-6 py-4 print:hidden">
          <AdminGlobalSearch orgId={profile.org_id} />
          <div className="ml-auto flex shrink-0 items-center gap-2">
            <button
              type="button"
              aria-label={unreadCount ? t("shell.notificationsUnread", { count: unreadCount > 9 ? "9+" : unreadCount }) : t("shell.notifications")}
              onClick={() => navigate("/admin/notifications")}
              className="relative flex size-10 items-center justify-center rounded-full bg-surface text-text-muted hover:bg-surface-alt hover:text-text"
            >
              <Bell className="size-4" />
              {unreadCount ? (
                <span className="absolute right-1.5 top-1.5 flex size-4 min-w-4 items-center justify-center rounded-full bg-danger px-0.5 text-[9px] font-bold leading-none text-white">
                  {unreadCount > 9 ? "9+" : unreadCount}
                </span>
              ) : null}
            </button>
            <LanguageToggle />
            <UserMenu fullName={profile.full_name} role={profile.role} />
          </div>
        </header>

        {canWorkFollowups(profile.role) ? <CallReturnPrompt /> : null}
        <PoApprovalPromptModal orgId={profile.org_id} userId={profile.id} role={profile.role} />
        <PoReceiptPromptModal orgId={profile.org_id} userId={profile.id} role={profile.role} />

        {/* The only scrolling region on the page now — sidebar and header stay put. */}
        <main className="flex-1 overflow-y-auto px-6 pb-8 print:overflow-visible print:p-0">
          <Outlet />
        </main>
      </div>
    </div>
  )
}
