import { useTranslation } from "react-i18next"
import { Star, TriangleAlert } from "lucide-react"
import { Card } from "@/components/ui/card"
import { Button } from "@/components/ui/button"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { useMyTechnician, usePendingReviews } from "@/hooks/useTechnician"
import { formatDate } from "@/lib/formatDate"

/**
 * Technician-facing "Pending reviews": customers from THIS technician's own
 * completed visits who haven't left a rating yet, so he can follow up with
 * them in person. Display-only — nothing is sent or messaged from here.
 *
 * Ownership (technician B must never see technician A's customers) is
 * enforced server-side (RLS + public.list_technician_pending_reviews(),
 * SECURITY INVOKER) — see that migration's header comment. This screen just
 * renders whatever the RPC returns for the signed-in technician.
 *
 * Loading vs. error vs. genuinely-empty are three visibly different states
 * on purpose: a failed/offline fetch must never render the same "nothing to
 * do" card a real empty result does, or a technician could wrongly believe
 * every customer has reviewed them when the list simply failed to load.
 */
export function PendingReviewsPage() {
  const { t } = useTranslation()
  const technician = useMyTechnician()
  const pendingReviews = usePendingReviews(technician.data?.id)

  if (technician.isLoading) return <FullPageLoader label={t("common.loading")} />
  if (technician.isError || !technician.data) {
    return <FullPageError message={t("technician.errors.loadFailed")} onRetry={() => technician.refetch()} retryLabel={t("common.retry")} />
  }

  return (
    <div className="space-y-4 pt-2">
      <div>
        <h1 className="text-xl font-bold text-text">{t("technician.pendingReviews.title")}</h1>
        <p className="text-sm text-text-muted">{t("technician.pendingReviews.subtitle")}</p>
      </div>

      {pendingReviews.isLoading ? (
        <Card className="items-center py-8 text-center">
          <p className="text-sm text-text-muted">{t("common.loading")}</p>
        </Card>
      ) : pendingReviews.isError ? (
        // Distinct from the empty state below: a red warning card with a retry
        // action, never the plain "all caught up" empty card — a failed fetch
        // must look nothing like a genuinely empty, fully-reviewed result.
        <Card className="items-center gap-2 border-danger/30 bg-danger/5 py-8 text-center">
          <TriangleAlert className="size-8 text-danger" />
          <p className="text-sm font-medium text-danger">{t("technician.errors.loadFailed")}</p>
          <Button type="button" variant="outline" size="sm" onClick={() => pendingReviews.refetch()}>
            {t("common.retry")}
          </Button>
        </Card>
      ) : !pendingReviews.data || pendingReviews.data.length === 0 ? (
        <Card className="items-center gap-2 py-8 text-center">
          <Star className="size-8 text-text-muted" />
          <p className="text-sm font-medium text-text">{t("technician.pendingReviews.emptyTitle")}</p>
          <p className="text-xs text-text-muted">{t("technician.pendingReviews.emptyBody")}</p>
        </Card>
      ) : (
        <div className="space-y-2.5">
          {pendingReviews.data.map((row) => (
            <Card key={row.visit_id} className="gap-2">
              <div className="flex items-start justify-between gap-2 px-1">
                <div className="min-w-0">
                  <p className="truncate text-sm font-semibold text-text">{row.customer_name || t("technician.pendingReviews.customerFallback")}</p>
                  <p className="truncate text-xs text-text-muted">{row.complaint || t("technician.pendingReviews.noComplaint")}</p>
                </div>
                <a
                  href={`tel:${row.customer_mobile}`}
                  className="shrink-0 rounded-full border border-border px-3 py-1 text-xs font-medium text-accent hover:bg-surface-alt"
                >
                  {row.customer_mobile}
                </a>
              </div>
              <div className="flex items-center gap-2 px-1">
                <Star className="size-3.5 text-text-muted" />
                <span className="text-xs text-text-muted">
                  {t("technician.pendingReviews.completedOn", { date: formatDate(row.visit_completed_at) })}
                </span>
              </div>
            </Card>
          ))}
        </div>
      )}
    </div>
  )
}
