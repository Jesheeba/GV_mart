import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Link, useParams } from "react-router-dom"
import { ArrowLeft, CalendarPlus, ClipboardCheck, Loader2, MessageCircle, Phone, RotateCcw, StickyNote, UserRound } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Skeleton } from "@/components/ui/skeleton"
import { StatusDot } from "@/components/shared/StatusDot"
import { useToast } from "@/components/ui/toast-context"
import { useProfile } from "@/hooks/useProfile"
import { useLead } from "@/hooks/useAutomation"
import { useAddLeadNote, useLeadAssignees, useLeadSchedule } from "@/hooks/useLeadFollowups"
import { AssignLeadDialog } from "./AssignLeadDialog"
import { assignActionFor, canScheduleLead } from "@/lib/lead-assign"
import type { UserRole } from "@/lib/roles"
import { useLeadSourceOptions } from "@/hooks/useLeadSources"
import { LeadDetailPanel } from "./LeadDetailPanel"
import { LeadTimeline } from "./LeadTimeline"
import { LogOutcomeSheet } from "./LogOutcomeSheet"
import { RescheduleDialog } from "./RescheduleDialog"
import { SetFollowupDialog } from "./SetFollowupDialog"
import { FollowupChip, PostponeBadge, StuckBadge } from "./FollowupBadges"
import { rememberCall } from "@/lib/call-return"
import { telHref } from "@/lib/lead-followups"
import { toWhatsappLink } from "@/lib/whatsapp-link"
import { DEFAULT_LEAD_SCHEDULE } from "@/services/leadFollowups"

