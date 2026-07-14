import type { ReactNode } from "react"
import { useTranslation } from "react-i18next"
import { Inbox, TriangleAlert } from "lucide-react"
import { cn } from "@/lib/utils"
import { Button } from "@/components/ui/button"
import { Skeleton } from "@/components/ui/skeleton"
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"

export type DataTableColumn<T> = {
  key: string
  header: ReactNode
  render: (row: T) => ReactNode
  className?: string
}

/**
 * Base data-table shell shared by every admin list (customers, tickets,
 * invoices, leads, inventory…). Handles the four states every list needs
 * (build-spec §8 "no static UI"): active, loading, empty, error.
 * Sort/filter/pagination land per-module in Phase 3+.
 */
export function DataTable<T>({
  columns,
  rows,
  rowKey,
  onRowClick,
  loading = false,
  error = null,
  onRetry,
  emptyMessage = "No records yet",
  skeletonRowCount = 5,
  className,
}: {
  columns: DataTableColumn<T>[]
  rows: T[]
  rowKey: (row: T) => string | number
  onRowClick?: (row: T) => void
  loading?: boolean
  error?: string | null
  onRetry?: () => void
  emptyMessage?: string
  skeletonRowCount?: number
  className?: string
}) {
  const { t } = useTranslation()
  return (
    <div className={cn("overflow-hidden rounded-subcard border border-border", className)}>
      <Table>
        <TableHeader className="bg-surface-alt">
          <TableRow className="hover:bg-transparent">
            {columns.map((col) => (
              <TableHead key={col.key} className={cn("text-text-muted", col.className)}>
                {col.header}
              </TableHead>
            ))}
          </TableRow>
        </TableHeader>
        <TableBody>
          {error ? (
            <TableRow className="hover:bg-transparent">
              <TableCell colSpan={columns.length} className="py-12 text-center">
                <div className="flex flex-col items-center gap-3">
                  <TriangleAlert className="size-6 text-danger" />
                  <p className="text-sm text-text-muted">{error}</p>
                  {onRetry ? (
                    <Button variant="outline" size="sm" onClick={onRetry}>
                      {t("common.retry")}
                    </Button>
                  ) : null}
                </div>
              </TableCell>
            </TableRow>
          ) : loading ? (
            Array.from({ length: skeletonRowCount }).map((_, i) => (
              <TableRow key={i} className="hover:bg-transparent">
                {columns.map((col) => (
                  <TableCell key={col.key}>
                    <Skeleton className="h-4 w-full max-w-40" />
                  </TableCell>
                ))}
              </TableRow>
            ))
          ) : rows.length === 0 ? (
            <TableRow className="hover:bg-transparent">
              <TableCell colSpan={columns.length} className="py-12 text-center">
                <div className="flex flex-col items-center gap-2">
                  <Inbox className="size-6 text-text-muted" />
                  <p className="text-sm text-text-muted">{emptyMessage}</p>
                </div>
              </TableCell>
            </TableRow>
          ) : (
            rows.map((row) => (
              <TableRow
                key={rowKey(row)}
                onClick={onRowClick ? () => onRowClick(row) : undefined}
                className={onRowClick ? "cursor-pointer" : undefined}
              >
                {columns.map((col) => (
                  <TableCell key={col.key} className={col.className}>
                    {col.render(row)}
                  </TableCell>
                ))}
              </TableRow>
            ))
          )}
        </TableBody>
      </Table>
    </div>
  )
}
