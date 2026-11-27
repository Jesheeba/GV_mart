import type { ReactNode } from "react"
import { TrendingDown, TrendingUp } from "lucide-react"
import { cn } from "@/lib/utils"
import { Card } from "@/components/ui/card"
import { Skeleton } from "@/components/ui/skeleton"

type KpiDelta = {
  /** Signed percentage, e.g. 12.4 or -3.1 */
  value: number
  /** Trailing caption, defaults to "this month" */
  label?: string
}

export function KpiCard({
  label,
  value,
  subValue,
  icon,
  corner,
  compact = false,
  delta,
  loading = false,
  className,
}: {
  label: string
  value: ReactNode
  /** Secondary line under the main value — e.g. "Collected ₹X" next to an
   *  invoiced main figure (money-flow-audit item 1). */
  subValue?: ReactNode
  icon?: ReactNode
  /** Small pill in the top-right corner instead of an icon, e.g. a "% of total". */
  corner?: ReactNode
  /** Smaller card: tighter padding and a smaller value. */
  compact?: boolean
  delta?: KpiDelta
  loading?: boolean
  className?: string
}) {
  if (loading) {
    return (
      <Card size={compact ? "sm" : "default"} className={cn(compact ? "gap-1.5" : "gap-3", className)}>
        <div className="flex items-start justify-between px-1">
          <Skeleton className="h-4 w-24" />
          {compact ? null : <Skeleton className="size-8 rounded-full" />}
        </div>
        <Skeleton className={cn("mx-1 w-28", compact ? "h-7" : "h-9")} />
        {compact ? null : <Skeleton className="mx-1 h-4 w-20" />}
      </Card>
    )
  }

  const isUp = (delta?.value ?? 0) >= 0

  return (
    <Card size={compact ? "sm" : "default"} className={cn(compact ? "gap-1.5" : "gap-3", className)}>
      <div className="flex items-start justify-between gap-2 px-1">
        <span className={cn("font-medium text-text-muted", compact ? "text-xs" : "text-sm")}>{label}</span>
        {corner ? (
          <span className="shrink-0 rounded-full bg-surface-alt px-2 py-0.5 text-xs font-semibold tabular-nums text-text">{corner}</span>
        ) : icon ? (
          <span className="flex size-8 items-center justify-center rounded-full bg-surface-alt text-text">
            {icon}
          </span>
        ) : null}
      </div>
      <div className={cn("px-1 font-bold tabular-nums text-text", compact ? "text-2xl" : "text-3xl")}>{value}</div>
      {subValue ? <div className="px-1 text-xs font-semibold text-text-muted">{subValue}</div> : null}
      {delta ? (
        <div className="flex items-center gap-1.5 px-1 text-xs">
          <span
            className={cn(
              "inline-flex items-center gap-0.5 rounded-full px-1.5 py-0.5 font-semibold",
              isUp ? "bg-success/10 text-success" : "bg-danger/10 text-danger"
            )}
          >
            {isUp ? <TrendingUp className="size-3" /> : <TrendingDown className="size-3" />}
            {Math.abs(delta.value)}%
          </span>
          <span className="text-text-muted">{delta.label ?? "this month"}</span>
        </div>
      ) : null}
    </Card>
  )
}
