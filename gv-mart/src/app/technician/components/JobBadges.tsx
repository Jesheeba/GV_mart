import { useTranslation } from "react-i18next"
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

const PRIORITY_CLASS: Record<Enums<"priority_level">, string> = {
  very_urgent: "bg-danger/10 text-danger",
  urgent: "bg-warning/10 text-warning",
  normal: "bg-surface-alt text-text-muted",
}

export function PriorityBadge({ priority }: { priority: Enums<"priority_level"> }) {
  const { t } = useTranslation()
  return (
    <span className={`inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium ${PRIORITY_CLASS[priority]}`}>
      {t(`technician.priority.${priority}`)}
    </span>
  )
}
