import { useMemo } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { FileText, Plus } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { StatusDot, type StatusTone } from "@/components/shared/StatusDot"
import { KpiCard } from "@/components/shared/KpiCard"
import { useProfile } from "@/hooks/useProfile"
import { useQuotationsList } from "@/hooks/useQuotations"
import { formatCurrency } from "@/lib/sale-calc"
import type { QuotationListItem } from "@/services/quotations"

const STATUS_TONE: Record<string, StatusTone> = { open: "info", converted: "success", lost: "danger" }

export function QuotationsListPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data, isLoading, isError, refetch } = useQuotationsList(orgId)
  const rows = useMemo(() => data ?? [], [data])

  const stats = useMemo(() => {
    const open = rows.filter((r) => r.status === "open").length
    const converted = rows.filter((r) => r.status === "converted").length
    const lost = rows.filter((r) => r.status === "lost").length
    const decided = converted + lost
    const rate = decided > 0 ? Math.round((converted / decided) * 100) : 0
    return { open, converted, lost, rate }
  }, [rows])

  const columns: DataTableColumn<QuotationListItem>[] = [
    {
      key: "customer",
      header: t("quotations.table.customer"),
      render: (q) => (
        <div>
          <div className="font-medium text-text">{q.customers?.name ?? "—"}</div>
          <div className="text-xs text-text-muted">{q.customers?.mobile}</div>
        </div>
      ),
    },
    { key: "total", header: t("quotations.table.amount"), render: (q) => formatCurrency(q.total) },
    { key: "validUntil", header: t("quotations.table.validUntil"), render: (q) => (q.valid_until ? new Date(q.valid_until).toLocaleDateString("en-IN") : "—") },
    { key: "date", header: t("quotations.table.date"), render: (q) => new Date(q.created_at).toLocaleDateString("en-IN") },
    { key: "status", header: t("quotations.table.status"), render: (q) => <StatusDot tone={STATUS_TONE[q.status] ?? "neutral"} label={t(`quotations.status.${q.status}`)} /> },
  ]

  return (
    <div className="space-y-4 pt-2">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold text-text">{t("quotations.title")}</h1>
          <p className="text-sm text-text-muted">{t("quotations.subtitle")}</p>
        </div>
        <Button variant="accent" onClick={() => navigate("/admin/quotations/new")}>
          <Plus className="size-4" />
          {t("quotations.addButton")}
        </Button>
      </div>

      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <KpiCard label={t("quotations.stats.open")} value={stats.open} loading={isLoading} />
        <KpiCard label={t("quotations.stats.converted")} value={stats.converted} loading={isLoading} />
        <KpiCard label={t("quotations.stats.lost")} value={stats.lost} loading={isLoading} />
        <KpiCard label={t("quotations.stats.conversionRate")} value={`${stats.rate}%`} loading={isLoading} />
      </div>

      <Card size="default">
        {rows.length === 0 && !isLoading ? (
          <div className="flex flex-col items-center gap-3 py-12 text-center">
            <span className="flex size-12 items-center justify-center rounded-full bg-surface-alt text-text-muted">
              <FileText className="size-6" />
            </span>
            <h2 className="text-lg font-semibold text-text">{t("quotations.empty.title")}</h2>
            <p className="max-w-xs text-sm text-text-muted">{t("quotations.empty.subtitle")}</p>
            <Button variant="accent" onClick={() => navigate("/admin/quotations/new")}>
              {t("quotations.addButton")}
            </Button>
          </div>
        ) : (
          <DataTable
            columns={columns}
            rows={rows}
            rowKey={(q) => q.id}
            onRowClick={(q) => navigate(`/admin/quotations/${q.id}`)}
            loading={isLoading}
            error={isError ? t("quotations.error.loadFailed") : null}
            onRetry={() => refetch()}
            emptyMessage={t("quotations.empty.title")}
          />
        )}
      </Card>
    </div>
  )
}
