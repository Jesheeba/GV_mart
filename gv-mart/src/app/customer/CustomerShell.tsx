import { Outlet, useNavigate } from "react-router-dom"
import { useTranslation } from "react-i18next"
import { Bell, Home, Package, CalendarClock, User } from "lucide-react"
import { BottomTabBar, type BottomTab } from "@/components/shared/BottomTabBar"
import { LanguageToggle } from "@/components/shared/LanguageToggle"
import { UserMenu } from "@/components/shared/UserMenu"
import { useProfile } from "@/hooks/useProfile"
import { useUnreadNotificationCount } from "@/hooks/useSystemPages"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { OtpAlertBanner } from "@/app/customer/components/OtpAlertBanner"
import { TechnicianAssignedBanner } from "@/app/customer/components/TechnicianAssignedBanner"

export function CustomerShell() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { data: profile, isLoading, isError, refetch } = useProfile()
  const { data: unreadCount } = useUnreadNotificationCount(profile?.org_id, profile?.id, profile?.role)

  if (isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError || !profile) {
    return <FullPageError message={t("auth.profileLoadError")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  const tabs: BottomTab[] = [
    { key: "home", label: t("tabs.home"), path: "/customer", icon: Home, end: true },
    { key: "myProducts", label: t("tabs.myProducts"), path: "/customer/products", icon: Package },
    { key: "bookings", label: t("tabs.bookings"), path: "/customer/bookings", icon: CalendarClock },
    { key: "profile", label: t("tabs.profile"), path: "/customer/profile", icon: User },
  ]

  return (
    <div className="min-h-screen bg-bg pb-20">
      <header className="flex items-center justify-between px-4 py-3 lg:px-25">
        <div className="flex items-center gap-2">
          <span className="flex size-8 items-center justify-center rounded-md border border-border bg-white p-1">
            <img src="/logo-icon.svg" alt="GV Mart" className="size-full object-contain" />
          </span>
          <span className="text-sm font-semibold text-text">{t("shell.customerAppTitle")}</span>
        </div>
        <div className="flex items-center gap-2">
          <button
            type="button"
            aria-label={t("shell.notifications")}
            onClick={() => navigate("/customer/notifications")}
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
      <TechnicianAssignedBanner />
      <OtpAlertBanner />
      <main className="px-4 lg:px-25">
        <Outlet />
      </main>
      <BottomTabBar tabs={tabs} />
    </div>
  )
}
