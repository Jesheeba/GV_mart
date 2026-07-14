import { Check } from "lucide-react"
import { cn } from "@/lib/utils"

export type StepperStep = { key: string; label: string }

export function Stepper({
  steps,
  currentIndex,
  onStepClick,
}: {
  steps: StepperStep[]
  currentIndex: number
  /**
   * Optional — when provided, already-completed steps (and the current one)
   * become clickable to jump back. Steps ahead of the current one stay
   * non-interactive since their data hasn't been reached/validated yet.
   * Omit to keep the stepper purely a progress indicator (previous behavior).
   */
  onStepClick?: (index: number) => void
}) {
  return (
    <div className="-mx-1 overflow-x-auto px-1">
      <ol className="flex min-w-max items-center">
        {steps.map((step, i) => {
          const clickable = !!onStepClick && i <= currentIndex
          return (
            <li key={step.key} className="flex flex-1 items-center last:flex-initial">
              <button
                type="button"
                disabled={!clickable}
                onClick={() => onStepClick?.(i)}
                className={cn("flex items-center gap-2 rounded-md", clickable ? "cursor-pointer hover:opacity-75" : "cursor-default")}
              >
                <span
                  className={cn(
                    "flex size-7 shrink-0 items-center justify-center rounded-full text-xs font-semibold",
                    i < currentIndex ? "bg-success text-white" : i === currentIndex ? "bg-ink text-white" : "bg-surface-alt text-text-muted"
                  )}
                >
                  {i < currentIndex ? <Check className="size-3.5" /> : i + 1}
                </span>
                <span className={cn("whitespace-nowrap text-sm font-medium", i === currentIndex ? "text-text" : "text-text-muted")}>
                  {step.label}
                </span>
              </button>
              {i < steps.length - 1 ? <span className="mx-3 h-px min-w-6 flex-1 bg-border" /> : null}
            </li>
          )
        })}
      </ol>
    </div>
  )
}
