import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { CalendarRange, LogOut, Star, TrendingUp } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { useProfile } from "@/hooks/useProfile"
import { useMyTechnician, useTechnicianStats } from "@/hooks/useTechnician"
import { signOut } from "@/services/auth"
import { formatCurrency } from "@/lib/sale-calc"

function initials(name: string) {
  const parts = name.trim().split(/\s+/)
  return ((parts[0]?.[0] ?? "") + (parts[1]?.[0] ?? "")).toUpperCase()
}

export function ProfilePage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { data: profile, isLoading, isError, refetch } = useProfile()
  const technician = useMyTechnician()
  const stats = useTechnicianStats(technician.data?.id, profile?.org_id)

  if (isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError || !profile) {
    return <FullPageError message={t("auth.profileLoadError")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  return (
    <div className="space-y-4 pt-2">
      <h1 className="text-xl font-bold text-text">{t("technician.profile.title")}</h1>

      <Card className="items-center gap-2 py-6 text-center">
        <span className="flex size-16 items-center justify-center rounded-full bg-ink text-xl font-semibold text-white">
          {initials(profile.full_name)}
        </span>
        <p className="text-base font-semibold text-text">{profile.full_name}</p>
        <p className="text-xs text-text-muted">{t(`roles.${profile.role}`)}</p>
      </Card>

      {technician.isLoading || stats.isLoading ? (
        <Card className="items-center py-6 text-center">
          <p className="text-sm text-text-muted">{t("common.loading")}</p>
        </Card>
      ) : technician.isError || stats.isError || !stats.data ? (
        <Card className="items-center gap-2 py-6 text-center">
          <p className="text-sm text-danger">{t("technician.errors.loadFailed")}</p>
          <Button type="button" variant="outline" size="sm" onClick={() => stats.refetch()}>
            {t("common.retry")}
          </Button>
        </Card>
      ) : (
        <>
          <Card className="gap-3">
            <p className="px-1 text-sm font-semibold text-text">{t("technician.profile.earningsTitle")}</p>
            <div className="grid grid-cols-2 gap-3 px-1">
              <div>
                <p className="text-xs text-text-muted">{t("technician.profile.revenue30d")}</p>
                <p className="text-lg font-semibold text-text">{formatCurrency(stats.data.revenue30d)}</p>
              </div>
              <div>
                <p className="text-xs text-text-muted">{t("technician.profile.jobs30d")}</p>
                <p className="text-lg font-semibold text-text">{stats.data.jobs30d}</p>
              </div>
            </div>
          </Card>

          <Card className="flex-row items-center gap-3">
            <span className="flex size-10 shrink-0 items-center justify-center rounded-full bg-warning/10 text-warning">
              <Star className="size-5 fill-warning" />
            </span>
            <div>
              <p className="text-sm font-semibold text-text">
                {stats.data.avgRating != null ? t("technician.profile.ratingValue", { rating: stats.data.avgRating.toFixed(1) }) : t("technician.profile.noRatingsYet")}
              </p>
              <p className="text-xs text-text-muted">{t("technician.profile.ratingCount", { count: stats.data.ratingCount })}</p>
            </div>
          </Card>

          <Card className="flex-row items-center gap-3">
            <span className="flex size-10 shrink-0 items-center justify-center rounded-full bg-info/10 text-info">
              <TrendingUp className="size-5" />
            </span>
            <div>
              <p className="text-sm font-semibold text-text">{t("technician.profile.kpiTitle")}</p>
              <p className="text-xs text-text-muted">{t("technician.profile.kpiNote")}</p>
            </div>
          </Card>
        </>
      )}

      <Button type="button" variant="outline" onClick={() => navigate("/technician/day-sheet")}>
        <CalendarRange className="size-4" />
        {t("technician.daySheet.viewLink")}
      </Button>

      <Button type="button" variant="destructive" onClick={() => signOut()}>
        <LogOut className="size-4" />
        {t("shell.signOut")}
      </Button>
    </div>
  )
}
