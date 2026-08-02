import { useTranslation } from "react-i18next"
import { TriangleAlert } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import type { Enums } from "@/types/database"

const TYPE_VARIANT: Record<Enums<"ticket_type">, "default" | "secondary" | "outline"> = {
  paid: "default",
  warranty: "secondary",
  amc: "outline",
  installation: "default",
}

export function JobTypeBadge({ type }: { type: Enums<"ticket_type"> | null }) {
  const { t } = useTranslation()
  if (!type) return null
  return <Badge variant={TYPE_VARIANT[type]}>{t(`technician.jobType.${type}`)}</Badge>
}

const PRIORITY_VARIANT: Record<Enums<"priority_level">, "danger" | "warning" | "secondary"> = {
  very_urgent: "danger",
  urgent: "warning",
  normal: "secondary",
}

export function PriorityBadge({ priority }: { priority: Enums<"priority_level"> }) {
  const { t } = useTranslation()
  return <Badge variant={PRIORITY_VARIANT[priority]}>{t(`technician.priority.${priority}`)}</Badge>
}

/**
 * Bug 2/3 + UI Suggestion 1/2 — flags a job whose SLA deadline has passed
 * (see `isOverdueJob` in services/technician.ts, ported from the admin
 * side's isOverdueRow). Styled like PriorityBadge's very_urgent tone
 * (bg-danger/10 / text-danger) plus a warning-triangle glyph so it reads
 * distinctly from the priority pill it sits next to.
 */
export function OverdueBadge() {
  const { t } = useTranslation()
  return (
    <Badge variant="danger">
      <TriangleAlert className="size-3" />
      {t("technician.home.counts.overdue")}
    </Badge>
  )
}

/** Build Order A4: a visit still open past its ticket's estimated_duration_minutes.
 *  Same danger-token language as PRIORITY_CLASS.very_urgent above, so "this job
 *  needs attention" reads consistently across badges rather than inventing a new color. */
export function OverrunBadge({ overrunByMinutes }: { overrunByMinutes: number }) {
  const { t } = useTranslation()
  return (
    <Badge variant="danger">
      {t("technician.jobDetail.overrunBadge", { count: Math.round(overrunByMinutes) })}
    </Badge>
  )
}
