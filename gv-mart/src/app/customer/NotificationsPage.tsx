import { useMemo } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { ArrowLeft, Bell, CheckCheck } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { useProfile } from "@/hooks/useProfile"
import { useAllMyNotifications, useMarkAllNotificationsRead, useMarkNotificationRead } from "@/hooks/useSystemPages"
import { cn } from "@/lib/utils"

// Same role-generic notification hooks the admin/technician notification
// pages already use — no filter UI here either (matches the technician
// app's single-scrollable-list choice over the admin page's dropdown
// filters), just the plain list + per-card and bulk "mark read" actions.
const NO_FILTERS = {}

// Live tracking notifications (technician_assigned/service_started/
// service_completed) carry the ticket id as ref_id — unlike the technician-
// facing 'appointment_assigned' type, which uses the appointment id — see
// 20260804220000_customer_tracking_notifications.sql.
const TRACKING_DEEP_LINK_TYPES = new Set(["technician_assigned", "service_started", "service_completed"])

export function NotificationsPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { data: profile, isLoading, isError, refetch } = useProfile()
  const notifications = useAllMyNotifications(profile?.org_id, profile?.id, profile?.role, NO_FILTERS)
  const markRead = useMarkNotificationRead()
  const markAllRead = useMarkAllNotificationsRead()

  const unreadIds = useMemo(() => (notifications.data ?? []).filter((n) => !n.is_read).map((n) => n.id), [notifications.data])

  if (isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError || !profile) {
    return <FullPageError message={t("auth.profileLoadError")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  return (
    <div className="space-y-4 pb-4 pt-2">
      <button type="button" onClick={() => navigate(-1)} className="flex items-center gap-1.5 text-sm font-medium text-text-muted">
        <ArrowLeft className="size-4" />
        {t("common.back")}
      </button>

      <div className="flex items-center justify-between gap-3">
        <h1 className="text-xl font-bold text-text">{t("nav.notifications")}</h1>
        <Button type="button" variant="outline" size="sm" disabled={unreadIds.length === 0 || markAllRead.isPending} onClick={() => markAllRead.mutate(unreadIds)}>
          <CheckCheck className="size-3.5" />
          {t("notifications.markAllRead")}
        </Button>
      </div>

      {notifications.isError ? (
        <Card className="items-center gap-2 py-8 text-center lg:px-5">
          <p className="text-sm text-danger">{t("notifications.loadFailed")}</p>
          <Button type="button" variant="outline" size="sm" onClick={() => notifications.refetch()}>
            {t("common.retry")}
          </Button>
        </Card>
      ) : notifications.isLoading ? (
        <Card className="items-center py-8 text-center lg:px-5">
          <p className="text-sm text-text-muted">{t("common.loading")}</p>
        </Card>
      ) : (notifications.data?.length ?? 0) === 0 ? (
        <Card className="items-center gap-2 py-10 text-center lg:px-5">
          <Bell className="size-8 text-text-muted" />
          <p className="text-sm text-text-muted">{t("notifications.empty")}</p>
        </Card>
      ) : (
        <div className="space-y-2.5">
          {notifications.data!.map((n) => {
            const deepLink = TRACKING_DEEP_LINK_TYPES.has(n.type) && n.ref_id ? `/customer/bookings/${n.ref_id}` : null
            return (
            <Card
              key={n.id}
              size="sm"
              className={cn("gap-2 lg:px-5", !n.is_read && "border-info/40 bg-info/5", deepLink && "cursor-pointer hover:bg-surface-alt/60")}
              onClick={deepLink ? () => navigate(deepLink) : undefined}
            >
              <div className="flex items-start justify-between gap-2 px-1">
                <div className="min-w-0">
                  <p className="text-sm font-semibold text-text">{n.title}</p>
                  {n.body ? <p className="mt-0.5 text-xs text-text-muted">{n.body}</p> : null}
                </div>
                {!n.is_read ? <span className="mt-1 size-2 shrink-0 rounded-full bg-info" aria-hidden="true" /> : null}
              </div>
              <div className="flex items-center justify-between gap-2 px-1">
                <span className="text-[10px] text-text-muted">{new Date(n.created_at).toLocaleString()}</span>
                {!n.is_read ? (
                  <Button
                    type="button"
                    size="xs"
                    variant="ghost"
                    onClick={(e) => {
                      e.stopPropagation()
                      markRead.mutate({ id: n.id })
                    }}
                  >
                    {t("notifications.markRead")}
                  </Button>
                ) : (
                  <span className="text-[10px] text-text-muted">{t("notifications.readLabel")}</span>
                )}
              </div>
            </Card>
            )
          })}
        </div>
      )}
    </div>
  )
}
