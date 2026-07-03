import { useTranslation } from "react-i18next"
import { IndianRupee, ReceiptText, ShieldCheck, Target, TriangleAlert, UserCheck } from "lucide-react"
import { KpiCard } from "@/components/shared/KpiCard"
import { HighlightKpiCard } from "@/components/shared/HighlightKpiCard"
import { useProfile } from "@/hooks/useProfile"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"

export function DashboardPage() {
  const { t } = useTranslation()
  const { data: profile, isLoading, isError, refetch } = useProfile()

  if (isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError || !profile) {
    return <FullPageError message={t("auth.profileLoadError")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  const subtitleKey =
    profile.role === "master"
      ? "dashboard.masterSubtitle"
      : profile.role === "operation_admin"
        ? "dashboard.operationAdminSubtitle"
        : "dashboard.salesAdminSubtitle"

  return (
    <div className="space-y-6 pt-2">
      <div>
        <h1 className="text-2xl font-bold text-text">{t("dashboard.welcomeBack", { name: profile.full_name.split(" ")[0] })}</h1>
        <p className="text-sm text-text-muted">{t(subtitleKey)}</p>
      </div>

      {profile.role === "master" && (
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <HighlightKpiCard
            label={t("dashboard.totalRevenue")}
            value="₹4,82,650"
            caption={t("common.thisMonth")}
            icon={<IndianRupee className="size-4" />}
          />
          <KpiCard label={t("dashboard.todaysSales")} value="₹18,200" icon={<ReceiptText className="size-4" />} delta={{ value: 12.4 }} />
          <KpiCard label={t("dashboard.openTickets")} value="7" icon={<TriangleAlert className="size-4" />} delta={{ value: -4 }} />
          <KpiCard label={t("dashboard.activeTechnicians")} value="5" icon={<UserCheck className="size-4" />} />
        </div>
      )}

      {profile.role === "operation_admin" && (
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
          <HighlightKpiCard label={t("dashboard.openTickets")} value="7" caption={t("common.thisMonth")} icon={<TriangleAlert className="size-4" />} />
          <KpiCard label={t("dashboard.slaOverdue")} value="2" icon={<TriangleAlert className="size-4" />} delta={{ value: -1 }} />
          <KpiCard label={t("dashboard.activeTechnicians")} value="5" icon={<UserCheck className="size-4" />} />
        </div>
      )}

      {profile.role === "sales_admin" && (
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
          <HighlightKpiCard label={t("dashboard.todaysSales")} value="₹18,200" caption={t("common.thisMonth")} icon={<ReceiptText className="size-4" />} />
          <KpiCard label={t("dashboard.openQuotations")} value="9" icon={<ShieldCheck className="size-4" />} />
          <KpiCard label={t("dashboard.leadConversion")} value="34%" icon={<Target className="size-4" />} delta={{ value: 6.1 }} />
        </div>
      )}
    </div>
  )
}
