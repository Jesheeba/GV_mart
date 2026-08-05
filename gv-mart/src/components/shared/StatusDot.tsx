import { cn } from "@/lib/utils"

export type StatusTone = "success" | "warning" | "danger" | "info" | "neutral"

export const DOT_TONE_CLASS: Record<StatusTone, string> = {
  success: "bg-success",
  warning: "bg-warning",
  danger: "bg-danger",
  info: "bg-info",
  neutral: "bg-text-muted",
}

/**
 * Small colored dot + label — the Finexy status pattern used in every table
 * (completed/paid/on-time/in-stock = success, pending/in-progress = warning,
 * late/overdue/out-of-stock = danger, AMC/warranty = info).
 */
export function StatusDot({
  tone,
  label,
  className,
}: {
  tone: StatusTone
  label: string
  className?: string
}) {
  return (
    <span className={cn("inline-flex items-center gap-1.5", className)}>
      <span className={cn("size-1.5 shrink-0 rounded-full", DOT_TONE_CLASS[tone])} aria-hidden="true" />
      <span className="text-sm text-text">{label}</span>
    </span>
  )
}
