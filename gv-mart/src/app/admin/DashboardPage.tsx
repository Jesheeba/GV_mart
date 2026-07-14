import { useTranslation } from "react-i18next"
import { useProfile } from "@/hooks/useProfile"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { OwnerDashboard } from "./dashboard/OwnerDashboard"
import { OpsDashboard } from "./dashboard/OpsDashboard"
import { SalesDashboard } from "./dashboard/SalesDashboard"

export function DashboardPage() {
  const { t } = useTranslation()
  const { data: profile, isLoading, isError, refetch } = useProfile()

  if (isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError || !profile) {
    return <FullPageError message={t("auth.profileLoadError")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  const firstName = profile.full_name.split(" ")[0]
  if (profile.role === "operation_admin") return <OpsDashboard orgId={profile.org_id} firstName={firstName} />
  if (profile.role === "sales_admin") return <SalesDashboard orgId={profile.org_id} firstName={firstName} />
  return <OwnerDashboard orgId={profile.org_id} firstName={firstName} />
}
