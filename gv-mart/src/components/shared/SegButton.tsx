import type { ReactNode } from "react"
import { cn } from "@/lib/utils"

/** Pill segmented-control button — wrap a group of these in a
 * `flex gap-[3px] rounded-full border border-border bg-surface-alt p-1` container.
 * Extracted from the identical markup AmcWarrantyListPage.tsx and PnlReportTab.tsx
 * each had inline, now the shared building block for any Month/Year/Custom-style
 * mode switch (see PeriodFilter.tsx). */
export function SegButton({
  active,
  onClick,
  children,
  className,
}: {
  active: boolean
  onClick: () => void
  children: ReactNode
  className?: string
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={active}
      className={cn(
        "rounded-full px-4 py-[7px] text-xs font-semibold transition-colors",
        active ? "bg-ink text-white" : "text-text-muted",
        className
      )}
    >
      {children}
    </button>
  )
}
