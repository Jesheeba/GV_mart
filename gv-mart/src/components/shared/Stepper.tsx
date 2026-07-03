import { Check } from "lucide-react"
import { cn } from "@/lib/utils"

export type StepperStep = { key: string; label: string }

export function Stepper({ steps, currentIndex }: { steps: StepperStep[]; currentIndex: number }) {
  return (
    <ol className="flex items-center">
      {steps.map((step, i) => (
        <li key={step.key} className="flex flex-1 items-center last:flex-initial">
          <div className="flex items-center gap-2">
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
          </div>
          {i < steps.length - 1 ? <span className="mx-3 h-px flex-1 bg-border" /> : null}
        </li>
      ))}
    </ol>
  )
}
