import { useTranslation } from "react-i18next"
import { CalendarClock, History, TriangleAlert } from "lucide-react"
import { cn } from "@/lib/utils"
import { formatIstDateTime, isOverdueNow } from "@/lib/lead-followups"
import type { LeadListItem } from "@/services/automation"

/** Next follow-up date/time — red the moment its time has passed. `null` renders the "No follow-up" warning. */
export function FollowupChip({ dueAt, className }: { dueAt: string | null; className?: string }) {
  const { t, i18n } = useTranslation()
  if (!dueAt) {
    return (
      <span className={cn("inline-flex w-fit items-center gap-1 rounded-full border border-warning/40 bg-warning/10 px-2 py-0.5 text-[11px] font-semibold text-warning", className)}>
        <CalendarClock className="size-3" />
        {t("leads.followup.none")}
      </span>
    )
  }
  const overdue = isOverdueNow(dueAt)
  return (
    <span
      className={cn(
        "inline-flex w-fit items-center gap-1 rounded-full border px-2 py-0.5 text-[11px] font-semibold",
        overdue ? "border-danger/40 bg-danger/10 text-danger" : "border-border bg-surface-alt text-text",
        className
      )}
    >
      <CalendarClock className="size-3" />
      {overdue ? `${t("leads.followup.overdue")} · ` : ""}
      {formatIstDateTime(dueAt, i18n.language)}
    </span>
  )
}

/** "Postponed ×N" — how many times in a row the customer has been put off. */
export function PostponeBadge({ count, className }: { count: number; className?: string }) {
  const { t } = useTranslation()
  if (count <= 0) return null
  return (
    <span className={cn("inline-flex w-fit items-center gap-1 rounded-full bg-surface-alt px-2 py-0.5 text-[11px] font-semibold text-text-muted", className)}>
      <History className="size-3" />
      {t("leads.followup.postponed", { count })}
    </span>
  )
}

export function StuckBadge({ className }: { className?: string }) {
  const { t } = useTranslation()
  return (
    <span className={cn("inline-flex w-fit items-center gap-1 rounded-full border border-danger/40 bg-danger/10 px-2 py-0.5 text-[11px] font-bold text-danger", className)}>
      <TriangleAlert className="size-3" />
      {t("leads.followup.stuck")}
    </span>
  )
}

/** Next follow-up for a list row/card: due chip (red once overdue), "no follow-up" warning for open leads, postpone + stuck flags. Closed leads show nothing. */
export function FollowupCell({ lead, stuckAt }: { lead: LeadListItem; stuckAt: number }) {
  if (lead.status === "won" || lead.status === "lost") return <span className="text-[13px] font-medium text-text-muted">—</span>
  return (
    <span className="flex flex-wrap items-center gap-1">
      <FollowupChip dueAt={lead.next_followup_at} />
      <PostponeBadge count={lead.postpone_count} />
      {lead.postpone_count >= stuckAt ? <StuckBadge /> : null}
    </span>
  )
}
