import { useTranslation } from "react-i18next"
import { Link } from "react-router-dom"
import { CalendarClock, ClipboardCheck, MessageCircle, Phone, UserRound, Wrench } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { FollowupChip } from "./FollowupBadges"
import { telHref } from "@/lib/lead-followups"
import { toWhatsappLink } from "@/lib/whatsapp-link"
import { cn } from "@/lib/utils"
import type { PostServiceFollowupItem } from "@/services/postServiceFollowups"

/**
 * One post-service call in Daily Follow Up: who to call, which job it was, how many tries so far, and one-tap
 * Call / WhatsApp / Log call. Sibling of FollowupCard (which is lead-centric); no lead actions apply here.
 */
export function PostServiceCard({ item, onLogCall }: { item: PostServiceFollowupItem; onLogCall: (item: PostServiceFollowupItem) => void }) {
  const { t, i18n } = useTranslation()
  const lang = i18n.language
  const lastLabel = lang.startsWith("ta") && item.last_outcome_label_ta ? item.last_outcome_label_ta : item.last_outcome_label_en

  return (
    <Card size="sm" className={cn("gap-2.5 px-4", item.bucket === "overdue" && "border-danger/40")} data-testid="post-service-card">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div className="min-w-0 space-y-0.5">
          <Link to={`/admin/customers/${item.customer_id}`} className="block truncate text-sm font-semibold text-text hover:underline">
            {item.customer_name}
          </Link>
          <p className="text-xs text-text-muted">{item.mobile ?? "—"}</p>
        </div>
        <div className="flex flex-wrap items-center justify-end gap-1.5">
          <FollowupChip dueAt={item.due_at} />
        </div>
      </div>

      <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-text-muted">
        <span className="inline-flex items-center gap-1 rounded-full bg-info/10 px-2 py-0.5 font-semibold text-info">
          <Wrench className="size-3" />
          {t("leads.postService.badge")}
        </span>
        <Link to={`/admin/service/${item.ticket_id}`} className="font-medium text-text hover:underline">
          {item.complaint ?? t("leads.postService.ticket")}
        </Link>
        {item.ticket_type ? <span>{t(`service.type.${item.ticket_type}`)}</span> : null}
        {item.product_name ? <span className="font-medium text-text">{item.product_name}</span> : null}
        <span className="inline-flex items-center gap-1" data-testid="assignee-chip">
          <UserRound className="size-3" />
          {item.assignee_name ?? t("leads.assign.unassigned")}
        </span>
        <span className="inline-flex items-center gap-1">
          <CalendarClock className="size-3" />
          {item.attempts > 0 ? t("leads.postService.attempts", { count: item.attempts }) : t("leads.postService.firstCall")}
        </span>
      </div>

      {lastLabel ? (
        <p className="rounded-lg bg-surface-alt px-2.5 py-1.5 text-xs">
          <span className="font-semibold text-text">{lastLabel}</span>
          {item.last_outcome_note ? <span className="text-text-muted"> — {item.last_outcome_note}</span> : null}
        </p>
      ) : null}

      <div className="flex flex-wrap gap-1.5">
        {item.mobile ? (
          <>
            <a href={telHref(item.mobile)} className="inline-flex h-8 items-center gap-1 rounded-full bg-ink px-4 text-[0.8rem] font-medium text-white hover:bg-ink/85">
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
        <Button size="sm" variant="accent" onClick={() => onLogCall(item)}>
          <ClipboardCheck className="size-3.5" />
          {t("leads.postService.logCall")}
        </Button>
      </div>
    </Card>
  )
}
