import { useTranslation } from "react-i18next"
import { Check, Repeat, TriangleAlert } from "lucide-react"
import { Card } from "@/components/ui/card"
import { Skeleton } from "@/components/ui/skeleton"
import { Button } from "@/components/ui/button"
import { cn } from "@/lib/utils"
import type { TicketListItem, TicketStatus } from "@/services/service"
import { TYPE_BADGE_CLASS } from "./TicketBadges"

// Design (design-template-decoded.html lines 988-1007) only shows 4 columns —
// Open / Assigned / In progress / Done — with muted styling on the first two
// and tone-colored styling on the last two. "Cancelled" isn't in the mock,
// but real tickets can carry that status; a 5th column (styled like the
// muted Open/Assigned pair) is added so cancelled tickets aren't silently
// dropped from the board.
const COLUMNS: { status: TicketStatus; toned: "muted" | "warning" | "success" }[] = [
  { status: "open", toned: "muted" },
  { status: "assigned", toned: "muted" },
  { status: "in_progress", toned: "warning" },
  { status: "completed", toned: "success" },
  { status: "cancelled", toned: "muted" },
]

const COLUMN_HEADER_LABEL: Record<string, string> = {
  muted: "text-text-muted",
  warning: "text-warning",
  success: "text-success",
}
const COLUMN_COUNT_PILL: Record<string, string> = {
  muted: "border border-border bg-surface text-text-muted",
  warning: "bg-[#FCF1DF] text-warning",
  success: "bg-[#E7F6ED] text-success",
}

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
  const now = Date.now()

  if (error) {
    return (
      <Card className="items-center gap-3 py-12 text-center px-5">
        <TriangleAlert className="size-6 text-danger" />
        <p className="text-sm text-text-muted">{error}</p>
        <Button variant="outline" size="sm" onClick={onRetry}>
          {t("common.retry")}
        </Button>
      </Card>
    )
  }

  return (
    <div className="grid grid-cols-1 gap-[14px] sm:grid-cols-2 lg:grid-cols-5">
      {COLUMNS.map(({ status, toned }) => {
        const colRows = rows.filter((r) => r.status === status)
        return (
          <div key={status} className="rounded-[18px] border border-border bg-surface-alt p-3.5">
            <div className="mb-3 flex items-center justify-between">
              <h3 className={cn("text-xs font-bold", COLUMN_HEADER_LABEL[toned])}>{t(`service.kanban.columns.${status}`)}</h3>
              <span className={cn("rounded-full px-2 py-0.5 text-[11px] font-bold", COLUMN_COUNT_PILL[toned])}>
                {loading ? "…" : colRows.length}
              </span>
            </div>
            <div className="space-y-[9px]">
              {loading ? (
                Array.from({ length: 2 }).map((_, i) => <Skeleton key={i} className="h-20 w-full rounded-[13px]" />)
              ) : colRows.length === 0 ? (
                <div className="rounded-[13px] border border-border bg-surface px-3 py-6 text-center text-xs text-text-muted">
                  {t("service.kanban.empty")}
                </div>
              ) : (
                colRows.map((r) => <TicketKanbanCard key={r.id} row={r} now={now} onClick={() => onCardClick(r)} repeat={repeatCustomers?.has(r.customer_id)} />)
              )}
            </div>
          </div>
        )
      })}
    </div>
  )
}

function TicketKanbanCard({
  row,
  now,
  onClick,
  repeat,
}: {
  row: TicketListItem
  now: number
  onClick: () => void
  repeat?: boolean
}) {
  const { t } = useTranslation()
  const overdue = !!row.sla_due_at && row.status !== "completed" && row.status !== "cancelled" && new Date(row.sla_due_at).getTime() <= now

  return (
    <button
      type="button"
      onClick={onClick}
      className={cn(
        "block w-full rounded-[13px] border bg-surface p-3 text-left",
        overdue ? "border-[#F5C9CB]" : "border-border",
        row.status === "completed" ? "opacity-75" : ""
      )}
    >
      <div className="mb-1.5 flex items-center justify-between gap-2">
        <span className="flex min-w-0 items-center gap-1 text-[11px] font-bold text-ink">
          #{row.id.slice(0, 8)}
          {repeat ? <Repeat className="size-3 shrink-0 text-warning" aria-label={t("service.table.repeatComplaint")} /> : null}
        </span>
        <CardStatusBadge row={row} now={now} overdue={overdue} />
      </div>
      <div className="text-xs font-semibold text-ink">{row.customers?.name ?? "—"}</div>
      <div className="truncate text-[10px] font-medium text-text-muted">
        {[row.products?.name, row.addresses?.area].filter(Boolean).join(" · ") || "—"}
      </div>
    </button>
  )
}

/**
 * Top-right status badge — mirrors the design's per-card badge (design lines
 * 991-1005), which isn't just the ticket type: it's whichever signal is most
 * urgent, all derived from real fields (no fabricated numbers):
 *   completed -> checkmark, overdue (sla_due_at passed) -> "Overdue",
 *   due within 2h (same threshold SlaCountdown uses) -> live countdown,
 *   otherwise -> the ticket type pill.
 */
function CardStatusBadge({ row, now, overdue }: { row: TicketListItem; now: number; overdue: boolean }) {
  const { t } = useTranslation()

  if (row.status === "completed") {
    return (
      <span className="flex size-4 shrink-0 items-center justify-center rounded-full bg-[#E7F6ED] text-success">
        <Check className="size-2.5" strokeWidth={3} />
      </span>
    )
  }

  if (overdue) {
    return <span className="shrink-0 rounded-full bg-[#FCEAEA] px-[7px] py-0.5 text-[9px] font-bold text-danger">{t("service.kanban.overdue")}</span>
  }

  if (row.sla_due_at && row.status !== "cancelled") {
    const diffMs = new Date(row.sla_due_at).getTime() - now
    if (diffMs > 0 && diffMs <= 2 * 60 * 60 * 1000) {
      const hours = Math.floor(diffMs / 3_600_000)
      const minutes = Math.floor((diffMs % 3_600_000) / 60_000)
      const label = hours >= 1 ? t("service.kanban.hoursLeft", { count: hours }) : t("service.kanban.minutesLeft", { count: minutes })
      return (
        <span className="inline-flex shrink-0 items-center gap-1 text-[9px] font-bold text-warning">
          <span className="size-1.5 animate-pulse rounded-full bg-warning" />
          {label}
        </span>
      )
    }
  }

  if (!row.type) return null
  return <span className={cn("shrink-0 rounded-full px-[7px] py-0.5 text-[9px] font-bold", TYPE_BADGE_CLASS[row.type])}>{t(`service.type.${row.type}`)}</span>
}
