import { Loader2, TriangleAlert } from "lucide-react"
import { Button } from "@/components/ui/button"
import { cn } from "@/lib/utils"

export function FullPageLoader({ label, className }: { label?: string; className?: string }) {
  return (
    <div className={cn("flex min-h-screen flex-col items-center justify-center gap-3 bg-bg", className)}>
      <Loader2 className="size-6 animate-spin text-accent" />
      {label ? <p className="text-sm text-text-muted">{label}</p> : null}
    </div>
  )
}

export function FullPageError({
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
    <div className={cn("flex min-h-screen flex-col items-center justify-center gap-3 bg-bg px-6 text-center", className)}>
      <TriangleAlert className="size-6 text-danger" />
      <p className="max-w-xs text-sm text-text-muted">{message}</p>
      {onRetry ? (
        <Button variant="outline" size="sm" onClick={onRetry}>
          {retryLabel}
        </Button>
      ) : null}
    </div>
  )
}
