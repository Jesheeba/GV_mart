import { useTranslation } from "react-i18next"
import { Flag, TriangleAlert } from "lucide-react"
import { Card } from "@/components/ui/card"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { useAllTechnicianStock, useSpareHandovers, useSpareReturns, useTechnicianSpareLedger } from "@/hooks/useTechniciansAdmin"
import { buildStockLog, type StockLogEntry, type TechnicianSpareLedgerRow, type TechnicianStockLevelItem } from "@/services/techniciansAdmin"
import { formatDate } from "@/lib/formatDate"

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
  const ledger = useTechnicianSpareLedger(orgId)

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
    { key: "date", header: t("technicians.spares.date"), render: (r) => formatDate(r.date) },
    {
      key: "kind",
      header: t("technicians.spares.status"),
      render: (r) => (
        <span className="inline-flex items-center gap-1">
          {r.kind === "handover" ? t("technicians.spares.logKindHandover") : t("technicians.spares.logKindReturn")}
          {r.disputed ? <Flag className="size-3.5 text-warning" aria-label={t("technicians.spares.disputedBadge")} /> : null}
        </span>
      ),
    },
    { key: "technician", header: t("technicians.spares.technician"), render: (r) => r.technicianName },
    // Requirement 2 (2026-11-14 gap fix): who gave it (hand-over rows only — a return has no
    // "given by", it's staff recording what came back).
    { key: "givenBy", header: t("technicians.spares.givenBy"), render: (r) => r.givenByName ?? "—" },
    {
      key: "items",
      header: t("technicians.spares.items"),
      render: (r) => <span className="text-xs text-text-muted">{r.items.length === 0 ? "—" : r.items.map((i) => `${i.name} ×${i.qty}`).join(", ")}</span>,
    },
  ]

  const ledgerColumns: DataTableColumn<TechnicianSpareLedgerRow>[] = [
    { key: "technician", header: t("technicians.spares.technician"), render: (r) => r.technician_name ?? "—" },
    {
      key: "spare",
      header: t("technicians.spares.spareColumn"),
      render: (r) => (
        <span className="flex items-center gap-1.5">
          {r.spare_name ?? "?"} {r.spare_sku ? <span className="text-xs text-text-muted">({r.spare_sku})</span> : null}
        </span>
      ),
    },
    { key: "handedOver", header: t("technicians.spares.ledgerHandedOver"), render: (r) => r.qty_handed_over },
    { key: "used", header: t("technicians.spares.ledgerUsed"), render: (r) => r.qty_used },
    { key: "returned", header: t("technicians.spares.ledgerReturned"), render: (r) => r.qty_returned },
    { key: "balance", header: t("technicians.spares.ledgerBalance"), render: (r) => <span className="font-semibold text-text">{r.balance}</span> },
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

      <Card size="default">
        <div className="mb-2 px-1">
          <p className="text-sm font-semibold text-text">{t("technicians.spares.ledgerTitle")}</p>
          <p className="text-xs text-text-muted">{t("technicians.spares.ledgerSubtitle")}</p>
        </div>
        <DataTable
          columns={ledgerColumns}
          rows={ledger.data ?? []}
          rowKey={(r) => `${r.technician_id}:${r.spare_id}`}
          loading={ledger.isLoading}
          error={ledger.isError ? t("technicians.spares.loadFailed") : null}
          onRetry={() => ledger.refetch()}
          emptyMessage={t("technicians.spares.empty")}
        />
      </Card>
    </div>
  )
}
