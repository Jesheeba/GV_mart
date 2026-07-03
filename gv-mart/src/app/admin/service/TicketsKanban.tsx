import { useTranslation } from "react-i18next"
import { Repeat, TriangleAlert } from "lucide-react"
import { Card } from "@/components/ui/card"
import { Skeleton } from "@/components/ui/skeleton"
import { Button } from "@/components/ui/button"
import type { TicketListItem, TicketStatus } from "@/services/service"
import { SlaCountdown } from "./SlaCountdown"
import { PriorityBadge, TicketTypeBadge } from "./TicketBadges"

const COLUMNS: TicketStatus[] = ["open", "assigned", "in_progress", "completed", "cancelled"]

/** Kanban-by-status view (ADM-09 "table + kanban toggle"). Read-only board —
 * drag-to-reassign lives on the Appointments screen (ADM-11), where
 * technician assignment (not ticket status) is what's being dragged. */
export function TicketsKanban({
  rows,
  loading,
  error,
  onRetry,
  onCardClick,
  repeatCustomers,
}: {
  rows: TicketListItem[]
  loading: boolean
  error: string | null
  onRetry: () => void
  onCardClick: (row: TicketListItem) => void
  repeatCustomers?: Set<string>
}) {
  const { t } = useTranslation()

  if (error) {
    return (
      <Card className="items-center gap-3 py-12 text-center">
        <TriangleAlert className="size-6 text-danger" />
        <p className="text-sm text-text-muted">{error}</p>
        <Button variant="outline" size="sm" onClick={onRetry}>
          {t("common.retry")}
        </Button>
      </Card>
    )
  }

  return (
    <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-5">
      {COLUMNS.map((col) => {
        const colRows = rows.filter((r) => r.status === col)
        return (
          <div key={col} className="space-y-2">
            <div className="flex items-center justify-between px-1">
              <h3 className="text-sm font-semibold text-text">{t(`service.status.${col}`)}</h3>
              <span className="text-xs text-text-muted">{loading ? "…" : colRows.length}</span>
            </div>
            <div className="space-y-2">
              {loading ? (
                Array.from({ length: 2 }).map((_, i) => <Skeleton key={i} className="h-24 w-full rounded-subcard" />)
              ) : colRows.length === 0 ? (
                <Card size="sm" className="items-center py-6 text-center text-xs text-text-muted">
                  {t("service.kanban.empty")}
                </Card>
              ) : (
                colRows.map((r) => (
                  <button key={r.id} type="button" onClick={() => onCardClick(r)} className="block w-full text-left">
                    <Card size="sm" className="gap-2 hover:border-accent/50">
                      <div className="flex items-center justify-between">
                        <span className="text-xs font-medium text-text-muted">#{r.id.slice(0, 8)}</span>
                        {repeatCustomers?.has(r.customer_id) ? <Repeat className="size-3.5 text-warning" /> : null}
                      </div>
                      <div className="text-sm font-medium text-text">{r.customers?.name ?? "—"}</div>
                      <div className="truncate text-xs text-text-muted">{r.name_of_complaint || "—"}</div>
                      <div className="flex flex-wrap items-center gap-1.5">
                        <TicketTypeBadge type={r.type} />
                        <PriorityBadge priority={r.priority} />
                      </div>
                      <SlaCountdown slaDueAt={r.sla_due_at} status={r.status} />
                    </Card>
                  </button>
                ))
              )}
            </div>
          </div>
        )
      })}
    </div>
  )
}
