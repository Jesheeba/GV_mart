import { Bell, Search } from "lucide-react"
import { NavLink, Outlet, useNavigate } from "react-router-dom"
import { useTranslation } from "react-i18next"
import { cn } from "@/lib/utils"
import { ADMIN_NAV } from "./nav"
import { useProfile } from "@/hooks/useProfile"
import { useUnreadNotificationCount } from "@/hooks/useSystemPages"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { LanguageToggle } from "@/components/shared/LanguageToggle"
import { UserMenu } from "@/components/shared/UserMenu"

export function AdminShell() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { data: profile, isLoading, isError, refetch } = useProfile()
  const { data: unreadCount } = useUnreadNotificationCount(profile?.org_id, profile?.id, profile?.role)

  if (isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError || !profile) {
    return <FullPageError message={t("auth.profileLoadError")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  const items = ADMIN_NAV.filter((item) => item.roles.includes(profile.role))

  return (
    <div className="flex h-screen overflow-hidden bg-bg">
      {/* Its own independently-scrolling region — never moves when the main
          content scrolls, and (if the nav list ever outgrows the viewport)
          scrolls internally instead of dragging header/content with it. */}
      <aside className="my-4 ml-4 flex h-[calc(100vh-2rem)] w-16 shrink-0 flex-col items-center gap-2 overflow-y-auto rounded-card border border-border bg-surface py-4">
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

      <div className="flex min-w-0 flex-1 flex-col overflow-hidden">
        <header className="flex shrink-0 items-center gap-3 px-6 py-4">
          <div className="relative flex-1 max-w-md">
            <Search className="pointer-events-none absolute left-3.5 top-1/2 size-4 -translate-y-1/2 text-text-muted" />
            <input
              type="search"
              placeholder={t("shell.searchPlaceholder")}
              className="h-10 w-full rounded-full border border-border bg-surface pl-10 pr-4 text-sm text-text outline-none placeholder:text-text-muted focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/20"
            />
          </div>
          <div className="ml-auto flex items-center gap-2">
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
        <main className="flex-1 overflow-y-auto px-6 pb-8">
          <Outlet />
        </main>
      </div>
    </div>
  )
}
