import { TriangleAlert } from "lucide-react"
import { Button } from "@/components/ui/button"
import { cn } from "@/lib/utils"

/** Section-level error state — for a query inside a page that has other,
 *  independently-working sections (e.g. the expenses history page's claims
 *  list and km-log list each fail on their own), so one failed section
 *  doesn't need FullPageError's whole-screen takeover. */
export function InlineErrorState({
  message,
  onRetry,
  retryLabel = "Retry",
  className,
}: {
  message: string
  onRetry?: () => void
  retryLabel?: string
  className?: string
}) {
  return (
    <div className={cn("flex flex-col items-start gap-2 rounded-xl border border-danger/30 bg-danger/5 px-3.5 py-2.5", className)}>
      <p className="flex items-start gap-1.5 text-sm text-danger">
        <TriangleAlert className="mt-0.5 size-4 shrink-0" /> {message}
      </p>
      {onRetry ? (
        <Button type="button" variant="outline" size="sm" onClick={onRetry}>
          {retryLabel}
        </Button>
      ) : null}
    </div>
  )
}
