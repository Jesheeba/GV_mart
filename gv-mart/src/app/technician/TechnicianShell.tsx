import { useEffect } from "react"
import { Outlet, useNavigate } from "react-router-dom"
import { useTranslation } from "react-i18next"
import { Bell, Home, MapPin, CalendarCheck, History, User, UserX } from "lucide-react"
import { BottomTabBar, type BottomTab } from "@/components/shared/BottomTabBar"
import { LanguageToggle } from "@/components/shared/LanguageToggle"
import { UserMenu } from "@/components/shared/UserMenu"
import { Button } from "@/components/ui/button"
import { useProfile } from "@/hooks/useProfile"
import { useLiveLocationStream, useMyTechnician } from "@/hooks/useTechnician"
import { useUnreadNotificationCount } from "@/hooks/useSystemPages"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { SyncStatusChip } from "./components/SyncStatusChip"
import { startSyncEngine, stopSyncEngine } from "@/lib/offline/sync"
import { signOut } from "@/services/auth"

export function TechnicianShell() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { data: profile, isLoading, isError, refetch } = useProfile()
  const { data: unreadCount } = useUnreadNotificationCount(profile?.org_id, profile?.id, profile?.role)

  // Starts the offline outbox flush loop once for the whole technician app
  // (DoD: "Full job lifecycle works offline and syncs") — idempotent, safe
  // to call once at the shell root; torn down on unmount.
  useEffect(() => {
    startSyncEngine()
    return () => stopSyncEngine()
  }, [])

  // v2.2 §6.6 live tracking: streams position for as long as the technician
  // is logged into the app, regardless of which screen they're on or
  // whether they currently have an active job (see useLiveLocationStream's
  // doc comment for why this isn't job-gated) — EXCEPT once deactivated
  // (Technician Lifecycle Mgmt Phase 3), passing `undefined` below no-ops it.
  const technician = useMyTechnician()
  const isDeactivated = technician.data != null && technician.data.is_active === false
  useLiveLocationStream(profile?.org_id, isDeactivated ? undefined : technician.data?.id)

  if (isLoading || technician.isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError || !profile) {
    return <FullPageError message={t("auth.profileLoadError")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  // Deactivated technicians keep a valid Supabase session (login itself
  // isn't proxied — see 20260730150000_technician_active_write_rls.sql's
  // file header for why) but get no functional dashboard: no active
  // bookings, no assignments, no notifications. RLS independently blocks
  // any new writes even if this check were somehow bypassed.
  if (isDeactivated) {
    return (
      <div className="flex min-h-screen flex-col items-center justify-center gap-3 bg-bg px-6 text-center">
        <UserX className="size-10 text-text-muted" />
        <h1 className="text-lg font-bold text-text">{t("technician.deactivated.title")}</h1>
        <p className="max-w-xs text-sm text-text-muted">{t("technician.deactivated.body")}</p>
        <Button variant="outline" onClick={() => void signOut()}>
          {t("technician.deactivated.signOut")}
        </Button>
      </div>
    )
  }

  const tabs: BottomTab[] = [
    { key: "home", label: t("tabs.home"), path: "/technician", icon: Home, end: true },
    { key: "map", label: t("tabs.map"), path: "/technician/map", icon: MapPin },
    { key: "attendance", label: t("tabs.attendance"), path: "/technician/attendance", icon: CalendarCheck },
    { key: "history", label: t("tabs.history"), path: "/technician/history", icon: History },
    { key: "profile", label: t("tabs.profile"), path: "/technician/profile", icon: User },
  ]

  return (
    <div className="min-h-screen bg-bg pb-20">
      <header className="flex items-center justify-between px-4 py-3">
        <div className="flex items-center gap-2">
          <span className="flex size-8 items-center justify-center rounded-md border border-border bg-white p-1">
            <img src="/logo-icon.svg" alt="GV Mart" className="size-full object-contain" />
          </span>
          <span className="text-sm font-semibold text-text">{t("shell.technicianAppTitle")}</span>
        </div>
        <div className="flex items-center gap-2">
          <SyncStatusChip />
          <button
            type="button"
            aria-label={t("shell.notifications")}
            onClick={() => navigate("/technician/notifications")}
            className="relative flex size-9 items-center justify-center rounded-full bg-surface text-text-muted hover:bg-surface-alt hover:text-text"
          >
            <Bell className="size-4" />
            {unreadCount ? (
              <span className="absolute right-1 top-1 flex size-4 min-w-4 items-center justify-center rounded-full bg-danger px-0.5 text-[9px] font-bold leading-none text-white">
                {unreadCount > 9 ? "9+" : unreadCount}
              </span>
            ) : null}
          </button>
          <LanguageToggle />
          <UserMenu fullName={profile.full_name} role={profile.role} />
        </div>
      </header>
      <main className="px-4">
        <Outlet />
      </main>
      <BottomTabBar tabs={tabs} />
    </div>
  )
}
