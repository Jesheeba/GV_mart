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
  // The circle+connector row never relies on horizontal scroll — circles are
  // small and fixed-size, connectors flex-shrink freely, so it always fits
  // any viewport width with no risk of overflow. Per-step labels only show
  // at sm: and up (where there's reliably room for 4+ of them beside their
  // circles, the original design); below that, a single caption for just
  // the current step takes their place. Fixes a real mobile bug where the
  // old min-w-max + horizontal-scroll approach got silently clipped by an
  // ancestor Card's overflow-hidden instead of ever actually scrolling.
  return (
    <div className="space-y-2">
      <ol className="flex items-center">
        {steps.map((step, i) => {
          const clickable = !!onStepClick && i <= completedIndex
          return (
            <li key={step.key} className="flex flex-1 items-center last:flex-initial">
              <button
                type="button"
                disabled={!clickable}
                onClick={() => onStepClick?.(i)}
                aria-label={step.label}
                aria-current={i === currentIndex ? "step" : undefined}
                className={cn(
                  "flex min-h-11 min-w-11 items-center justify-center gap-2 rounded-md p-2",
                  clickable ? "cursor-pointer hover:opacity-75" : "cursor-default"
                )}
              >
                <span
                  className={cn(
                    "flex size-7 shrink-0 items-center justify-center rounded-full text-xs font-semibold",
                    i < completedIndex ? "bg-success text-white" : i === currentIndex ? "bg-ink text-white" : "bg-surface-alt text-text-muted"
                  )}
                >
                  {i < completedIndex ? <Check className="size-3.5" /> : i + 1}
                </span>
                <span className={cn("hidden whitespace-nowrap text-sm font-medium sm:inline", i === currentIndex ? "text-text" : "text-text-muted")}>
                  {step.label}
                </span>
              </button>
              {i < steps.length - 1 ? <span className="mx-2 h-px min-w-3 flex-1 bg-border sm:mx-3 sm:min-w-6" /> : null}
            </li>
          )
        })}
      </ol>
      <p className="text-center text-sm font-medium text-text sm:hidden">{steps[currentIndex]?.label}</p>
    </div>
  )
}
