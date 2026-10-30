import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { Link } from "react-router-dom"
import { CalendarClock, ClipboardCheck, Inbox, Loader2, TriangleAlert, Wrench } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Skeleton } from "@/components/ui/skeleton"
import { useToast } from "@/components/ui/toast-context"
import { useFollowups, useLeadAssignees, useLeadTechnicianNames, useLeadsWithoutFollowup } from "@/hooks/useLeadFollowups"
import { useProfile } from "@/hooks/useProfile"
import { AssignLeadDialog } from "./AssignLeadDialog"
import { assignActionFor, canScheduleLead } from "@/lib/lead-assign"
import { NoFollowupCard } from "./NoFollowupCard"
import { BulkSetFollowupDialog } from "./BulkSetFollowupDialog"
import { SetFollowupDialog } from "./SetFollowupDialog"
import { useLeadSourceOptions } from "@/hooks/useLeadSources"
import { useLeadKindOptions } from "@/hooks/useLeadLists"
import { FollowupCard } from "./FollowupCard"
import { PostServiceCard } from "./PostServiceCard"
import { PostServiceCallSheet } from "./PostServiceCallSheet"
import { usePostServiceFollowups } from "@/hooks/usePostServiceFollowups"
import { lifecycleFollowupVisible, mergeBuckets, postServiceVisible } from "@/lib/daily-followup-merge"
import type { PostServiceFollowupItem } from "@/services/postServiceFollowups"
import { LogOutcomeSheet } from "./LogOutcomeSheet"
import { RescheduleDialog } from "./RescheduleDialog"
import { formatIstDate, getIstNow } from "@/lib/lead-followups"
import { cn } from "@/lib/utils"
import type { FollowupBucket, FollowupListItem, FollowupScope, LeadWithoutFollowup } from "@/services/leadFollowups"
import type { UserRole } from "@/lib/roles"
import type { Enums } from "@/types/database"
import { useCreateServiceRequest, useLifecycleFollowups, useMarkFollowupContacted, useSnoozeFollowup } from "@/hooks/useLifecycleFollowups"
import type { LifecycleFollowupRow } from "@/services/lifecycleFollowups"

/** The three follow-up buckets plus the leads nobody has scheduled yet. */
type MyDayTab = FollowupBucket | "none"
const TABS: MyDayTab[] = ["overdue", "today", "upcoming", "none"]
const STAGES: Enums<"lead_status">[] = ["new", "contacted", "quoted"]

const selectClass =
  "h-9 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"

