import { useEffect } from "react"
import { Outlet } from "react-router-dom"
import { useTranslation } from "react-i18next"
import { Home, MapPin, CalendarCheck, History, User } from "lucide-react"
import { BottomTabBar, type BottomTab } from "@/components/shared/BottomTabBar"
import { LanguageToggle } from "@/components/shared/LanguageToggle"
import { UserMenu } from "@/components/shared/UserMenu"
import { useProfile } from "@/hooks/useProfile"
import { useLiveLocationStream, useMyTechnician } from "@/hooks/useTechnician"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { SyncStatusChip } from "./components/SyncStatusChip"
import { startSyncEngine, stopSyncEngine } from "@/lib/offline/sync"

export function TechnicianShell() {
  const { t } = useTranslation()
  const { data: profile, isLoading, isError, refetch } = useProfile()

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
  // doc comment for why this isn't job-gated).
  const technician = useMyTechnician()
  useLiveLocationStream(profile?.org_id, technician.data?.id)

  if (isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError || !profile) {
    return <FullPageError message={t("auth.profileLoadError")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
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
