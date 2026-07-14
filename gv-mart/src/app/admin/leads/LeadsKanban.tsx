import { useTranslation } from "react-i18next"
import { TriangleAlert } from "lucide-react"
import { Card } from "@/components/ui/card"
import { Skeleton } from "@/components/ui/skeleton"
import { Button } from "@/components/ui/button"
import type { LeadListItem } from "@/services/automation"

const COLUMNS = ["new", "contacted", "quoted", "won", "lost"] as const

/** Click-to-advance board (no drag-and-drop primitive in this codebase —
 * same simplification TicketsKanban.tsx uses for ticket status). */
export function LeadsKanban({
  rows,
  loading,
  error,
  onRetry,
  onCardClick,
}: {
  rows: LeadListItem[]
  loading: boolean
  error: string | null
  onRetry: () => void
  onCardClick: (row: LeadListItem) => void
}) {
  const { t } = useTranslation()

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
    <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-5">
      {COLUMNS.map((col) => {
        const colRows = rows.filter((r) => r.status === col)
        return (
          <div key={col} className="space-y-2">
            <div className="flex items-center justify-between px-1">
              <h3 className="text-sm font-semibold text-text">{t(`leads.status.${col}`)}</h3>
              <span className="text-xs text-text-muted">{loading ? "…" : colRows.length}</span>
            </div>
            <div className="space-y-2">
              {loading ? (
                Array.from({ length: 2 }).map((_, i) => <Skeleton key={i} className="h-20 w-full rounded-subcard" />)
              ) : colRows.length === 0 ? (
                <Card size="sm" className="items-center py-6 text-center text-xs text-text-muted px-4">
                  {t("leads.kanban.empty")}
                </Card>
              ) : (
                colRows.map((r) => (
                  <button key={r.id} type="button" onClick={() => onCardClick(r)} className="block w-full text-left">
                    <Card size="sm" className="gap-1.5 hover:border-accent/50 px-4">
                      <div className="text-sm font-medium text-text">{r.customers?.name ?? r.name}</div>
                      <div className="text-xs text-text-muted">{r.mobile ?? r.customers?.mobile ?? "—"}</div>
                      <div className="flex flex-wrap items-center gap-1.5 text-xs text-text-muted">
                        <span className="rounded-full bg-surface-alt px-2 py-0.5">{t(`leads.source.${r.source}`)}</span>
                        {r.enquiry_type ? <span className="rounded-full bg-surface-alt px-2 py-0.5">{t(`leads.enquiryType.${r.enquiry_type}`)}</span> : null}
                      </div>
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