/** Full lead page: header (who, stage, next follow-up, postpones), quick actions, unified timeline, and the lead's other actions. */
export function LeadDetailPage() {
  const { t } = useTranslation()
  const { toast } = useToast()
  const { leadId } = useParams<{ leadId: string }>()
  const { data: profile } = useProfile()
  const { label: sourceLabel } = useLeadSourceOptions()
  const schedule = useLeadSchedule(profile?.org_id).data ?? DEFAULT_LEAD_SCHEDULE
  const lead = useLead(leadId)
  const addNote = useAddLeadNote()

  const [outcomeOpen, setOutcomeOpen] = useState(false)
  const [rescheduleOpen, setRescheduleOpen] = useState(false)
  const [setFollowupOpen, setSetFollowupOpen] = useState(false)
  const [noteOpen, setNoteOpen] = useState(false)
  const [assignOpen, setAssignOpen] = useState(false)
  const assignees = useLeadAssignees(profile?.org_id, profile?.role as UserRole | undefined).data ?? []
  const [note, setNote] = useState("")

  if (lead.isLoading) {
    return (
      <div className="space-y-4 pt-2">
        <Skeleton className="h-28 w-full" />
        <Skeleton className="h-64 w-full" />
      </div>
    )
  }
  const l = lead.data
  if (lead.isError || !l) {
    return (
      <div className="space-y-3 pt-2">
        <Link to="/admin/leads" className="inline-flex items-center gap-1 text-xs font-semibold text-text-muted hover:text-text">
          <ArrowLeft className="size-3.5" />
          {t("leads.detail.backToLeads")}
        </Link>
        <p className="text-sm text-text-muted">{t("leads.detail.notFound")}</p>
      </div>
    )
  }

  const closed = l.status === "won" || l.status === "lost"
  const name = l.customers?.name ?? l.name
  const mobile = l.mobile ?? l.customers?.mobile ?? null
  const stuck = !closed && l.postpone_count >= schedule.lead_stuck_postpones
  const tone = l.status === "won" ? "success" : l.status === "lost" ? "danger" : l.status === "new" ? "info" : "warning"
  const sheetLead = { id: l.id, name, mobile, status: l.status }
  const assigneeName = assignees.find((a) => a.id === l.assigned_to)?.full_name ?? null
  const canSchedule = canScheduleLead(profile?.role as UserRole | undefined, profile?.id, l.assigned_to, assignees)
  const assignAction = closed ? null : assignActionFor(profile?.role as UserRole | undefined, profile?.id, l.assigned_to, assignees)

  async function saveNote() {
    if (!note.trim()) return
    try {
      await addNote.mutateAsync({ leadId: l!.id, note: note.trim() })
      setNote("")
      setNoteOpen(false)
      toast.success(t("leads.detail.noteSaved"))
    } catch (e) {
      toast.error(e instanceof Error && e.message ? e.message : t("common.actionFailed"))
    }
  }

  return (
    <div className="space-y-4 pt-2">
      <Link to={closed ? "/admin/leads" : "/admin/my-day"} className="inline-flex items-center gap-1 text-xs font-semibold text-text-muted hover:text-text">
        <ArrowLeft className="size-3.5" />
        {closed ? t("leads.detail.backToLeads") : t("leads.detail.backToMyDay")}
      </Link>

      <Card className="gap-3 px-5" data-testid="lead-header">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div className="min-w-0 space-y-1">
            <h1 className="truncate text-xl font-bold text-text">{name}</h1>
            {mobile ? (
              <a href={telHref(mobile)} onClick={() => rememberCall(sheetLead)} className="inline-flex items-center gap-1.5 text-sm font-medium text-text hover:underline">
                <Phone className="size-3.5" />
                {mobile}
              </a>
            ) : (
              <span className="text-sm text-text-muted">—</span>
            )}
            <div className="flex flex-wrap items-center gap-1.5 pt-0.5 text-xs text-text-muted">
              <span>{sourceLabel(l.source)}</span>
              {l.kind ? <span>· {t(`leads.kind.${l.kind}`)}</span> : null}
              {l.enquiry_type ? <span>· {t(`leads.enquiryType.${l.enquiry_type}`)}</span> : null}
              {l.product_category ? <span>· {t(`masters.categories.${l.product_category}`)}</span> : null}
              <span className="inline-flex items-center gap-1" data-testid="lead-assignee">
                · <UserRound className="size-3" />
                {assigneeName ?? t("leads.assign.unassigned")}
              </span>
            </div>
            {l.notes ? <p className="whitespace-pre-wrap pt-1.5 text-sm text-text">{l.notes}</p> : null}
          </div>
          <div className="flex flex-wrap items-center justify-end gap-1.5">
            <StatusDot tone={tone} label={t(`leads.status.${l.status}`)} />
            {!closed ? <FollowupChip dueAt={l.next_followup_at} /> : null}
            {!closed ? <PostponeBadge count={l.postpone_count} /> : null}
            {stuck ? <StuckBadge /> : null}
          </div>
        </div>

        <div className="flex flex-wrap gap-1.5">
          {closed ? (
            <Button size="sm" variant="accent" onClick={() => setOutcomeOpen(true)}>
              <RotateCcw className="size-3.5" />
              {t("leads.detail.reopen")}
            </Button>
          ) : (
            <>
              <Button size="sm" variant="accent" onClick={() => setOutcomeOpen(true)}>
                <ClipboardCheck className="size-3.5" />
                {t("leads.followup.logOutcome")}
              </Button>
              {l.next_followup_at ? (
                <Button size="sm" variant="outline" onClick={() => setRescheduleOpen(true)}>
                  {t("leads.followup.reschedule")}
                </Button>
              ) : canSchedule ? (
                <Button size="sm" variant="outline" onClick={() => setSetFollowupOpen(true)} data-testid="set-followup">
                  <CalendarPlus className="size-3.5" />
                  {t("leads.followup.setButton")}
                </Button>
              ) : null}
            </>
          )}
          {assignAction ? (
            <Button size="sm" variant="outline" onClick={() => setAssignOpen(true)}>
              <UserRound className="size-3.5" />
              {t(`leads.assign.action.${assignAction}`)}
            </Button>
          ) : null}
          <Button size="sm" variant="outline" onClick={() => setNoteOpen((v) => !v)}>
            <StickyNote className="size-3.5" />
            {t("leads.detail.addNote")}
          </Button>
          {mobile ? (
            <a
              href={toWhatsappLink(mobile, "")}
              target="_blank"
              rel="noreferrer"
              className="inline-flex h-8 items-center gap-1 rounded-full border border-border px-4 text-[0.8rem] font-medium text-text hover:bg-surface-alt"
            >
              <MessageCircle className="size-3.5" />
              {t("leads.followup.whatsapp")}
            </a>
          ) : null}
        </div>

        {noteOpen ? (
          <div className="flex gap-2">
            <Input autoFocus value={note} onChange={(e) => setNote(e.target.value)} placeholder={t("leads.detail.notePlaceholder")} onKeyDown={(e) => e.key === "Enter" && saveNote()} />
            <Button size="sm" onClick={saveNote} disabled={!note.trim() || addNote.isPending}>
              {addNote.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("common.save")}
            </Button>
          </div>
        ) : null}
      </Card>

      <div className="flex flex-col gap-4 lg:flex-row lg:items-start">
        <Card className="min-w-0 gap-3 px-5 lg:flex-1">
          <h2 className="text-sm font-semibold text-text">{t("leads.detail.history")}</h2>
          <LeadTimeline leadId={l.id} />
        </Card>
        <div className="lg:w-80 lg:shrink-0">
          <LeadDetailPanel lead={l} />
        </div>
      </div>

      <LogOutcomeSheet lead={sheetLead} open={outcomeOpen} onOpenChange={setOutcomeOpen} />
      <RescheduleDialog lead={{ id: l.id, name }} open={rescheduleOpen} onOpenChange={setRescheduleOpen} />
      <SetFollowupDialog lead={{ id: l.id, name }} open={setFollowupOpen} onOpenChange={setSetFollowupOpen} />

      <AssignLeadDialog leads={[{ id: l.id, name, assignedTo: l.assigned_to }]} open={assignOpen} onOpenChange={setAssignOpen} />
    </div>
  )
}
