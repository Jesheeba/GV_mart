import { useTranslation } from "react-i18next"
import { Link } from "react-router-dom"
import { ArrowRightLeft, CalendarCheck, CalendarClock, CalendarX, FileText, MessageSquareText, Phone, StickyNote, UserRound } from "lucide-react"
import { Skeleton } from "@/components/ui/skeleton"
import { useLeadTimeline } from "@/hooks/useLeadFollowups"
import { formatCurrency } from "@/lib/sale-calc"
import { formatIstDateTime, formatIstStamp } from "@/lib/lead-followups"
import { lostReasonLabel } from "@/lib/lead-lost-reasons"
import { cn } from "@/lib/utils"
import type { TimelineEvent } from "@/services/leadFollowups"

type Detail = Record<string, unknown>

const KIND_ICON: Record<string, typeof Phone> = {
  outcome: Phone,
  note: StickyNote,
  stage_change: ArrowRightLeft,
  activity: MessageSquareText,
  followup_set: CalendarClock,
  followup_done: CalendarCheck,
  followup_cancelled: CalendarX,
  quotation: FileText,
}

/** Unified, newest-first history of a lead: outcomes, notes, stage changes, follow-ups set/done/cancelled, quotations — each with its author and IST time. */
export function LeadTimeline({ leadId }: { leadId: string }) {
  const { t, i18n } = useTranslation()
  const timeline = useLeadTimeline(leadId)

  if (timeline.isLoading) return <Skeleton className="h-24 w-full" />
  if (timeline.isError) return <p className="text-xs text-danger">{t("leads.timeline.loadFailed")}</p>
  const events = timeline.data ?? []
  if (events.length === 0) return <p className="text-xs text-text-muted">{t("leads.timeline.empty")}</p>

  return (
    <ol className="space-y-2" data-testid="lead-timeline">
      {events.map((e, i) => (
        <TimelineRow key={`${e.kind}-${e.event_at}-${i}`} event={e} lang={i18n.language} t={t} />
      ))}
    </ol>
  )
}

function authorText(e: TimelineEvent, t: (k: string) => string) {
  if (e.author_kind === "system") return t("leads.timeline.system")
  if (e.author_kind === "before_upgrade") return t("leads.timeline.beforeUpgrade")
  return e.author_name ?? t("leads.timeline.unknownUser")
}

function TimelineRow({ event: e, lang, t }: { event: TimelineEvent; lang: string; t: (k: string, o?: Record<string, unknown>) => string }) {
  const d = (e.detail ?? {}) as Detail
  const Icon = KIND_ICON[e.kind] ?? UserRound
  const note = typeof d.note === "string" && d.note ? d.note : null

  let title: string
  let body: React.ReactNode = null
  switch (e.kind) {
    case "outcome": {
      title = lang.startsWith("ta") && d.outcome_label_ta ? String(d.outcome_label_ta) : String(d.outcome_label_en ?? e.title)
      body = (
        <>
          <span className="text-text-muted"> · {t(`leads.followup.type.${String(d.type)}`)}</span>
          {note ? <p className="mt-0.5 text-text-muted">{note}</p> : null}
        </>
      )
      break
    }
    case "note":
      title = t("leads.timeline.note")
      body = note ? <p className="mt-0.5 text-text-muted">{note}</p> : null
      break
    case "stage_change": {
      const from = d.from_status ? t(`leads.status.${String(d.from_status)}`) : null
      const to = d.to_status ? t(`leads.status.${String(d.to_status)}`) : String(note ?? "")
      title = from ? t("leads.timeline.stageChange", { from, to }) : t("leads.timeline.stageSet", { to })
      if (d.to_status === "lost" && note) body = <p className="mt-0.5 text-text-muted">{t("leads.detail.lostReasonLabel")}: {lostReasonLabel(note, t as never)}</p>
      break
    }
    case "followup_set": {
      const source = String(d.source ?? "")
      title = t("leads.timeline.followupSet", { when: formatIstDateTime(String(d.due_at), lang), type: t(`leads.followup.type.${String(d.type)}`) })
      body = (
        <>
          {source && source !== "outcome" && source !== "manual" ? <span className="text-text-muted"> · {t(`leads.timeline.source.${source}`)}</span> : null}
          {note ? <p className="mt-0.5 text-text-muted">{note}</p> : null}
        </>
      )
      break
    }
    case "followup_done":
      title = t(d.early ? "leads.timeline.followupDoneEarly" : "leads.timeline.followupDone", { when: formatIstDateTime(String(d.due_at), lang) })
      break
    case "followup_cancelled": {
      const reason = String(d.cancel_reason ?? "")
      title =
        reason === "rescheduled"
          ? t("leads.timeline.followupRescheduled", { when: formatIstDateTime(String(d.due_at), lang) })
          : t("leads.timeline.followupCancelled", { when: formatIstDateTime(String(d.due_at), lang), why: t(`leads.timeline.cancelReason.${reason}`) })
      if (reason === "rescheduled" && d.reschedule_reason) body = <p className="mt-0.5 text-text-muted">{t("leads.timeline.reason")}: {String(d.reschedule_reason)}</p>
      break
    }
    case "quotation":
      title = t("leads.timeline.quotation", { total: formatCurrency(Number(d.total ?? 0)), status: t(`quotations.status.${String(d.status)}`) })
      body = (
        <Link to={`/admin/quotations/${String(d.quotation_id)}`} className="ml-1 text-accent hover:underline">
          {t("leads.timeline.open")}
        </Link>
      )
      break
    default:
      title = t(`leads.activityType.${String(d.type ?? e.title)}`, { defaultValue: String(d.type ?? e.title) })
      body = note ? <p className="mt-0.5 text-text-muted">{note}</p> : null
  }

  return (
    <li className="flex gap-2.5 rounded-lg bg-surface-alt px-3 py-2 text-xs" data-kind={e.kind}>
      <Icon className={cn("mt-0.5 size-3.5 shrink-0", e.kind === "followup_cancelled" ? "text-text-muted" : "text-text")} />
      <div className="min-w-0 flex-1">
        <div className="text-text">
          <span className="font-semibold">{title}</span>
          {body}
        </div>
        <p className="mt-0.5 text-[11px] text-text-muted">
          {authorText(e, t)} · {formatIstStamp(e.event_at, lang)}
        </p>
      </div>
    </li>
  )
}
