import { Bell, Search } from "lucide-react"
import { NavLink, Outlet } from "react-router-dom"
import { useTranslation } from "react-i18next"
import { cn } from "@/lib/utils"
import { ADMIN_NAV } from "./nav"
import { useProfile } from "@/hooks/useProfile"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { LanguageToggle } from "@/components/shared/LanguageToggle"
import { UserMenu } from "@/components/shared/UserMenu"
import { GVMartMark } from "@/components/shared/GVMartMark"

export function AdminShell() {
  const { t } = useTranslation()
  const { data: profile, isLoading, isError, refetch } = useProfile()

  if (isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError || !profile) {
    return <FullPageError message={t("auth.profileLoadError")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  const items = ADMIN_NAV.filter((item) => item.roles.includes(profile.role))

  return (
    <div className="flex min-h-screen bg-bg">
      <aside className="sticky top-4 ml-4 flex h-[calc(100vh-2rem)] w-16 flex-col items-center gap-2 rounded-card border border-border bg-surface py-4">
        <span className="mb-2 flex size-9 items-center justify-center rounded-md bg-accent p-1.5 text-white">
          <GVMartMark variant="mono" className="size-full" />
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
                    "flex size-10 items-center justify-center rounded-xl transition-colors",
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

      <div className="flex min-w-0 flex-1 flex-col">
        <header className="flex items-center gap-3 px-6 py-4">
          <div className="relative flex-1 max-w-md">
            <Search className="pointer-events-none absolute left-3.5 top-1/2 size-4 -translate-y-1/2 text-text-muted" />
            <input
              type="search"
              placeholder={t("shell.searchPlaceholder")}
              className="h-10 w-full rounded-full border border-border bg-surface pl-10 pr-4 text-sm text-text outline-none placeholder:text-text-muted focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/20"
            />
          </div>
          <div className="flex items-center gap-2">
            <button
              type="button"
              aria-label={t("shell.notifications")}
              className="flex size-10 items-center justify-center rounded-full bg-surface text-text-muted hover:bg-surface-alt hover:text-text"
            >
              <Bell className="size-4" />
            </button>
            <LanguageToggle />
            <UserMenu fullName={profile.full_name} role={profile.role} />
          </div>
        </header>

        <main className="flex-1 px-6 pb-8">
          <Outlet />
        </main>
      </div>
    </div>
  )
}
