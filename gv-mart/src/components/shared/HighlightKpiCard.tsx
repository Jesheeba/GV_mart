import type { ReactNode } from "react"
import { cn } from "@/lib/utils"
import { Skeleton } from "@/components/ui/skeleton"

/**
 * The single filled-coral "highlight" KPI card per section (e.g. Total
 * Revenue on ADM-01, technician's today's earnings on TECH-10).
 * Reference: design system §2.5 / §2.7.
 */
export function HighlightKpiCard({
  label,
  value,
  caption,
  icon,
  loading = false,
  className,
}: {
  label: string
  value: ReactNode
  caption?: string
  icon?: ReactNode
  loading?: boolean
  className?: string
}) {
  if (loading) {
    return (
      <div
        className={cn(
          "rounded-card bg-accent/40 p-5",
          className
        )}
      >
        <Skeleton className="h-4 w-28 bg-white/30" />
        <Skeleton className="mt-4 h-9 w-32 bg-white/30" />
        <Skeleton className="mt-3 h-4 w-20 bg-white/30" />
      </div>
    )
  }

  return (
    <div
      className={cn(
        "flex flex-col gap-3 rounded-card bg-gradient-to-br from-accent to-[#FF7A45] p-5 text-white",
        className
      )}
    >
      <div className="flex items-start justify-between">
        <span className="text-sm font-medium text-white/85">{label}</span>
        {icon ? (
          <span className="flex size-8 items-center justify-center rounded-full bg-white/15">
            {icon}
          </span>
        ) : null}
      </div>
      <div className="text-3xl font-bold tabular-nums">{value}</div>
      {caption ? <span className="text-xs text-white/80">{caption}</span> : null}
    </div>
  )
}
