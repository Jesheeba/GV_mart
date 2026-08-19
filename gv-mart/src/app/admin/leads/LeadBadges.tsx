import { useTranslation } from "react-i18next"
import { MessageCircle } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import type { Enums } from "@/types/database"

/** Same treatment as service/TicketBadges.tsx's ChannelBadge — only
 * WhatsApp gets its own visual accent, the other sources share a neutral
 * badge, since the ask is specifically to make WhatsApp-origin leads
 * stand out where source is already read (LeadsPage's table), not a
 * six-way color system for every lead_source value. */
export function SourceBadge({ source }: { source: Enums<"lead_source"> }) {
  const { t } = useTranslation()
  if (source === "whatsapp") {
    return (
      <Badge variant="outline" className="border-transparent bg-success/15 font-bold text-success">
        <MessageCircle className="size-3" />
        {t("leads.source.whatsapp")}
      </Badge>
    )
  }
  return <span className="text-[13px] font-medium text-text">{t(`leads.source.${source}`)}</span>
}
