import { Outlet } from "react-router-dom"
import { useTranslation } from "react-i18next"
import { Home, Package, CalendarClock, User } from "lucide-react"
import { BottomTabBar, type BottomTab } from "@/components/shared/BottomTabBar"
import { LanguageToggle } from "@/components/shared/LanguageToggle"
import { UserMenu } from "@/components/shared/UserMenu"
import { useProfile } from "@/hooks/useProfile"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { GVMartMark } from "@/components/shared/GVMartMark"

export function CustomerShell() {
  const { t } = useTranslation()
  const { data: profile, isLoading, isError, refetch } = useProfile()

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
      <header className="flex items-center justify-between px-4 py-3">
        <div className="flex items-center gap-2">
          <span className="flex size-8 items-center justify-center rounded-md bg-accent p-1.5 text-white">
            <GVMartMark variant="mono" className="size-full" />
          </span>
          <span className="text-sm font-semibold text-text">{t("shell.customerAppTitle")}</span>
        </div>
        <div className="flex items-center gap-2">
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
