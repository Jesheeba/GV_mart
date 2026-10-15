import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import { useToast } from "@/components/ui/toast-context"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { useProfile } from "@/hooks/useProfile"
import { useAgendaIssues, useIssueTasks, useMeetingLog, useProposeHuddleSolution, useRaiseHuddleIssue, useRecentMeetings } from "@/hooks/useHuddle"
import { useAssignableProfiles } from "@/hooks/useTasks"
import { todayIst } from "@/services/huddle"
import { IssueCard } from "@/app/admin/huddle/IssueCard"

// A technician reads the huddle, may RAISE a problem and PROPOSE a solution (through two narrow RPCs, so the master is told),
// and cannot edit, solve or task anything: meeting_* direct writes stay is_staff()-gated.
export function HuddlePage() {
  const { t } = useTranslation()
  const { data: profile, isLoading, isError, refetch } = useProfile()
  const orgId = profile?.org_id
  const date = todayIst()
  const { toast } = useToast()
  const raise = useRaiseHuddleIssue()
  const propose = useProposeHuddleSolution()
  const [problem, setProblem] = useState("")
  const [proposing, setProposing] = useState<string | null>(null)
  const [solution, setSolution] = useState("")

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

      <Card className="gap-2" data-testid="huddle-raise">
        <h3 className="text-sm font-semibold text-text">{t("huddle.raiseTitle")}</h3>
        <textarea
          rows={3}
          maxLength={1000}
          value={problem}
          onChange={(e) => setProblem(e.target.value)}
          placeholder={t("huddle.raisePlaceholder")}
          className="w-full rounded-xl border border-border bg-surface px-3 py-2 text-base text-text outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"
        />
        <div className="flex justify-end">
          <Button
            type="button"
            className="h-11"
            disabled={problem.trim().length < 3 || raise.isPending}
            onClick={() =>
              raise.mutate(problem.trim(), {
                onSuccess: () => {
                  setProblem("")
                  toast.success(t("huddle.raised"))
                },
                onError: (e) => toast.error(e instanceof Error && e.message ? e.message : t("common.actionFailed")),
              })
            }
          >
            {t("huddle.raiseButton")}
          </Button>
        </div>
      </Card>

      <Card className="gap-2">
        <h3 className="text-sm font-semibold text-text">{t("huddle.todayNotes", { date })}</h3>
        <p className="whitespace-pre-wrap text-sm text-text-muted" data-testid="huddle-today-notes">
          {log.data?.general_notes || (log.data ? t("huddle.noNotes") : t("huddle.notLoggedYet"))}
        </p>
      </Card>

      <section className="space-y-2.5">
        <h2 className="text-sm font-semibold text-text-muted">{t("huddle.sections.open", { count: open.length })}</h2>
        {open.length === 0 ? (
          <Card className="items-center py-5 text-sm text-text-muted">{t("huddle.noIssues")}</Card>
        ) : (
          open.map((i) => (
            <IssueCard
              key={i.id}
              issue={i}
              names={names}
              tasks={tasksFor(i.id)}
              onProposeSolution={() => {
                setSolution("")
                setProposing(i.id)
              }}
            />
          ))
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

      <Dialog open={!!proposing} onOpenChange={(o) => !o && setProposing(null)}>
        <DialogContent>
          <DialogTitle>{t("huddle.proposeSolution")}</DialogTitle>
          <DialogDescription>{t("huddle.proposeHint")}</DialogDescription>
          <textarea
            rows={4}
            maxLength={2000}
            value={solution}
            onChange={(e) => setSolution(e.target.value)}
            placeholder={t("huddle.proposePlaceholder")}
            className="w-full rounded-xl border border-border bg-surface px-3 py-2 text-base text-text outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"
          />
          <div className="flex justify-end gap-2">
            <Button type="button" variant="ghost" className="h-11" onClick={() => setProposing(null)}>
              {t("common.cancel")}
            </Button>
            <Button
              type="button"
              className="h-11"
              disabled={solution.trim().length < 3 || propose.isPending}
              onClick={() =>
                proposing &&
                propose.mutate(
                  { issueId: proposing, solution: solution.trim() },
                  {
                    onSuccess: () => {
                      setProposing(null)
                      toast.success(t("huddle.proposed"))
                    },
                    onError: (e) => toast.error(e instanceof Error && e.message ? e.message : t("common.actionFailed")),
                  }
                )
              }
            >
              {t("huddle.proposeSend")}
            </Button>
          </div>
        </DialogContent>
      </Dialog>

      {pastMeetings.length > 0 && (
        <section className="space-y-2.5">
          <h2 className="text-sm font-semibold text-text-muted">{t("huddle.recentMeetings")}</h2>
          {pastMeetings.map((m) => (
            <Card key={m.id} className="gap-1">
              <p className="text-xs font-semibold text-text">{m.meeting_date}</p>
              <p className="whitespace-pre-wrap text-sm text-text-muted">{m.general_notes}</p>
            </Card>
          ))}
        </section>
      )}
    </div>
  )
}
