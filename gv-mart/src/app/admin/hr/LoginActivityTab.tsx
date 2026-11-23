import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { SegButton } from "@/components/shared/SegButton"
import { StatusDot } from "@/components/shared/StatusDot"
import { useDebouncedValue } from "@/hooks/useDebouncedValue"
import { useLoginActivity } from "@/hooks/useLoginActivity"
import { formatDateTime } from "@/lib/formatDate"
import {
  LOGIN_ACTIVITY_PAGE_SIZE,
  LOGIN_ROLE_FILTERS,
  describeDevice,
  formatDuration,
  sessionDurationMinutes,
  type LoginActivityRow,
  type LoginRoleFilter,
} from "@/services/loginActivity"

/** Today's IST calendar date as YYYY-MM-DD, independent of the viewer's device timezone. */
function istToday(offsetDays = 0) {
  return new Date(Date.now() + offsetDays * 86_400_000).toLocaleDateString("en-CA", { timeZone: "Asia/Kolkata" })
}

export function LoginActivityTab() {
  const { t } = useTranslation()
  const [from, setFrom] = useState(() => istToday(-6))
  const [to, setTo] = useState(() => istToday())
  const [role, setRole] = useState<LoginRoleFilter>("all")
  const [searchInput, setSearchInput] = useState("")
  const search = useDebouncedValue(searchInput.trim(), 300)
  const [page, setPage] = useState(0)

  const { data, isLoading, isError, isFetching, refetch, valid } = useLoginActivity({ from, to, role, search, page })
  const total = data?.total ?? 0
  const pageCount = Math.max(1, Math.ceil(total / LOGIN_ACTIVITY_PAGE_SIZE))

  // Any filter change goes back to the first page.
  function update<T>(setter: (v: T) => void) {
    return (v: T) => {
      setter(v)
      setPage(0)
    }
  }

  const columns: DataTableColumn<LoginActivityRow>[] = [
    {
      key: "name",
      header: t("hr.loginActivity.name"),
      render: (r) => (
        <div>
          <p className="font-medium text-text">{r.full_name ?? "—"}</p>
          {r.phone ? <p className="text-xs text-text-muted">{r.phone}</p> : null}
        </div>
      ),
    },
    { key: "role", header: t("hr.loginActivity.role"), render: (r) => (r.role ? t(`hr.loginActivity.roles.${r.role}`, r.role) : "—") },
    { key: "login", header: t("hr.loginActivity.login"), render: (r) => formatDateTime(r.started_at) },
    { key: "lastActive", header: t("hr.loginActivity.lastActive"), render: (r) => formatDateTime(r.last_seen_at) },
    {
      key: "logout",
      header: t("hr.loginActivity.logout"),
      render: (r) => (r.ended_at ? formatDateTime(r.ended_at) : <StatusDot tone="success" label={t("hr.loginActivity.signedIn")} />),
    },
    { key: "duration", header: t("hr.loginActivity.duration"), render: (r) => formatDuration(sessionDurationMinutes(r)) },
    { key: "device", header: t("hr.loginActivity.device"), render: (r) => describeDevice(r.user_agent) ?? "—" },
  ]

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end gap-3">
        <div className="space-y-1">
          <Label htmlFor="login-from" className="text-sm">{t("hr.loginActivity.from")}</Label>
          <Input id="login-from" type="date" value={from} max={to} onChange={(e) => update(setFrom)(e.target.value)} className="w-40" />
        </div>
        <div className="space-y-1">
          <Label htmlFor="login-to" className="text-sm">{t("hr.loginActivity.to")}</Label>
          <Input id="login-to" type="date" value={to} min={from} onChange={(e) => update(setTo)(e.target.value)} className="w-40" />
        </div>
        <div className="min-w-48 flex-1 space-y-1">
          <Label htmlFor="login-search" className="text-sm">{t("hr.loginActivity.search")}</Label>
          <Input
            id="login-search"
            type="search"
            maxLength={100}
            value={searchInput}
            placeholder={t("hr.loginActivity.searchPlaceholder")}
            onChange={(e) => {
              setSearchInput(e.target.value)
              setPage(0)
            }}
          />
        </div>
      </div>

      <div role="group" aria-label={t("hr.loginActivity.role")} className="flex gap-[3px] self-start rounded-full border border-border bg-surface-alt p-1 w-fit">
        {LOGIN_ROLE_FILTERS.map((r) => (
          <SegButton key={r} active={role === r} onClick={() => update(setRole)(r)}>
            {t(`hr.loginActivity.filters.${r}`)}
          </SegButton>
        ))}
      </div>

      {!valid ? <p role="alert" className="text-sm text-danger">{t("hr.loginActivity.invalidRange")}</p> : null}

      <DataTable
        columns={columns}
        rows={valid ? data?.rows ?? [] : []}
        rowKey={(r) => r.session_id}
        loading={valid && isLoading}
        error={isError ? t("hr.loginActivity.loadFailed") : null}
        onRetry={() => refetch()}
        emptyMessage={t("hr.loginActivity.empty")}
      />

      {valid && total > 0 ? (
        <div className="flex items-center justify-between gap-2 text-sm text-text-muted">
          <span aria-live="polite">
            {t("hr.loginActivity.pageInfo", { page: page + 1, pages: pageCount, total })}
          </span>
          <div className="flex gap-2">
            <Button variant="outline" size="sm" disabled={page === 0 || isFetching} onClick={() => setPage((p) => p - 1)}>
              {t("hr.loginActivity.prev")}
            </Button>
            <Button variant="outline" size="sm" disabled={page + 1 >= pageCount || isFetching} onClick={() => setPage((p) => p + 1)}>
              {t("hr.loginActivity.next")}
            </Button>
          </div>
        </div>
      ) : null}

      <p className="text-xs text-text-muted">{t("hr.loginActivity.note")}</p>
    </div>
  )
}
