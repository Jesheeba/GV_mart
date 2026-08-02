import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { Bell, CheckCheck } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { useProfile } from "@/hooks/useProfile"
import { useAllMyNotifications, useMarkAllNotificationsRead, useMarkNotificationRead, useMyNotificationTypes } from "@/hooks/useSystemPages"
import { cn } from "@/lib/utils"

export function NotificationsPage() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const [type, setType] = useState("")
  const [readStatus, setReadStatus] = useState<"read" | "unread" | "">("")

  const filters = useMemo(() => ({ type: type || undefined, readStatus: readStatus || undefined }), [type, readStatus])
  const { data, isLoading, isError, refetch } = useAllMyNotifications(profile?.org_id, profile?.id, profile?.role, filters)
  const markRead = useMarkNotificationRead()
  const markAllRead = useMarkAllNotificationsRead()

  const { data: typeOptions } = useMyNotificationTypes(profile?.org_id, profile?.id, profile?.role)
  const unreadIds = useMemo(() => (data ?? []).filter((n) => !n.is_read).map((n) => n.id), [data])

  return (
    <div className="space-y-4 pt-2">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold text-text">{t("nav.notifications")}</h1>
          <p className="text-sm text-text-muted">{t("notifications.subtitle")}</p>
        </div>
        <Button type="button" variant="outline" size="sm" disabled={unreadIds.length === 0 || markAllRead.isPending} onClick={() => markAllRead.mutate(unreadIds)}>
          <CheckCheck className="size-3.5" />
          {t("notifications.markAllRead")}
        </Button>
      </div>

      <Card size="sm" className="flex-row flex-wrap items-center gap-2 px-4">
        <div className="space-y-1">
          <label className="block text-xs font-medium text-text-muted">{t("notifications.filters.type")}</label>
          <select value={type} onChange={(e) => setType(e.target.value)} className="h-9 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none">
            <option value="">{t("notifications.filters.all")}</option>
            {(typeOptions ?? []).map((tOpt) => (
              <option key={tOpt} value={tOpt}>
                {t(`notifications.types.${tOpt}`, { defaultValue: tOpt })}
              </option>
            ))}
          </select>
        </div>
        <div className="space-y-1">
          <label className="block text-xs font-medium text-text-muted">{t("notifications.filters.status")}</label>
          <select
            value={readStatus}
            onChange={(e) => setReadStatus(e.target.value as "read" | "unread" | "")}
            className="h-9 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
          >
            <option value="">{t("notifications.filters.all")}</option>
            <option value="unread">{t("notifications.filters.unread")}</option>
            <option value="read">{t("notifications.filters.read")}</option>
          </select>
        </div>
      </Card>

      {isError ? (
        <Card className="items-center gap-2 py-8 text-center px-5">
          <p className="text-sm text-danger">{t("notifications.loadFailed")}</p>
          <Button type="button" variant="outline" size="sm" onClick={() => refetch()}>
            {t("common.retry")}
          </Button>
        </Card>
      ) : isLoading ? (
        <Card className="items-center py-8 text-center px-5">
          <p className="text-sm text-text-muted">{t("common.loading")}</p>
        </Card>
      ) : (data?.length ?? 0) === 0 ? (
        <Card className="items-center gap-2 py-10 text-center px-5">
          <Bell className="size-6 text-text-muted" />
          <p className="text-sm text-text-muted">{t("notifications.empty")}</p>
        </Card>
      ) : (
        <div className="space-y-2">
          {data!.map((n) => (
            <Card key={n.id} size="sm" className={cn("flex-row items-start justify-between gap-3 px-4", !n.is_read && "border-info/40 bg-info/5")}>
              <div className="min-w-0">
                <div className="flex items-center gap-2">
                  <p className="text-sm font-semibold text-text">{n.title}</p>
                  <span className="rounded-full bg-surface-alt px-2 py-0.5 text-[10px] font-medium text-text-muted">
                    {t(`notifications.types.${n.type}`, { defaultValue: n.type })}
                  </span>
                </div>
                {n.body ? <p className="mt-0.5 text-xs text-text-muted">{n.body}</p> : null}
                <p className="mt-1 text-[10px] text-text-muted">{new Date(n.created_at).toLocaleString()}</p>
              </div>
              {!n.is_read ? (
                <Button type="button" size="xs" variant="ghost" onClick={() => markRead.mutate({ id: n.id })}>
                  {t("notifications.markRead")}
                </Button>
              ) : (
                <span className="shrink-0 text-[10px] text-text-muted">{t("notifications.readLabel")}</span>
              )}
            </Card>
          ))}
        </div>
      )}
    </div>
  )
}
