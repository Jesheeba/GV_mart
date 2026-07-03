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
  icon,
  delta,
  loading = false,
  className,
}: {
  label: string
  value: ReactNode
  icon?: ReactNode
  delta?: KpiDelta
  loading?: boolean
  className?: string
}) {
  if (loading) {
    return (
      <Card className={cn("gap-3", className)}>
        <div className="flex items-start justify-between px-1">
          <Skeleton className="h-4 w-24" />
          <Skeleton className="size-8 rounded-full" />
        </div>
        <Skeleton className="mx-1 h-9 w-28" />
        <Skeleton className="mx-1 h-4 w-20" />
      </Card>
    )
  }

  const isUp = (delta?.value ?? 0) >= 0

  return (
    <Card className={cn("gap-3", className)}>
      <div className="flex items-start justify-between px-1">
        <span className="text-sm font-medium text-text-muted">{label}</span>
        {icon ? (
          <span className="flex size-8 items-center justify-center rounded-full bg-surface-alt text-text">
            {icon}
          </span>
        ) : null}
      </div>
      <div className="px-1 text-3xl font-bold tabular-nums text-text">{value}</div>
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