/** The shared follow-up list for master + sales_admin: what to call, in order, today. */
export function MyDayPage() {
  const { t, i18n } = useTranslation()
  const { sources, label: sourceLabel } = useLeadSourceOptions()
  const { activeKinds, label: kindLabel } = useLeadKindOptions()
  const [chosenTab, setChosenTab] = useState<MyDayTab | null>(null)
  const [stage, setStage] = useState<Enums<"lead_status"> | "">("")
  const [source, setSource] = useState("")
  const [kind, setKind] = useState("")
  const [stuckOnly, setStuckOnly] = useState(false)
  const { data: profile } = useProfile()
  const role = profile?.role as UserRole | undefined
  const isMaster = role === "master"
  const assignees = useLeadAssignees(profile?.org_id, role).data ?? []
  // auto = master: everything; sales_admin: own + unassigned (resolved by the server too)
  const [scope, setScope] = useState<FollowupScope>("auto")
  const [assignFor, setAssignFor] = useState<{ lead_id: string; lead_name: string; assignee_id: string | null } | null>(null)
  const [scheduleFor, setScheduleFor] = useState<LeadWithoutFollowup | null>(null)
  // master bulk action on the "No follow-up" tab
  const [selectMode, setSelectMode] = useState(false)
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const [bulkOpen, setBulkOpen] = useState(false)

  const [outcomeFor, setOutcomeFor] = useState<FollowupListItem | null>(null)
  const [rescheduleFor, setRescheduleFor] = useState<FollowupListItem | null>(null)
  const [postCallFor, setPostCallFor] = useState<PostServiceFollowupItem | null>(null)

  const list = useFollowups({ bucket: "all", stage: stage || undefined, source: source || undefined, kind: kind || undefined, stuckOnly, scope })

  const none = useLeadsWithoutFollowup({ stage: stage || undefined, source: source || undefined, kind: kind || undefined, scope })
  const noneRows = none.data ?? []

  // Post-service calls (item 13) come from their own function and are merged in by due time. An error there (e.g. the
  // function not deployed yet) just means "no post-service calls" — it must never take the lead list down with it.
  const postService = usePostServiceFollowups(scope, role)
  const showPostService = postServiceVisible({ stage, source, kind, stuckOnly })
  // Product Lifecycle service reminders (W5): a third source merged in the same way, by due time. Same rule as
  // post-service calls — a failed/undeployed RPC here just means "no lifecycle reminders", never a broken page.
  const lifecycle = useLifecycleFollowups(profile?.org_id)
  const showLifecycle = lifecycleFollowupVisible({ stage, source, kind, stuckOnly })
  const byBucket = useMemo(
    () => mergeBuckets(list.data, showPostService ? postService.data : undefined, showLifecycle ? lifecycle.data : undefined),
    [list.data, postService.data, showPostService, lifecycle.data, showLifecycle]
  )

  // nothing due, but leads waiting to be scheduled: land on them so they are never out of sight
  const tab: MyDayTab = chosenTab ?? (byBucket.overdue.length > 0 ? "overdue" : byBucket.today.length > 0 ? "today" : noneRows.length > 0 ? "none" : "today")
  const rows = tab === "none" ? [] : byBucket[tab]
  // Item 3: "Referred by X" / "Technician X" chip on each lead card (names for the leads currently listed).
  const technicianNames = useLeadTechnicianNames((list.data ?? []).map((i) => i.lead_id))
  const selectedIds = noneRows.filter((r) => selected.has(r.lead_id)).map((r) => r.lead_id)
  const schedulable = (r: LeadWithoutFollowup) => canScheduleLead(role, profile?.id, r.assignee_id, assignees)
  const filtersActive = !!(stage || source || kind || stuckOnly || scope !== "auto")

  return (
    <div className="space-y-4 pt-2">
      <div>
        <h1 className="text-2xl font-bold text-text">{t("leads.myDay.title")}</h1>
        <p className="text-sm text-text-muted">{t("leads.myDay.subtitle", { date: formatIstDate(getIstNow().date, i18n.language) })}</p>
      </div>

      <div className="flex flex-wrap items-center gap-2.5">
        <div className="flex gap-[3px] rounded-full border border-border bg-surface p-1" role="tablist">
          {TABS.map((b) => (
            <button
              key={b}
              type="button"
              role="tab"
              aria-selected={tab === b}
              onClick={() => setChosenTab(b)}
              className={cn(
                "flex items-center gap-1.5 rounded-full px-3.5 py-[7px] text-xs font-semibold transition-colors",
                tab === b ? (b === "overdue" ? "bg-danger text-white" : "bg-ink text-white") : b === "overdue" && byBucket.overdue.length > 0 ? "text-danger" : "text-text-muted"
              )}
            >
              {t(`leads.myDay.tab.${b}`)}
              <span className={cn("rounded-full px-1.5 text-[10px] tabular-nums", tab === b ? "bg-white/20" : "bg-surface-alt")} data-testid={`tab-count-${b}`}>
                {b === "none" ? (none.isLoading ? "…" : noneRows.length) : list.isLoading ? "…" : byBucket[b].length}
              </span>
            </button>
          ))}
        </div>

        <select value={stage} onChange={(e) => setStage(e.target.value as Enums<"lead_status"> | "")} className={selectClass} aria-label={t("leads.myDay.filters.stage")}>
          <option value="">{t("leads.myDay.filters.allStages")}</option>
          {STAGES.map((s) => (
            <option key={s} value={s}>
              {t(`leads.status.${s}`)}
            </option>
          ))}
        </select>
        <select value={source} onChange={(e) => setSource(e.target.value)} className={selectClass} aria-label={t("leads.myDay.filters.source")}>
          <option value="">{t("leads.filters.allSources")}</option>
          {sources.map((s) => (
            <option key={s.key} value={s.key}>
              {sourceLabel(s.key)}
            </option>
          ))}
        </select>
        <select value={kind} onChange={(e) => setKind(e.target.value)} className={selectClass} aria-label={t("leads.myDay.filters.kind")}>
          <option value="">{t("leads.filters.allKinds")}</option>
          {activeKinds.map((k) => (
            <option key={k.key} value={k.key}>
              {kindLabel(k.key)}
            </option>
          ))}
        </select>
        <select value={scope} onChange={(e) => setScope(e.target.value as FollowupScope)} className={selectClass} aria-label={t("leads.assign.scopeLabel")} data-testid="scope-select">
          <option value="auto">{t(isMaster ? "leads.assign.scope.all" : "leads.assign.scope.mineUnassigned")}</option>
          <option value="mine">{t("leads.assign.scope.mine")}</option>
          <option value="unassigned">{t("leads.assign.scope.unassigned")}</option>
          {isMaster
            ? assignees
                .filter((a) => a.id !== profile?.id)
                .map((a) => (
                  <option key={a.id} value={`person:${a.id}`}>
                    {a.full_name}
                  </option>
                ))
            : null}
        </select>
        <button
          type="button"
          aria-pressed={stuckOnly}
          onClick={() => setStuckOnly((v) => !v)}
          className={cn("rounded-full border px-3.5 py-2 text-xs font-semibold", stuckOnly ? "border-danger bg-danger text-white" : "border-border bg-surface text-text-muted")}
        >
          {t("leads.myDay.filters.stuckOnly")}
        </button>
        {filtersActive ? (
          <button
            type="button"
            onClick={() => {
              setStage("")
              setSource("")
              setKind("")
              setStuckOnly(false)
              setScope("auto")
            }}
            className="text-xs font-semibold text-text-muted hover:text-text"
          >
            {t("leads.filters.clear")}
          </button>
        ) : null}
      </div>

      {tab === "none" ? (
        <div className="space-y-3" data-testid="no-followup-section">
          <p className="text-xs text-text-muted">{t("leads.noFollowup.intro")}</p>
          {isMaster && noneRows.length > 0 ? (
            <div className="flex flex-wrap items-center gap-2">
              <button
                type="button"
                aria-pressed={selectMode}
                onClick={() => {
                  setSelectMode((v) => !v)
                  setSelected(new Set())
                }}
                className={cn("rounded-full border px-3.5 py-2 text-xs font-semibold", selectMode ? "border-ink bg-ink text-white" : "border-border bg-surface text-text-muted")}
              >
                {t(selectMode ? "leads.assign.selectDone" : "leads.assign.select")}
              </button>
              {selectMode ? (
                <>
                  <button type="button" className="text-xs font-semibold text-text-muted hover:text-text" onClick={() => setSelected(new Set(noneRows.map((r) => r.lead_id)))}>
                    {t("leads.noFollowup.selectAll", { count: noneRows.length })}
                  </button>
                  {selectedIds.length > 0 ? (
                    <Button size="sm" variant="accent" onClick={() => setBulkOpen(true)} data-testid="bulk-open">
                      {t("leads.noFollowup.setSelected", { count: selectedIds.length })}
                    </Button>
                  ) : null}
                </>
              ) : null}
            </div>
          ) : null}
          {none.isError ? (
            <div className="flex flex-col items-center gap-3 rounded-card border border-border bg-surface py-12 text-center">
              <TriangleAlert className="size-6 text-danger" />
              <p className="text-sm text-text-muted">{t("leads.myDay.loadFailed")}</p>
              <Button variant="outline" size="sm" onClick={() => none.refetch()}>
                {t("common.retry")}
              </Button>
            </div>
          ) : none.isLoading ? (
            <div className="space-y-3">
              {Array.from({ length: 3 }).map((_, i) => (
                <Skeleton key={i} className="h-28 w-full rounded-subcard" />
              ))}
            </div>
          ) : noneRows.length === 0 ? (
            <div className="flex flex-col items-center gap-2 rounded-card border border-dashed border-border py-14 text-center">
              <Inbox className="size-6 text-text-muted" />
              <p className="text-sm text-text-muted">{t("leads.myDay.empty.none")}</p>
            </div>
          ) : (
            <div className="grid grid-cols-1 gap-3 xl:grid-cols-2" data-testid="no-followup-list">
              {noneRows.map((r) => (
                <NoFollowupCard
                  key={r.lead_id}
                  item={r}
                  onSetFollowup={schedulable(r) ? setScheduleFor : undefined}
                  onAssign={assignActionFor(role, profile?.id, r.assignee_id, assignees) ? setAssignFor : undefined}
                  selectable={selectMode}
                  selected={selected.has(r.lead_id)}
                  onToggle={(it) =>
                    setSelected((cur) => {
                      const n = new Set(cur)
                      if (n.has(it.lead_id)) n.delete(it.lead_id)
                      else n.add(it.lead_id)
                      return n
                    })
                  }
                />
              ))}
            </div>
          )}
        </div>
      ) : list.isError ? (
        <div className="flex flex-col items-center gap-3 rounded-card border border-border bg-surface py-12 text-center">
          <TriangleAlert className="size-6 text-danger" />
          <p className="text-sm text-text-muted">{t("leads.myDay.loadFailed")}</p>
          <Button variant="outline" size="sm" onClick={() => list.refetch()}>
            {t("common.retry")}
          </Button>
        </div>
      ) : list.isLoading ? (
        <div className="space-y-3">
          {Array.from({ length: 3 }).map((_, i) => (
            <Skeleton key={i} className="h-28 w-full rounded-subcard" />
          ))}
        </div>
      ) : rows.length === 0 ? (
        <div className="flex flex-col items-center gap-2 rounded-card border border-dashed border-border py-14 text-center">
          <Inbox className="size-6 text-text-muted" />
          <p className="text-sm text-text-muted">{t(`leads.myDay.empty.${tab}`)}</p>
        </div>
      ) : (
        <div className="grid grid-cols-1 gap-3 xl:grid-cols-2" data-testid="followup-list">
          {rows.map((r) =>
            r.type === "post" ? (
              <PostServiceCard key={`ps-${r.item.followup_id}`} item={r.item} onLogCall={setPostCallFor} />
            ) : r.type === "lifecycle" ? (
              <LifecycleFollowupCard key={`lf-${r.item.scheduleId}`} item={r.item} orgId={profile?.org_id} />
            ) : (
              <FollowupCard
                key={r.item.followup_id}
                item={r.item}
                technicianName={technicianNames.data?.get(r.item.lead_id) ?? null}
                onLogOutcome={setOutcomeFor}
                onReschedule={setRescheduleFor}
                onAssign={assignActionFor(role, profile?.id, r.item.assignee_id, assignees) ? setAssignFor : undefined}
              />
            )
          )}
        </div>
      )}

      <PostServiceCallSheet item={postCallFor} open={!!postCallFor} onOpenChange={(o) => !o && setPostCallFor(null)} />
      <LogOutcomeSheet
        lead={outcomeFor ? { id: outcomeFor.lead_id, name: outcomeFor.lead_name, mobile: outcomeFor.mobile, status: outcomeFor.lead_status } : null}
        open={!!outcomeFor}
        onOpenChange={(o) => !o && setOutcomeFor(null)}
      />
      <AssignLeadDialog
        leads={assignFor ? [{ id: assignFor.lead_id, name: assignFor.lead_name, assignedTo: assignFor.assignee_id }] : []}
        open={!!assignFor}
        onOpenChange={(o) => !o && setAssignFor(null)}
      />
      <SetFollowupDialog lead={scheduleFor ? { id: scheduleFor.lead_id, name: scheduleFor.lead_name } : null} open={!!scheduleFor} onOpenChange={(o) => !o && setScheduleFor(null)} />
      <BulkSetFollowupDialog
        leadIds={selectedIds}
        open={bulkOpen}
        onOpenChange={setBulkOpen}
        onDone={() => {
          setSelected(new Set())
          setSelectMode(false)
        }}
      />
      <RescheduleDialog lead={rescheduleFor ? { id: rescheduleFor.lead_id, name: rescheduleFor.lead_name } : null} open={!!rescheduleFor} onOpenChange={(o) => !o && setRescheduleFor(null)} />
    </div>
  )
}

