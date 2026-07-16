import { useMemo } from "react"
import { useTranslation } from "react-i18next"
import { Bell, CheckCheck } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { useProfile } from "@/hooks/useProfile"
import { useAllMyNotifications, useMarkAllNotificationsRead, useMarkNotificationRead } from "@/hooks/useSystemPages"
import { cn } from "@/lib/utils"

// No type/read-status filter UI here (unlike the admin notifications page) —
// the technician app favors a single scrollable list over dropdown filters.
// Unread vs read is still visible per-card, and "mark all read" covers the
// bulk action, so all four notification hooks stay reachable.
const NO_FILTERS = {}

export function NotificationsPage() {
  const { t } = useTranslation()
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
    <div className="space-y-4 pt-2">
      <div className="flex items-center justify-between gap-3">
        <h1 className="text-xl font-bold text-text">{t("nav.notifications")}</h1>
        <Button type="button" variant="outline" size="sm" disabled={unreadIds.length === 0 || markAllRead.isPending} onClick={() => markAllRead.mutate(unreadIds)}>
          <CheckCheck className="size-3.5" />
          {t("notifications.markAllRead")}
        </Button>
      </div>

      {notifications.isError ? (
        <Card className="items-center gap-2 py-8 text-center">
          <p className="text-sm text-danger">{t("notifications.loadFailed")}</p>
          <Button type="button" variant="outline" size="sm" onClick={() => notifications.refetch()}>
            {t("common.retry")}
          </Button>
        </Card>
      ) : notifications.isLoading ? (
        <Card className="items-center py-8 text-center">
          <p className="text-sm text-text-muted">{t("common.loading")}</p>
        </Card>
      ) : (notifications.data?.length ?? 0) === 0 ? (
        <Card className="items-center gap-2 py-10 text-center">
          <Bell className="size-8 text-text-muted" />
          <p className="text-sm text-text-muted">{t("notifications.empty")}</p>
        </Card>
      ) : (
        <div className="space-y-2.5">
          {notifications.data!.map((n) => (
            <Card key={n.id} className={cn("gap-2", !n.is_read && "border-info/40 bg-info/5")}>
              <div className="flex items-start justify-between gap-2">
                <div className="min-w-0">
                  <p className="text-sm font-semibold text-text">{n.title}</p>
                  {n.body ? <p className="mt-0.5 text-xs text-text-muted">{n.body}</p> : null}
                </div>
                {!n.is_read ? <span className="mt-1 size-2 shrink-0 rounded-full bg-info" aria-hidden="true" /> : null}
              </div>
              <div className="flex items-center justify-between gap-2">
                <span className="text-[10px] text-text-muted">{new Date(n.created_at).toLocaleString()}</span>
                {!n.is_read ? (
                  <Button type="button" size="xs" variant="ghost" onClick={() => markRead.mutate({ id: n.id })}>
                    {t("notifications.markRead")}
                  </Button>
                ) : (
                  <span className="text-[10px] text-text-muted">{t("notifications.readLabel")}</span>
                )}
              </div>
            </Card>
          ))}
        </div>
      )}
    </div>
  )
}
