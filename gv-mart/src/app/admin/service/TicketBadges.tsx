import { useTranslation } from "react-i18next"
import { Badge } from "@/components/ui/badge"
import { cn } from "@/lib/utils"
import type { PriorityLevel, TicketType } from "@/services/service"

const TYPE_CLASS: Record<TicketType, string> = {
  paid: "bg-ink/10 text-ink",
  warranty: "bg-info/10 text-info",
  amc: "bg-accent/10 text-accent",
  installation: "bg-success/10 text-success",
}

export function TicketTypeBadge({ type }: { type: TicketType | null }) {
  const { t } = useTranslation()
  if (!type) return <span className="text-text-muted">—</span>
  return <Badge variant="outline" className={cn("border-transparent", TYPE_CLASS[type])}>{t(`service.type.${type}`)}</Badge>
}

const PRIORITY_CLASS: Record<PriorityLevel, string> = {
  very_urgent: "bg-danger/10 text-danger",
  urgent: "bg-warning/10 text-warning",
  normal: "bg-surface-alt text-text-muted",
}

export function PriorityBadge({ priority }: { priority: PriorityLevel }) {
  const { t } = useTranslation()
  return <Badge variant="outline" className={cn("border-transparent", PRIORITY_CLASS[priority])}>{t(`service.priority.${priority}`)}</Badge>
}
