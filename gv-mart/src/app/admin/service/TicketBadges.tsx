import { useTranslation } from "react-i18next"
import { MessageCircle } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { cn } from "@/lib/utils"
import type { PriorityLevel, TicketType } from "@/services/service"
import type { Enums } from "@/types/database"

/**
 * Ticket-type colors, matched to the design source (design-template-decoded.html
 * lines 979, 991-1006): AMC = info blue, Warranty = a dedicated green
 * (distinct from the --success token, kept as a literal to stay pixel-faithful),
 * Paid = ink. "Installation" has no example in the design mock data, so it's
 * assigned --accent to stay visually distinct from the other three — an
 * assumption, not a value copied from the source.
 */
export const TYPE_BADGE_CLASS: Record<TicketType, string> = {
  paid: "text-ink bg-[#F0EBE3]",
  warranty: "text-[#16855B] bg-[#E2F3EA]",
  amc: "text-info bg-info/10",
  installation: "text-accent bg-accent/10",
}

/** Only WhatsApp gets its own visual treatment (green, matching this
 * app's existing WhatsApp-brand accents elsewhere e.g. CustomerDetailPage's
 * WhatsApp button) — the other four channels are functionally equivalent
 * "not WhatsApp" origins and share a neutral badge, per the plan's "source
 * badge where channel is already read" ask (that read specifically wants
 * WhatsApp-origin tickets to stand out, not a five-way color system). */
export function ChannelBadge({ channel }: { channel: Enums<"ticket_channel"> }) {
  const { t } = useTranslation()
  if (channel === "whatsapp") {
    return (
      <Badge variant="outline" className="border-transparent bg-success/15 font-bold text-success">
        <MessageCircle className="size-3" />
        {t("service.channel.whatsapp")}
      </Badge>
    )
  }
  return (
    <Badge variant="outline" className="border-transparent bg-surface-alt font-medium text-text-muted">
      {t(`service.channel.${channel}`)}
    </Badge>
  )
}

export function TicketTypeBadge({ type }: { type: TicketType | null }) {
  const { t } = useTranslation()
  if (!type) return <span className="text-text-muted">—</span>
  return (
    <Badge variant="outline" className={cn("border-transparent font-bold", TYPE_BADGE_CLASS[type])}>
      {t(`service.type.${type}`)}
    </Badge>
  )
}

/** Priority colors, matched 1:1 to the design's High/Med/Low text colors (danger/warning/success). */
export const PRIORITY_COLOR_CLASS: Record<PriorityLevel, string> = {
  very_urgent: "text-danger",
  urgent: "text-warning",
  normal: "text-success",
}

const PRIORITY_BG_CLASS: Record<PriorityLevel, string> = {
  very_urgent: "bg-danger/10",
  urgent: "bg-warning/10",
  normal: "bg-success/10",
}

export function PriorityBadge({ priority }: { priority: PriorityLevel }) {
  const { t } = useTranslation()
  return (
    <Badge variant="outline" className={cn("border-transparent font-bold", PRIORITY_COLOR_CLASS[priority], PRIORITY_BG_CLASS[priority])}>
      {t(`service.priority.${priority}`)}
    </Badge>
  )
}

/**
 * Plain colored text (no pill) — the design's table "Prio" column renders
 * priority as bold colored text with no background (design-template-decoded.html
 * line 980), unlike the badge pill used elsewhere. Uses the abbreviated
 * High/Med/Low labels the design shows to fit the narrow column.
 */
export function PriorityText({ priority }: { priority: PriorityLevel }) {
  const { t } = useTranslation()
  return <span className={cn("text-xs font-bold", PRIORITY_COLOR_CLASS[priority])}>{t(`service.priority.short.${priority}`)}</span>
}
