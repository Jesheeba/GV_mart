import { Check } from "lucide-react"
import { cn } from "@/lib/utils"

export type StepperStep = { key: string; label: string }

export function Stepper({
  steps,
  currentIndex,
  maxCompletedIndex,
  onStepClick,
}: {
  steps: StepperStep[]
  currentIndex: number
  /**
   * Highest step index the wizard has ever reached. Optional — defaults to
   * `currentIndex` so callers that don't track it separately (i.e. every
   * wizard that only ever has one `step` variable) keep their exact previous
   * behavior. Wizards that let the user navigate backward while keeping
   * later steps' data intact should track this in its own only-grows state
   * variable and pass it through, so a step's checkmark doesn't disappear
   * just because `currentIndex` moved behind it.
   */
  maxCompletedIndex?: number
  /**
   * Optional — when provided, already-completed steps (and the current one)
   * become clickable to jump back. Steps ahead of the current one stay
   * non-interactive since their data hasn't been reached/validated yet.
   * Omit to keep the stepper purely a progress indicator (previous behavior).
   */
  onStepClick?: (index: number) => void
}) {
  const completedIndex = maxCompletedIndex ?? currentIndex
  return (
    <div className="-mx-1 overflow-x-auto px-1">
      <ol className="flex min-w-max items-center">
        {steps.map((step, i) => {
          const clickable = !!onStepClick && i <= completedIndex
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
                    i < completedIndex ? "bg-success text-white" : i === currentIndex ? "bg-ink text-white" : "bg-surface-alt text-text-muted"
                  )}
                >
                  {i < completedIndex ? <Check className="size-3.5" /> : i + 1}
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
