import { useEffect } from "react"
import { useTranslation } from "react-i18next"
import { useProfile } from "@/hooks/useProfile"
import { useRefreshOperationalAlerts } from "@/hooks/useService"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { OwnerDashboard } from "./dashboard/OwnerDashboard"
import { OpsDashboard } from "./dashboard/OpsDashboard"
import { SalesDashboard } from "./dashboard/SalesDashboard"

export function DashboardPage() {
  const { t } = useTranslation()
  const { data: profile, isLoading, isError, refetch } = useProfile()
  const orgId = profile?.org_id
  const refreshAlerts = useRefreshOperationalAlerts(orgId)

  // Operational alerts (SLA breach / stuck handovers) have no scheduler to
  // run on (no pg_cron in this environment) — computed on page load instead,
  // same "mutate once per org" pattern as AmcWarrantyListPage.tsx's
  // refresh_amc_statuses call. The dashboard is the first page every staff
  // role lands on, so this is where that once-per-visit scan runs.
  useEffect(() => {
    if (orgId) refreshAlerts.mutate()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [orgId])

  if (isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError || !profile) {
    return <FullPageError message={t("auth.profileLoadError")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  const firstName = profile.full_name.split(" ")[0]
  if (profile.role === "operation_admin") return <OpsDashboard orgId={profile.org_id} firstName={firstName} />
  if (profile.role === "sales_admin") return <SalesDashboard orgId={profile.org_id} firstName={firstName} />
  return <OwnerDashboard orgId={profile.org_id} firstName={firstName} />
}
