import { useTranslation } from "react-i18next"
import { TriangleAlert } from "lucide-react"
import { Card } from "@/components/ui/card"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { useAllTechnicianStock, useSpareHandovers, useSpareReturns } from "@/hooks/useTechniciansAdmin"
import { buildStockLog, type StockLogEntry, type TechnicianStockLevelItem } from "@/services/techniciansAdmin"

/**
 * Group 5 — manager-facing visibility: who holds what (per-technician van
 * balance), which rows are low relative to the spare's own warehouse
 * `min_stock` (same threshold InventoryPage already uses), and a combined
 * chronological handover/return log.
 */
export function TechniciansStockLevelsTab({ orgId }: { orgId: string | undefined }) {
  const { t } = useTranslation()
  const stock = useAllTechnicianStock(orgId)
  const handovers = useSpareHandovers(orgId)
  const returns = useSpareReturns(orgId)

  const stockColumns: DataTableColumn<TechnicianStockLevelItem>[] = [
    { key: "technician", header: t("technicians.spares.technician"), render: (r) => r.technicians?.profiles?.full_name ?? "—" },
    {
      key: "spare",
      header: t("technicians.spares.spareColumn"),
      render: (r) => (
        <span className="flex items-center gap-1.5">
          {r.spares?.name ?? "?"} {r.spares?.sku ? <span className="text-xs text-text-muted">({r.spares.sku})</span> : null}
        </span>
      ),
    },
    {
      key: "qty",
      header: t("technicians.spares.qty"),
      render: (r) => {
        const low = r.spares?.min_stock != null && r.stock_qty > 0 && r.stock_qty <= r.spares.min_stock
        return (
          <span className={low ? "inline-flex items-center gap-1 font-semibold text-warning" : "font-medium text-text"}>
            {low ? <TriangleAlert className="size-3.5" /> : null}
            {r.stock_qty}
            {low ? ` (${t("technicians.spares.lowStockBadge")})` : ""}
          </span>
        )
      },
    },
  ]

  const logColumns: DataTableColumn<StockLogEntry>[] = [
    { key: "date", header: t("technicians.spares.date"), render: (r) => new Date(r.date).toLocaleDateString("en-IN") },
    {
      key: "kind",
      header: t("technicians.spares.status"),
      render: (r) => (r.kind === "handover" ? t("technicians.spares.logKindHandover") : t("technicians.spares.logKindReturn")),
    },
    { key: "technician", header: t("technicians.spares.technician"), render: (r) => r.technicianName },
    {
      key: "items",
      header: t("technicians.spares.items"),
      render: (r) => <span className="text-xs text-text-muted">{r.items.length === 0 ? "—" : r.items.map((i) => `${i.name} ×${i.qty}`).join(", ")}</span>,
    },
  ]

  const log = buildStockLog(handovers.data ?? [], returns.data ?? [])

  return (
    <div className="space-y-4">
      <Card size="default">
        <div className="mb-2 px-1">
          <p className="text-sm font-semibold text-text">{t("technicians.spares.stockTitle")}</p>
          <p className="text-xs text-text-muted">{t("technicians.spares.stockSubtitle")}</p>
        </div>
        <DataTable
          columns={stockColumns}
          rows={stock.data ?? []}
          rowKey={(r) => r.id}
          loading={stock.isLoading}
          error={stock.isError ? t("technicians.spares.stockLoadFailed") : null}
          onRetry={() => stock.refetch()}
          emptyMessage={t("technicians.spares.stockEmpty")}
        />
      </Card>

      <Card size="default">
        <div className="mb-2 px-1">
          <p className="text-sm font-semibold text-text">{t("technicians.spares.logTitle")}</p>
        </div>
        <DataTable
          columns={logColumns}
          rows={log}
          rowKey={(r) => `${r.kind}:${r.id}`}
          loading={handovers.isLoading || returns.isLoading}
          error={handovers.isError || returns.isError ? t("technicians.spares.loadFailed") : null}
          onRetry={() => {
            handovers.refetch()
            returns.refetch()
          }}
          emptyMessage={t("technicians.spares.empty")}
        />
      </Card>
    </div>
  )
}
