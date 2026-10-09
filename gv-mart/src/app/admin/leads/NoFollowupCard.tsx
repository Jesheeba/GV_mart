import { useTranslation } from "react-i18next"
import { Link } from "react-router-dom"
import { CalendarPlus, MessageCircle, Phone, UserRound } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { StatusDot } from "@/components/shared/StatusDot"
import { useLeadSourceOptions } from "@/hooks/useLeadSources"
import { useLeadKindOptions } from "@/hooks/useLeadLists"
import { PostponeBadge } from "./FollowupBadges"
import { rememberCall } from "@/lib/call-return"
import { telHref } from "@/lib/lead-followups"
import { toWhatsappLink } from "@/lib/whatsapp-link"
import type { LeadWithoutFollowup } from "@/services/leadFollowups"

/** Whole days since the lead was created (0 = today); never negative. */
function ageDays(createdAt: string, now: number = Date.now()): number {
  return Math.max(0, Math.floor((now - new Date(createdAt).getTime()) / 86_400_000))
}

/** One open lead that nobody has scheduled: who, what they want, how long it has waited, and one-tap Call / WhatsApp / Set follow-up. */
export function NoFollowupCard({
  item,
  onSetFollowup,
  onAssign,
  selectable,
  selected,
  onToggle,
}: {
  item: LeadWithoutFollowup
  /** Set only when the signed-in person may schedule this lead (see canScheduleLead). */
  onSetFollowup?: (item: LeadWithoutFollowup) => void
  /** Set only when the signed-in person may assign this lead (see assignActionFor). */
  onAssign?: (item: LeadWithoutFollowup) => void
  selectable?: boolean
  selected?: boolean
  onToggle?: (item: LeadWithoutFollowup) => void
}) {
  const { t, i18n } = useTranslation()
  const { label: sourceLabel } = useLeadSourceOptions()
  const { label: kindLabel } = useLeadKindOptions()
  const lang = i18n.language
  const outcomeLabel = lang.startsWith("ta") && item.last_outcome_label_ta ? item.last_outcome_label_ta : item.last_outcome_label_en
  const call = { id: item.lead_id, name: item.lead_name, mobile: item.mobile, status: item.lead_status }
  const days = ageDays(item.created_at)

  return (
    <Card size="sm" className="gap-2.5 px-4" data-testid="no-followup-card">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div className="flex min-w-0 items-start gap-2">
          {selectable ? (
            <input
              type="checkbox"
              checked={!!selected}
              onChange={() => onToggle?.(item)}
              aria-label={item.lead_name}
              className="mt-1 size-4 shrink-0 accent-accent"
            />
          ) : null}
          <div className="min-w-0 space-y-0.5">
            <Link to={`/admin/leads/${item.lead_id}`} className="block truncate text-sm font-semibold text-text hover:underline">
              {item.lead_name}
            </Link>
            <p className="text-xs text-text-muted">{item.mobile ?? "—"}</p>
          </div>
        </div>
        <div className="flex flex-wrap items-center justify-end gap-1.5">
          <span className="rounded-full border border-border bg-surface-alt px-2.5 py-0.5 text-[11px] font-semibold text-text-muted" data-testid="waiting-chip">
            {days === 0 ? t("leads.noFollowup.today") : t("leads.noFollowup.waiting", { count: days })}
          </span>
          <PostponeBadge count={item.postpone_count} />
        </div>
      </div>

      <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-text-muted">
        <StatusDot tone={item.lead_status === "new" ? "info" : "warning"} label={t(`leads.status.${item.lead_status}`)} className="[&>span:last-child]:text-xs" />
        {item.kind ? <span>{kindLabel(item.kind)}</span> : null}
        {item.product_name ? <span className="font-medium text-text">{item.product_name}</span> : null}
        <span>{sourceLabel(item.source)}</span>
        <span className="inline-flex items-center gap-1" data-testid="assignee-chip">
          <UserRound className="size-3" />
          {item.assignee_name ?? t("leads.assign.unassigned")}
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
        {onSetFollowup ? (
          <Button size="sm" variant="accent" onClick={() => onSetFollowup(item)} data-testid="card-set-followup">
            <CalendarPlus className="size-3.5" />
            {t("leads.followup.setButton")}
          </Button>
        ) : null}
        {onAssign ? (
          <Button size="sm" variant="ghost" onClick={() => onAssign(item)}>
            {t(item.assignee_id ? "leads.assign.reassign" : "leads.assign.assign")}
          </Button>
        ) : null}
      </div>
    </Card>
  )
}
