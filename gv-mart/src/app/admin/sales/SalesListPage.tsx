import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { Plus, Receipt } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { StatusDot, type StatusTone } from "@/components/shared/StatusDot"
import { useProfile } from "@/hooks/useProfile"
import { useInvoicesList } from "@/hooks/useSales"
import { formatCurrency } from "@/lib/sale-calc"
import type { InvoiceListItem } from "@/services/sales"

const PAYMENT_STATUS_TONE: Record<string, StatusTone> = { paid: "success", partial: "warning", due: "danger" }

export function SalesListPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data, isLoading, isError, refetch } = useInvoicesList(orgId)
  const rows = data ?? []

  const columns: DataTableColumn<InvoiceListItem>[] = [
    {
      key: "customer",
      header: t("sales.list.customer"),
      render: (inv) => (
        <div>
          <div className="font-medium text-text">{inv.customers?.name ?? "—"}</div>
          <div className="text-xs text-text-muted">{inv.customers?.mobile}</div>
        </div>
      ),
    },
    { key: "type", header: t("sales.list.type"), render: (inv) => t(`sales.invoice.type.${inv.type}`) },
    { key: "total", header: t("sales.list.total"), render: (inv) => formatCurrency(inv.total) },
    {
      key: "status",
      header: t("sales.list.paymentStatus"),
      render: (inv) => <StatusDot tone={PAYMENT_STATUS_TONE[inv.payment_status] ?? "neutral"} label={t(`sales.invoice.paymentStatus.${inv.payment_status}`)} />,
    },
    { key: "date", header: t("sales.list.date"), render: (inv) => new Date(inv.created_at).toLocaleDateString("en-IN") },
  ]

  return (
    <div className="space-y-4 pt-2">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold text-text">{t("sales.list.title")}</h1>
          <p className="text-sm text-text-muted">{t("sales.list.subtitle")}</p>
        </div>
        <Button variant="accent" onClick={() => navigate("/admin/sales/new")}>
          <Plus className="size-4" />
          {t("sales.list.newSaleButton")}
        </Button>
      </div>

      <Card size="default">
        {rows.length === 0 && !isLoading ? (
          <div className="flex flex-col items-center gap-3 py-12 text-center">
            <span className="flex size-12 items-center justify-center rounded-full bg-surface-alt text-text-muted">
              <Receipt className="size-6" />
            </span>
            <h2 className="text-lg font-semibold text-text">{t("sales.list.empty.title")}</h2>
            <p className="max-w-xs text-sm text-text-muted">{t("sales.list.empty.subtitle")}</p>
            <Button variant="accent" onClick={() => navigate("/admin/sales/new")}>
              {t("sales.list.newSaleButton")}
            </Button>
          </div>
        ) : (
          <DataTable
            columns={columns}
            rows={rows}
            rowKey={(inv) => inv.id}
            onRowClick={(inv) => navigate(`/admin/sales/invoices/${inv.id}`)}
            loading={isLoading}
            error={isError ? t("sales.list.error.loadFailed") : null}
            onRetry={() => refetch()}
            emptyMessage={t("sales.list.empty.title")}
          />
        )}
      </Card>
    </div>
  )
}
