import { useTranslation } from "react-i18next"
import { MessageCircle, UserPlus } from "lucide-react"
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

/** Item 4d (2026-09-16): a lead's owning technician chip, worded to match
 * what owner_id actually means for this lead — "Referred by X" only when
 * source is 'referral' (the technician-referral finder-credit path, see
 * create_sale's referral block); every other source just shows the
 * assigned/finding technician neutrally, since owner_id isn't referral-only
 * (Generate Enquiry field leads set it too). Mirrors CustomerDetailPage's
 * existing referredBy chip so the same fact reads the same way in both
 * places, not styled text in one and a plain table cell in the other. */
export function TechnicianChip({ source, name }: { source: Enums<"lead_source">; name: string | null }) {
  const { t } = useTranslation()
  if (!name) return <span className="text-[13px] font-medium text-text-muted">—</span>
  const label = source === "referral" ? t("leads.chip.referredBy", { name }) : t("leads.chip.technician", { name })
  return (
    <span title={label} className="flex w-fit min-w-0 max-w-full items-center gap-1 rounded-full border border-border bg-surface-alt px-2.5 py-1 text-[11px] font-semibold text-text">
      <UserPlus className="size-3 shrink-0" />
      <span className="truncate">{label}</span>
    </span>
  )
}
