import { useEffect, useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { BellRing, Plus, Search } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { DatePicker } from "@/components/ui/date-picker"
import { Input } from "@/components/ui/input"
import { Skeleton } from "@/components/ui/skeleton"
import { useToast } from "@/components/ui/toast-context"
import { useProfile } from "@/hooks/useProfile"
import {
  useAgendaIssues,
  useCreateIssue,
  useHuddlePerformance,
  useHuddleReminderTime,
  useIssueTasks,
  useMeetingLog,
  useSaveNotes,
  useSearchIssues,
  useSetIssueStatus,
  useSetReminderTime,
  useUpdateIssue,
} from "@/hooks/useHuddle"
import { useAssignableProfiles } from "@/hooks/useTasks"
import { formatCurrency } from "@/lib/sale-calc"
import { cn } from "@/lib/utils"
import { todayIst, type IssueSearch, type MeetingIssue } from "@/services/huddle"
import { AssignTaskDialog } from "@/app/admin/tasks/AssignTaskDialog"
import { IssueCard } from "./IssueCard"
import { IssueDialog } from "./IssueDialog"

type View = "today" | "history"

export function HuddlePage() {
  const { t } = useTranslation()
  const [view, setView] = useState<View>("today")
  return (
    <div className="space-y-4 pt-2">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold text-text">{t("nav.huddle")}</h1>
          <p className="text-sm text-text-muted">{t("huddle.subtitle")}</p>
        </div>
        <div className="flex gap-[3px] rounded-full border border-border bg-surface p-1">
          {(["today", "history"] as const).map((v) => (
            <button
              key={v}
              type="button"
              onClick={() => setView(v)}
              className={cn("rounded-full px-4 py-1.5 text-sm font-medium transition-colors", view === v ? "bg-ink text-white" : "text-text-muted")}
            >
              {t(`huddle.view.${v}`)}
            </button>
          ))}
        </div>
      </div>
      {view === "today" ? <MeetingView /> : <HistoryView />}
    </div>
  )
}

function useNameMap(orgId: string | undefined) {
  const { data } = useAssignableProfiles(orgId)
  const profiles = useMemo(() => data ?? [], [data])
  const names = useMemo(() => new Map(profiles.map((p) => [p.id, p.full_name])), [profiles])
  return { profiles, names }
}

function MeetingView() {
  const { t } = useTranslation()
  const { toast } = useToast()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id
  const userId = profile?.id ?? ""
  const isMaster = profile?.role === "master"

  const [date, setDate] = useState(todayIst())
  const log = useMeetingLog(orgId, date)
  const logReady = !log.isLoading
  const issuesQuery = useAgendaIssues(orgId, date, log.data?.id ?? null, logReady)
  const { profiles, names } = useNameMap(orgId)

  // A past agenda shouldn't show problems raised after that day.
  const issues = useMemo(() => (issuesQuery.data ?? []).filter((i) => i.date_raised <= date), [issuesQuery.data, date])
  const carried = issues.filter((i) => i.status === "open" && i.date_raised < date)
  const raisedHere = issues.filter((i) => i.status === "open" && i.date_raised === date)
  const solved = issues.filter((i) => i.status === "solved")

  const issueIds = useMemo(() => issues.map((i) => i.id), [issues])
  const tasks = useIssueTasks(orgId, issueIds)
  const tasksByIssue = useMemo(() => {
    const m = new Map<string, NonNullable<typeof tasks.data>>()
    for (const tsk of tasks.data ?? []) m.set(tsk.ref_id, [...(m.get(tsk.ref_id) ?? []), tsk])
    return m
  }, [tasks.data])

  const perf = useHuddlePerformance(orgId, date, true)

  const [notes, setNotes] = useState("")
  useEffect(() => {
    setNotes(log.data?.general_notes ?? "")
  }, [log.data?.id, log.data?.general_notes, date])

  const saveNotes = useSaveNotes(orgId ?? "", date, userId)
  const createIssue = useCreateIssue(orgId ?? "", date, userId)
  const updateIssue = useUpdateIssue()
  const setStatus = useSetIssueStatus(date)

  const [dialog, setDialog] = useState<{ issue: MeetingIssue | null } | null>(null)
  const [taskFor, setTaskFor] = useState<MeetingIssue | null>(null)

  if (!orgId) return <Skeleton className="h-40 w-full" />

  function failed() {
    toast.error(t("common.actionFailed"))
  }

  function renderIssues(list: MeetingIssue[]) {
    return list.map((issue) => (
      <IssueCard
        key={issue.id}
        issue={issue}
        names={names}
        tasks={tasksByIssue.get(issue.id) ?? []}
        busy={setStatus.isPending}
        onEdit={() => setDialog({ issue })}
        onCreateTask={() => setTaskFor(issue)}
        onToggleStatus={() => setStatus.mutate({ id: issue.id, status: issue.status === "open" ? "solved" : "open" }, { onError: failed })}
      />
    ))
  }

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-3">
        <div className="w-48">
          <DatePicker id="huddleDate" value={date} max={todayIst()} onChange={(v) => v && setDate(v)} aria-label={t("huddle.meetingDate")} />
        </div>
        <p className="text-sm text-text-muted">
          {log.data
            ? t("huddle.recordedBy", { name: (log.data.recorded_by && names.get(log.data.recorded_by)) || "—" })
            : t("huddle.notLoggedYet")}
        </p>
      </div>

      <Card className="gap-3" data-testid="huddle-performance">
        <h3 className="px-1 text-sm font-semibold text-text">{t("huddle.performance.title", { date: perf.data?.date ?? "" })}</h3>
        {perf.isLoading ? (
          <Skeleton className="h-14 w-full" />
        ) : perf.isError || !perf.data ? (
          <p className="px-1 text-sm text-text-muted">{t("huddle.performance.unavailable")}</p>
        ) : (
          <div className="grid grid-cols-2 gap-3 px-1 sm:grid-cols-4">
            <Metric label={t("huddle.performance.collected")} value={formatCurrency(perf.data.collected)} />
            <Metric label={t("huddle.performance.completedVisits")} value={String(perf.data.completedVisits)} />
            <Metric label={t("huddle.performance.within24h")} value={perf.data.resolvedWithin24hPercent === null ? "—" : `${perf.data.resolvedWithin24hPercent}%`} />
            <Metric label={t("huddle.performance.openTickets")} value={String(perf.data.openTickets)} />
          </div>
        )}
      </Card>

      <Card className="gap-3">
        <h3 className="px-1 text-sm font-semibold text-text">{t("huddle.generalNotes")}</h3>
        <textarea
          rows={3}
          value={notes}
          onChange={(e) => setNotes(e.target.value)}
          placeholder={t("huddle.generalNotesPlaceholder")}
          className="w-full rounded-xl border border-border bg-surface px-3 py-2 text-sm text-text outline-none focus-visible:ring-2 focus-visible:ring-accent/40"
          data-testid="huddle-notes"
        />
        <div className="flex justify-end">
          <Button
            type="button"
            size="sm"
            disabled={saveNotes.isPending || notes === (log.data?.general_notes ?? "")}
            onClick={() => saveNotes.mutate(notes, { onSuccess: () => toast.success(t("huddle.saved")), onError: failed })}
          >
            {t("huddle.saveNotes")}
          </Button>
        </div>
      </Card>

      <div className="flex items-center justify-between">
        <h2 className="text-lg font-semibold text-text">{t("huddle.agenda")}</h2>
        <Button type="button" onClick={() => setDialog({ issue: null })}>
          <Plus className="size-3.5" />
          {t("huddle.addIssue")}
        </Button>
      </div>

      {issuesQuery.isLoading ? (
        <Skeleton className="h-24 w-full" />
      ) : issuesQuery.isError ? (
        <p className="text-sm text-danger">{t("huddle.loadFailed")}</p>
      ) : issues.length === 0 ? (
        <Card className="items-center py-8 text-sm text-text-muted">{t("huddle.noIssues")}</Card>
      ) : (
        <div className="space-y-5">
          <Section title={t("huddle.sections.carried", { count: carried.length })} show={carried.length > 0}>
            {renderIssues(carried)}
          </Section>
          <Section title={t("huddle.sections.raised", { count: raisedHere.length })} show={raisedHere.length > 0}>
            {renderIssues(raisedHere)}
          </Section>
          <Section title={t("huddle.sections.solved", { count: solved.length })} show={solved.length > 0}>
            {renderIssues(solved)}
          </Section>
        </div>
      )}

      {isMaster && <ReminderSetting orgId={orgId} />}

      {dialog && (
        <IssueDialog
          // Remount per target so the form's initial state tracks the issue being edited.
          key={dialog.issue?.id ?? "new"}
          issue={dialog.issue}
          profiles={profiles}
          saving={createIssue.isPending || updateIssue.isPending}
          onClose={() => setDialog(null)}
          onSubmit={(input) => {
            const opts = { onSuccess: () => setDialog(null), onError: failed }
            if (dialog.issue) updateIssue.mutate({ id: dialog.issue.id, input }, opts)
            else createIssue.mutate(input, opts)
          }}
        />
      )}

      {taskFor && (
        <AssignTaskDialog
          orgId={orgId}
          userId={userId}
          initialTitle={taskFor.description.slice(0, 120)}
          initialDescription={taskFor.root_cause ? `${t("huddle.rootCause")}: ${taskFor.root_cause}` : ""}
          refType="meeting_issue"
          refId={taskFor.id}
          onClose={() => setTaskFor(null)}
        />
      )}
    </div>
  )
}

