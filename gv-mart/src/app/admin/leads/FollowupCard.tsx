import { useTranslation } from "react-i18next"
import { Link } from "react-router-dom"
import { CalendarClock, ClipboardCheck, MessageCircle, Phone } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { StatusDot } from "@/components/shared/StatusDot"
import { useLeadSourceOptions } from "@/hooks/useLeadSources"
import { FollowupChip, PostponeBadge, StuckBadge } from "./FollowupBadges"
import { rememberCall } from "@/lib/call-return"
import { telHref } from "@/lib/lead-followups"
import { toWhatsappLink } from "@/lib/whatsapp-link"
import { cn } from "@/lib/utils"
import type { FollowupListItem } from "@/services/leadFollowups"

/** One row of the My Day list: who, what they want, what happened last, when it is due, and one-tap Call / WhatsApp / Log outcome. */
export function FollowupCard({
  item,
  onLogOutcome,
  onReschedule,
}: {
  item: FollowupListItem
  onLogOutcome: (item: FollowupListItem) => void
  onReschedule: (item: FollowupListItem) => void
}) {
  const { t, i18n } = useTranslation()
  const { label: sourceLabel } = useLeadSourceOptions()
  const lang = i18n.language
  const outcomeLabel = lang.startsWith("ta") && item.last_outcome_label_ta ? item.last_outcome_label_ta : item.last_outcome_label_en
  const call = { id: item.lead_id, name: item.lead_name, mobile: item.mobile, status: item.lead_status }

  return (
    <Card size="sm" className={cn("gap-2.5 px-4", item.bucket === "overdue" && "border-danger/40")} data-testid="followup-card">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div className="min-w-0 space-y-0.5">
          <Link to={`/admin/leads/${item.lead_id}`} className="block truncate text-sm font-semibold text-text hover:underline">
            {item.lead_name}
          </Link>
          <p className="text-xs text-text-muted">{item.mobile ?? "—"}</p>
        </div>
        <div className="flex flex-wrap items-center justify-end gap-1.5">
          <FollowupChip dueAt={item.due_at} />
          <PostponeBadge count={item.postpone_count} />
          {item.is_stuck ? <StuckBadge /> : null}
        </div>
      </div>

      <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-text-muted">
        <StatusDot tone={item.lead_status === "new" ? "info" : "warning"} label={t(`leads.status.${item.lead_status}`)} className="[&>span:last-child]:text-xs" />
        {item.kind ? <span>{t(`leads.kind.${item.kind}`)}</span> : null}
        {item.product_name ? <span className="font-medium text-text">{item.product_name}</span> : null}
        <span>{sourceLabel(item.source)}</span>
        <span className="inline-flex items-center gap-1">
          <CalendarClock className="size-3" />
          {t(`leads.followup.type.${item.followup_type}`)}
          {item.followup_note ? ` · ${item.followup_note}` : ""}
        </span>
      </div>

      {outcomeLabel ? (
        <p className="rounded-lg bg-surface-alt px-2.5 py-1.5 text-xs">
          <span className="font-semibold text-text">{outcomeLabel}</span>
          {item.last_outcome_note ? <span className="text-text-muted"> — {item.last_outcome_note}</span> : null}
        </p>
      ) : null}

      <div className="flex flex-wrap gap-1.5">
        {item.mobile ? (
          <>
            <a
              href={telHref(item.mobile)}
              onClick={() => rememberCall(call)}
              className="inline-flex h-8 items-center gap-1 rounded-full bg-ink px-4 text-[0.8rem] font-medium text-white hover:bg-ink/85"
            >
              <Phone className="size-3.5" />
              {t("leads.followup.call")}
            </a>
            <a
              href={toWhatsappLink(item.mobile, "")}
              target="_blank"
              rel="noreferrer"
              className="inline-flex h-8 items-center gap-1 rounded-full border border-border px-4 text-[0.8rem] font-medium text-text hover:bg-surface-alt"
            >
              <MessageCircle className="size-3.5" />
              {t("leads.followup.whatsapp")}
            </a>
          </>
        ) : null}
        <Button size="sm" variant="accent" onClick={() => onLogOutcome(item)}>
          <ClipboardCheck className="size-3.5" />
          {t("leads.followup.logOutcome")}
        </Button>
        <Button size="sm" variant="ghost" onClick={() => onReschedule(item)}>
          {t("leads.followup.reschedule")}
        </Button>
      </div>
    </Card>
  )
}