/**
 * One Product Lifecycle service reminder in Daily Follow Up (W5): customer, product + part, due/overdue status, and
 * three actions on the schedule itself (Mark contacted, Snooze, Create service request). Sibling of PostServiceCard
 * and FollowupCard — no lead stage/postpone/outcome state applies here, so none of their buttons are reused.
 */
function LifecycleFollowupCard({ item, orgId }: { item: LifecycleFollowupRow; orgId: string | undefined }) {
  const { t, i18n } = useTranslation()
  const { toast } = useToast()
  const [mode, setMode] = useState<"idle" | "contact" | "snooze">("idle")
  const [note, setNote] = useState("")
  const [snoozeDate, setSnoozeDate] = useState("")

  const markContacted = useMarkFollowupContacted(orgId)
  const snooze = useSnoozeFollowup(orgId)
  const createRequest = useCreateServiceRequest(orgId)

  const todayIst = getIstNow().date
  const canSnooze = snoozeDate !== "" && snoozeDate > todayIst

  function reset() {
    setMode("idle")
    setNote("")
    setSnoozeDate("")
  }

  async function saveContacted() {
    try {
      await markContacted.mutateAsync({ scheduleId: item.scheduleId, note: note.trim() || null })
      toast.success(t("lifecycleFollowups.markContactedSaved"))
      reset()
    } catch (e) {
      toast.error(e instanceof Error && e.message ? e.message : t("common.actionFailed"))
    }
  }

  async function saveSnooze() {
    if (!canSnooze) return
    try {
      await snooze.mutateAsync({ scheduleId: item.scheduleId, until: snoozeDate })
      toast.success(t("lifecycleFollowups.snoozeSaved", { date: formatIstDate(snoozeDate, i18n.language) }))
      reset()
    } catch (e) {
      toast.error(e instanceof Error && e.message ? e.message : t("common.actionFailed"))
    }
  }

  async function doCreateServiceRequest() {
    try {
      const ticketId = await createRequest.mutateAsync(item.scheduleId)
      toast.success(t("lifecycleFollowups.serviceRequestCreated", { ticketId }))
    } catch (e) {
      toast.error(e instanceof Error && e.message ? e.message : t("common.actionFailed"))
    }
  }

  return (
    <Card size="sm" className={cn("gap-2.5 px-4", item.status === "overdue" && "border-danger/40")} data-testid="lifecycle-followup-card">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div className="min-w-0 space-y-0.5">
          <Link to={`/admin/customers/${item.customerId}`} className="block truncate text-sm font-semibold text-text hover:underline">
            {item.customerName}
          </Link>
        </div>
        <div className="flex flex-wrap items-center justify-end gap-1.5">
          <span
            className={cn(
              "rounded-full px-2 py-0.5 text-xs font-semibold",
              item.status === "overdue" ? "bg-danger/10 text-danger" : item.status === "due" ? "bg-warning/10 text-warning" : "bg-surface-alt text-text-muted"
            )}
          >
            {t(`lifecycleFollowups.statusLabel.${item.status}`)}
          </span>
        </div>
      </div>

      <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-text-muted">
        <span className="inline-flex items-center gap-1 rounded-full bg-info/10 px-2 py-0.5 font-semibold text-info">
          <Wrench className="size-3" />
          {t("lifecycleFollowups.badge")}
        </span>
        <span className="font-medium text-text">{item.productName}</span>
        <span>{item.label}</span>
        <span className="inline-flex items-center gap-1">
          <CalendarClock className="size-3" />
          {formatIstDate(item.nextDueDate, i18n.language)}
        </span>
      </div>

      {mode === "contact" ? (
        <div className="space-y-2">
          <Input
            value={note}
            onChange={(e) => setNote(e.target.value)}
            placeholder={t("lifecycleFollowups.markContactedNotePlaceholder")}
            maxLength={2000}
          />
          <div className="flex justify-end gap-1.5">
            <Button size="sm" variant="ghost" onClick={reset} disabled={markContacted.isPending}>
              {t("common.cancel")}
            </Button>
            <Button size="sm" variant="accent" onClick={saveContacted} disabled={markContacted.isPending}>
              {markContacted.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("lifecycleFollowups.markContactedSave")}
            </Button>
          </div>
        </div>
      ) : mode === "snooze" ? (
        <div className="space-y-2">
          <label className="flex flex-col gap-1 text-xs text-text-muted">
            {t("lifecycleFollowups.snoozeUntilLabel")}
            <Input type="date" min={todayIst} value={snoozeDate} onChange={(e) => setSnoozeDate(e.target.value)} />
          </label>
          {snoozeDate && !canSnooze ? <p className="text-xs text-danger">{t("lifecycleFollowups.snoozeMustBeFuture")}</p> : null}
          <div className="flex justify-end gap-1.5">
            <Button size="sm" variant="ghost" onClick={reset} disabled={snooze.isPending}>
              {t("common.cancel")}
            </Button>
            <Button size="sm" variant="accent" onClick={saveSnooze} disabled={!canSnooze || snooze.isPending}>
              {snooze.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("lifecycleFollowups.snoozeSave")}
            </Button>
          </div>
        </div>
      ) : (
        <div className="flex flex-wrap gap-1.5">
          <Button size="sm" variant="accent" onClick={() => setMode("contact")}>
            <ClipboardCheck className="size-3.5" />
            {t("lifecycleFollowups.markContacted")}
          </Button>
          <Button size="sm" variant="ghost" onClick={() => setMode("snooze")}>
            {t("lifecycleFollowups.snooze")}
          </Button>
          <Button size="sm" variant="ghost" onClick={doCreateServiceRequest} disabled={createRequest.isPending}>
            {createRequest.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("lifecycleFollowups.createServiceRequest")}
          </Button>
        </div>
      )}
    </Card>
  )
}