function Section({ title, show, children }: { title: string; show: boolean; children: React.ReactNode }) {
  if (!show) return null
  return (
    <section className="space-y-2.5">
      <h3 className="text-sm font-semibold text-text-muted">{title}</h3>
      {children}
    </section>
  )
}

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <p className="text-xs text-text-muted">{label}</p>
      <p className="text-lg font-bold text-text">{value}</p>
    </div>
  )
}

function ReminderSetting({ orgId }: { orgId: string }) {
  const { t } = useTranslation()
  const { toast } = useToast()
  const current = useHuddleReminderTime(orgId)
  const save = useSetReminderTime(orgId)
  const [value, setValue] = useState("")
  useEffect(() => {
    setValue(current.data ? current.data.slice(0, 5) : "")
  }, [current.data])

  return (
    <Card className="gap-2">
      <h3 className="flex items-center gap-2 px-1 text-sm font-semibold text-text">
        <BellRing className="size-4" />
        {t("huddle.reminder.title")}
      </h3>
      <p className="px-1 text-xs text-text-muted">{t("huddle.reminder.hint")}</p>
      <div className="flex items-center gap-2 px-1">
        <Input type="time" className="w-36" value={value} onChange={(e) => setValue(e.target.value)} aria-label={t("huddle.reminder.title")} data-testid="huddle-reminder-time" />
        <Button
          type="button"
          size="sm"
          disabled={save.isPending}
          onClick={() =>
            save.mutate(value ? `${value}:00` : null, {
              onSuccess: () => toast.success(t("huddle.saved")),
              onError: () => toast.error(t("common.actionFailed")),
            })
          }
        >
          {t("common.save")}
        </Button>
      </div>
    </Card>
  )
}

