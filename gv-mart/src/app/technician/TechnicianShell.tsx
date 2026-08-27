import { useEffect } from "react"
import { Outlet, useNavigate } from "react-router-dom"
import { useTranslation } from "react-i18next"
import { Bell, Check, Home, MapPin, CalendarCheck, History, Languages, Moon, MoreVertical, Sun, User, UserX } from "lucide-react"
import { BottomTabBar, type BottomTab } from "@/components/shared/BottomTabBar"
import { UserMenu } from "@/components/shared/UserMenu"
import { Button } from "@/components/ui/button"
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuSeparator, DropdownMenuTrigger } from "@/components/ui/dropdown-menu"
import { useProfile } from "@/hooks/useProfile"
import { useLiveLocationStream, useMyTechnician } from "@/hooks/useTechnician"
import { useUnreadNotificationCount } from "@/hooks/useSystemPages"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { SyncStatusChip } from "./components/SyncStatusChip"
import { NewJobAssignedBanner } from "./components/NewJobAssignedBanner"
import { startSyncEngine, stopSyncEngine } from "@/lib/offline/sync"
import { signOut } from "@/services/auth"
import { useTheme } from "@/lib/theme/ThemeProvider"
import { SUPPORTED_LANGUAGES, type SupportedLanguage } from "@/lib/i18n"

const LANGUAGE_LABELS: Record<SupportedLanguage, string> = { en: "English", ta: "தமிழ்" }

export function TechnicianShell() {
  const { t, i18n } = useTranslation()
  const navigate = useNavigate()
  const { data: profile, isLoading, isError, refetch } = useProfile()
  const { data: unreadCount } = useUnreadNotificationCount(profile?.org_id, profile?.id, profile?.role)
  const { theme, toggleTheme } = useTheme()
  const activeLanguage = (i18n.resolvedLanguage ?? "en") as SupportedLanguage

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
      <header className="flex items-center justify-between gap-1.5 px-4 pb-3 pt-[calc(env(safe-area-inset-top)+0.75rem)]">
        <div className="flex min-w-0 shrink items-center gap-2">
          <span className="flex size-8 shrink-0 items-center justify-center rounded-md border border-border bg-white p-1">
            <img src="/logo-icon.svg" alt="GV Mart" className="size-full object-contain" />
          </span>
          {/* Hidden below sm: the header's right-side cluster (sync status,
              theme, notifications, language, user menu) alone is already
              tight against a ~360-412dp phone width — a title here forced an
              ugly two-line wrap and pushed the user menu past the edge. Kept
              for screen readers via sr-only. */}
          <span className="sr-only text-sm font-semibold text-text sm:not-sr-only sm:truncate">{t("shell.technicianAppTitle")}</span>
        </div>
        <div className="flex shrink-0 items-center gap-1.5">
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
          {/* Theme + language used to each get their own persistent header
              button — set-once, infrequent actions that were a big share of
              why the row didn't fit a 360-412dp phone. Consolidated into one
              overflow menu; sync status and notifications stay persistent
              since those are the things a technician actually checks often. */}
          <DropdownMenu>
            <DropdownMenuTrigger
              aria-label={t("shell.moreOptions")}
              className="flex size-9 items-center justify-center rounded-full bg-surface text-text-muted outline-none hover:bg-surface-alt hover:text-text"
            >
              <MoreVertical className="size-4" />
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end" className="w-44">
              <DropdownMenuItem onClick={toggleTheme}>
                {theme === "dark" ? <Sun className="size-4" /> : <Moon className="size-4" />}
                {theme === "dark" ? t("shell.switchToLightMode") : t("shell.switchToDarkMode")}
              </DropdownMenuItem>
              <DropdownMenuSeparator />
              {SUPPORTED_LANGUAGES.map((lng) => (
                <DropdownMenuItem key={lng} onClick={() => i18n.changeLanguage(lng)}>
                  <Languages className="size-4" />
                  {LANGUAGE_LABELS[lng]}
                  {activeLanguage === lng ? <Check className="ml-auto size-4" /> : null}
                </DropdownMenuItem>
              ))}
            </DropdownMenuContent>
          </DropdownMenu>
          <UserMenu fullName={profile.full_name} role={profile.role} />
        </div>
      </header>
      <NewJobAssignedBanner userId={profile.id} />
      <main className="px-4">
        <Outlet />
      </main>
      <BottomTabBar tabs={tabs} />
    </div>
  )
}
