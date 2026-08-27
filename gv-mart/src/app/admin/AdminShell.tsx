import { useEffect, useRef, useState } from "react"
import { Bell, Search } from "lucide-react"
import { NavLink, Outlet, useNavigate } from "react-router-dom"
import { useTranslation } from "react-i18next"
import { cn } from "@/lib/utils"
import { ADMIN_NAV } from "./nav"
import { useProfile } from "@/hooks/useProfile"
import { useUnreadNotificationCount } from "@/hooks/useSystemPages"
import { useCustomerAutocomplete } from "@/hooks/useCustomers"
import { useTicketSearch, useServiceTicketsRealtimeInvalidate } from "@/hooks/useService"
import { useTechniciansOpenVisits, useTechniciansWithLocation } from "@/hooks/useTechniciansAdmin"
import { useDebouncedValue } from "@/hooks/useDebouncedValue"
import { useToast } from "@/components/ui/toast-context"
import { Autocomplete } from "@/components/shared/Autocomplete"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { LanguageToggle } from "@/components/shared/LanguageToggle"
import { UserMenu } from "@/components/shared/UserMenu"
import { computeJobOverrun } from "@/lib/job-overrun"
import { notifyJobOverrunAlert } from "@/services/techniciansAdmin"

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

export function AdminShell() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { data: profile, isLoading, isError, refetch } = useProfile()
  const { data: unreadCount } = useUnreadNotificationCount(profile?.org_id, profile?.id, profile?.role)
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
  const notifiedVisitIdsRef = useRef<Set<string>>(new Set())
  useEffect(() => {
    const orgId = profile?.org_id
    if (!orgId || !openVisits) return
    function checkOverruns() {
      const nowMs = Date.now()
      for (const [techId, visit] of openVisits!) {
        const overrun = computeJobOverrun(
          { timerStart: visit.timerStart, timerEnd: visit.timerEnd, estimatedDurationMinutes: visit.allowedDurationMinutes },
          nowMs
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
      {/* Its own independently-scrolling region — never moves when the main
          content scrolls, and (if the nav list ever outgrows the viewport)
          scrolls internally instead of dragging header/content with it. */}
      <aside className="my-4 ml-4 flex h-[calc(100vh-2rem)] w-16 shrink-0 flex-col items-center gap-2 overflow-y-auto rounded-card border border-border bg-surface py-4 print:hidden">
        <span className="mb-2 flex size-9 shrink-0 items-center justify-center rounded-md border border-border bg-white p-1">
          <img src="/logo-icon.svg" alt="GV Mart" className="size-full object-contain" />
        </span>
        <nav className="flex flex-1 flex-col items-center gap-1">
          {items.map((item) => {
            const Icon = item.icon
            return (
              <NavLink
                key={item.key}
                to={item.path}
                end={item.end}
                title={t(item.labelKey)}
                aria-label={t(item.labelKey)}
                className={({ isActive }) =>
                  cn(
                    "flex size-10 shrink-0 items-center justify-center rounded-xl transition-colors",
                    isActive ? "bg-ink text-white" : "text-text-muted hover:bg-surface-alt hover:text-text"
                  )
                }
              >
                <Icon className="size-5" />
              </NavLink>
            )
          })}
        </nav>
      </aside>

      <div className="flex min-w-0 flex-1 flex-col overflow-hidden print:block print:overflow-visible">
        <header className="flex shrink-0 items-center gap-3 px-6 py-4 print:hidden">
          <AdminGlobalSearch orgId={profile.org_id} />
          <div className="ml-auto flex shrink-0 items-center gap-2">
            <button
              type="button"
              aria-label={t("shell.notifications")}
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

        {/* The only scrolling region on the page now — sidebar and header stay put. */}
        <main className="flex-1 overflow-y-auto px-6 pb-8 print:overflow-visible print:p-0">
          <Outlet />
        </main>
      </div>
    </div>
  )
}