function HistoryView() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id
  const { names } = useNameMap(orgId)
  const [filter, setFilter] = useState<IssueSearch>({ q: "", status: "all", from: "", to: "" })
  const [qInput, setQInput] = useState("")
  useEffect(() => {
    const id = setTimeout(() => setFilter((f) => ({ ...f, q: qInput })), 300)
    return () => clearTimeout(id)
  }, [qInput])

  const results = useSearchIssues(orgId, filter)
  const issueIds = useMemo(() => (results.data ?? []).map((i) => i.id), [results.data])
  const tasks = useIssueTasks(orgId, issueIds)
  const tasksByIssue = useMemo(() => {
    const m = new Map<string, NonNullable<typeof tasks.data>>()
    for (const tsk of tasks.data ?? []) m.set(tsk.ref_id, [...(m.get(tsk.ref_id) ?? []), tsk])
    return m
  }, [tasks.data])

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-2.5">
        <div className="relative min-w-56 flex-1">
          <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-text-muted" />
          <Input className="pl-9" value={qInput} onChange={(e) => setQInput(e.target.value)} placeholder={t("huddle.history.searchPlaceholder")} data-testid="huddle-search" />
        </div>
        {(["all", "open", "solved"] as const).map((s) => (
          <button
            key={s}
            type="button"
            onClick={() => setFilter((f) => ({ ...f, status: s }))}
            className={cn("rounded-full border px-3.5 py-1.5 text-sm font-medium", filter.status === s ? "border-ink bg-ink text-white" : "border-border bg-surface text-text-muted")}
          >
            {s === "all" ? t("huddle.history.all") : t(`huddle.status.${s}`)}
          </button>
        ))}
        <div className="w-40">
          <DatePicker value={filter.from} onChange={(v) => setFilter((f) => ({ ...f, from: v }))} aria-label={t("huddle.history.from")} />
        </div>
        <div className="w-40">
          <DatePicker value={filter.to} onChange={(v) => setFilter((f) => ({ ...f, to: v }))} aria-label={t("huddle.history.to")} />
        </div>
      </div>

      {results.isLoading ? (
        <Skeleton className="h-24 w-full" />
      ) : results.isError ? (
        <p className="text-sm text-danger">{t("huddle.loadFailed")}</p>
      ) : (results.data ?? []).length === 0 ? (
        <Card className="items-center py-8 text-sm text-text-muted">{t("huddle.history.empty")}</Card>
      ) : (
        <div className="space-y-2.5">
          {(results.data ?? []).map((issue) => (
            <IssueCard key={issue.id} issue={issue} names={names} tasks={tasksByIssue.get(issue.id) ?? []} />
          ))}
        </div>
      )}
    </div>
  )
}
