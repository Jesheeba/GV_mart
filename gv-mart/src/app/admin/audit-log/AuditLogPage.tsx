import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { ChevronDown, ChevronRight, History, Search } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { useProfile } from "@/hooks/useProfile"
import { useAuditLog, useAuditLogTableNames } from "@/hooks/useSystemPages"
import type { AuditLogRow } from "@/services/systemPages"
import { useDebouncedValue } from "@/hooks/useDebouncedValue"

function JsonDiff({ before, after }: { before: unknown; after: unknown }) {
  const { t } = useTranslation()
  return (
    <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
      <div>
        <p className="mb-1 text-xs font-semibold text-text-muted">{t("auditLog.before")}</p>
        <pre className="max-h-64 overflow-auto rounded-lg bg-surface-alt p-2.5 text-[11px] text-text">
          {before ? JSON.stringify(before, null, 2) : t("auditLog.none")}
        </pre>
      </div>
      <div>
        <p className="mb-1 text-xs font-semibold text-text-muted">{t("auditLog.after")}</p>
        <pre className="max-h-64 overflow-auto rounded-lg bg-surface-alt p-2.5 text-[11px] text-text">
          {after ? JSON.stringify(after, null, 2) : t("auditLog.none")}
        </pre>
      </div>
    </div>
  )
}

function AuditLogEntry({ row }: { row: AuditLogRow }) {
  const { t } = useTranslation()
  const [expanded, setExpanded] = useState(false)

  return (
    <Card size="sm" className="gap-2 px-4">
      <button type="button" onClick={() => setExpanded((v) => !v)} className="flex w-full items-center justify-between gap-3 text-left">
        <div className="flex min-w-0 items-center gap-2">
          {expanded ? <ChevronDown className="size-3.5 shrink-0 text-text-muted" /> : <ChevronRight className="size-3.5 shrink-0 text-text-muted" />}
          <div className="min-w-0">
            <p className="truncate text-sm font-medium text-text">
              <span className="rounded-full bg-surface-alt px-2 py-0.5 text-xs font-semibold">{row.action}</span>{" "}
              <span className="text-text-muted">{row.table_name}</span>
            </p>
            <p className="truncate text-xs text-text-muted">
              {row.actor?.full_name ?? t("auditLog.systemActor")} · {new Date(row.created_at).toLocaleString()}
              {row.row_id ? ` · #${row.row_id.slice(0, 8)}` : ""}
            </p>
          </div>
        </div>
      </button>
      {expanded ? <JsonDiff before={row.before} after={row.after} /> : null}
    </Card>
  )
}

export function AuditLogPage() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const [tableName, setTableName] = useState("")
  const [from, setFrom] = useState("")
  const [to, setTo] = useState("")
  const [searchInput, setSearchInput] = useState("")
  const search = useDebouncedValue(searchInput, 300)

  const filters = useMemo(
    () => ({ tableName: tableName || undefined, from: from || undefined, to: to || undefined, search: search || undefined }),
    [tableName, from, to, search]
  )
  const { data, isLoading, isError, refetch } = useAuditLog(profile?.org_id, filters)
  const tableNames = useAuditLogTableNames(profile?.org_id)

  return (
    <div className="space-y-4 pt-2">
      <div>
        <h1 className="text-2xl font-bold text-text">{t("nav.auditLog")}</h1>
        <p className="text-sm text-text-muted">{t("auditLog.subtitle")}</p>
      </div>

      <Card size="sm" className="flex-row flex-wrap items-end gap-2 px-4">
        <div className="space-y-1">
          <label className="block text-xs font-medium text-text-muted">{t("auditLog.filters.search")}</label>
          <div className="relative">
            <Search className="pointer-events-none absolute top-1/2 left-3 size-3.5 -translate-y-1/2 text-text-muted" />
            <Input value={searchInput} onChange={(e) => setSearchInput(e.target.value)} placeholder={t("auditLog.filters.searchPlaceholder")} className="h-9 pl-8" />
          </div>
        </div>
        <div className="space-y-1">
          <label className="block text-xs font-medium text-text-muted">{t("auditLog.filters.table")}</label>
          <select value={tableName} onChange={(e) => setTableName(e.target.value)} className="h-9 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none">
            <option value="">{t("auditLog.filters.all")}</option>
            {(tableNames.data ?? []).map((tn) => (
              <option key={tn} value={tn}>
                {tn}
              </option>
            ))}
          </select>
        </div>
        <div className="space-y-1">
          <label className="block text-xs font-medium text-text-muted">{t("auditLog.filters.from")}</label>
          <input type="date" value={from} onChange={(e) => setFrom(e.target.value)} className="h-9 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none" />
        </div>
        <div className="space-y-1">
          <label className="block text-xs font-medium text-text-muted">{t("auditLog.filters.to")}</label>
          <input type="date" value={to} onChange={(e) => setTo(e.target.value)} className="h-9 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none" />
        </div>
        {tableName || from || to || searchInput ? (
          <Button
            size="sm"
            variant="ghost"
            onClick={() => {
              setTableName("")
              setFrom("")
              setTo("")
              setSearchInput("")
            }}
          >
            {t("auditLog.filters.clear")}
          </Button>
        ) : null}
      </Card>

      {isError ? (
        <Card className="items-center gap-2 py-8 text-center">
          <p className="text-sm text-danger">{t("auditLog.loadFailed")}</p>
          <Button type="button" variant="outline" size="sm" onClick={() => refetch()}>
            {t("common.retry")}
          </Button>
        </Card>
      ) : isLoading ? (
        <Card className="items-center py-8 text-center">
          <p className="text-sm text-text-muted">{t("common.loading")}</p>
        </Card>
      ) : (data?.length ?? 0) === 0 ? (
        <Card className="items-center gap-2 py-10 text-center">
          <History className="size-6 text-text-muted" />
          <p className="text-sm text-text-muted">{t("auditLog.empty")}</p>
        </Card>
      ) : (
        <div className="space-y-2">
          {data!.map((row) => (
            <AuditLogEntry key={row.id} row={row} />
          ))}
        </div>
      )}
    </div>
  )
}
