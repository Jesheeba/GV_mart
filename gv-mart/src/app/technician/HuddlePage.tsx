import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { useToast } from "@/components/ui/toast-context"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { useProfile } from "@/hooks/useProfile"
import { useAgendaIssues, useIssueTasks, useMeetingLog, useRaiseIssue, useRecentMeetings } from "@/hooks/useHuddle"
import { useAssignableProfiles } from "@/hooks/useTasks"
import { todayIst } from "@/services/huddle"
import { IssueCard } from "@/app/admin/huddle/IssueCard"
import { formatDate } from "@/lib/formatDate"

// Read-only by design for existing items: no edit/solve/task controls are rendered (and
// RLS would reject the writes anyway — meeting_* writes are is_staff()-gated). A technician can only
// RAISE a new problem, through the raise_huddle_issue RPC; the master is notified by a trigger.
export function HuddlePage() {
  const { t } = useTranslation()
  const { data: profile, isLoading, isError, refetch } = useProfile()
  const orgId = profile?.org_id
  const date = todayIst()
  const { toast } = useToast()
  const raise = useRaiseIssue()
  const [draft, setDraft] = useState("")

  const log = useMeetingLog(orgId, date)
  const issuesQuery = useAgendaIssues(orgId, date, log.data?.id ?? null, !log.isLoading)
  const recent = useRecentMeetings(orgId)
  const { data: profiles } = useAssignableProfiles(orgId)
  const names = useMemo(() => new Map((profiles ?? []).map((p) => [p.id, p.full_name])), [profiles])

  const issues = useMemo(() => (issuesQuery.data ?? []).filter((i) => i.date_raised <= date), [issuesQuery.data, date])
  const open = issues.filter((i) => i.status === "open")
  const solvedToday = issues.filter((i) => i.status === "solved")
  const tasks = useIssueTasks(orgId, useMemo(() => issues.map((i) => i.id), [issues]))
  const tasksFor = (id: string) => (tasks.data ?? []).filter((tsk) => tsk.ref_id === id)

  const pastMeetings = (recent.data ?? []).filter((m) => m.meeting_date !== date && m.general_notes)

  if (isLoading) return <FullPageLoader />
  if (isError || !profile) return <FullPageError message={t("common.actionFailed")} onRetry={() => void refetch()} />

  return (
    <div className="space-y-4 pt-2">
      <div>
        <h1 className="text-xl font-bold text-text">{t("nav.huddle")}</h1>
        <p className="text-xs text-text-muted">{t("huddle.technicianSubtitle")}</p>
      </div>

      <Card className="gap-2">
        <h3 className="text-sm font-semibold text-text">{t("huddle.todayNotes", { date: formatDate(date) })}</h3>
        <p className="whitespace-pre-wrap text-sm text-text-muted" data-testid="huddle-today-notes">
          {log.data?.general_notes || (log.data ? t("huddle.noNotes") : t("huddle.notLoggedYet"))}
        </p>
      </Card>

      <Card className="gap-2">
        <h3 className="text-sm font-semibold text-text">{t("huddle.raiseTitle")}</h3>
        <p className="text-xs text-text-muted">{t("huddle.raiseHint")}</p>
        <textarea
          value={draft}
          maxLength={1000}
          rows={3}
          onChange={(e) => setDraft(e.target.value)}
          placeholder={t("huddle.raisePlaceholder")}
          className="w-full rounded-xl border border-border bg-surface px-3 py-2 text-sm text-text outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"
        />
        <div className="flex justify-end">
          <Button
            type="button"
            size="sm"
            disabled={draft.trim().length === 0 || raise.isPending}
            onClick={() =>
              raise.mutate(draft, {
                onSuccess: () => {
                  setDraft("")
                  toast.success(t("huddle.raised"))
                },
                onError: () => toast.error(t("huddle.raiseFailed")),
              })
            }
          >
            {t("huddle.raiseButton")}
          </Button>
        </div>
      </Card>

      <section className="space-y-2.5">
        <h2 className="text-sm font-semibold text-text-muted">{t("huddle.sections.open", { count: open.length })}</h2>
        {open.length === 0 ? (
          <Card className="items-center py-5 text-sm text-text-muted">{t("huddle.noIssues")}</Card>
        ) : (
          open.map((i) => <IssueCard key={i.id} issue={i} names={names} tasks={tasksFor(i.id)} />)
        )}
      </section>

      {solvedToday.length > 0 && (
        <section className="space-y-2.5">
          <h2 className="text-sm font-semibold text-text-muted">{t("huddle.sections.solved", { count: solvedToday.length })}</h2>
          {solvedToday.map((i) => (
            <IssueCard key={i.id} issue={i} names={names} tasks={tasksFor(i.id)} />
          ))}
        </section>
      )}

      {pastMeetings.length > 0 && (
        <section className="space-y-2.5">
          <h2 className="text-sm font-semibold text-text-muted">{t("huddle.recentMeetings")}</h2>
          {pastMeetings.map((m) => (
            <Card key={m.id} className="gap-1">
              <p className="text-xs font-semibold text-text">{formatDate(m.meeting_date)}</p>
              <p className="whitespace-pre-wrap text-sm text-text-muted">{m.general_notes}</p>
            </Card>
          ))}
        </section>
      )}
    </div>
  )
}
