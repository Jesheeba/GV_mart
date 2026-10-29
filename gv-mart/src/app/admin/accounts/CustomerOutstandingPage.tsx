import { useState } from "react"
import { useNavigate } from "react-router-dom"
import { useTranslation } from "react-i18next"
import { Loader2, Plus } from "lucide-react"
import { useProfile } from "@/hooks/useProfile"
import { useAssignableProfiles } from "@/hooks/useTasks"
import {
  useCustomerOutstandingList,
  useCreateOutstandingReminder,
  useCreateOutstandingTask,
  useReconcileOutstandingOnLoad,
  useReconcileAllOutstandingOnLoad,
  useOutstandingReminders,
  useCloseOutstandingReminder,
  useCancelOutstandingReminder,
  useRescheduleOutstandingReminder,
} from "@/hooks/useAccountsFollowup"
import { classifyReminderBucket, type ReminderBucket } from "@/services/reportMappers"
import { formatCurrency } from "@/lib/sale-calc"
import { toLocalDateString } from "@/lib/local-date"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Skeleton } from "@/components/ui/skeleton"
import { DatePicker } from "@/components/ui/date-picker"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"

/** Customer Outstanding, master-only (same gate as the rest of /accounts —
 * nothing under Accounts is open to operation_admin/sales_admin today).
 * No such page existed before this; see plan.md / DECISIONS.md. */
export function CustomerOutstandingPage() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const [cursor] = useState<string | null>(null)
  const { data: rows, isLoading, isError, refetch } = useCustomerOutstandingList(cursor)
  const [actionFor, setActionFor] = useState<{ customerId: string; customerName: string; amount: number } | null>(null)
  // Item 2: the bulk sweep runs whenever this page loads, not only when one
  // customer's own Follow up dialog opens.
  useReconcileAllOutstandingOnLoad()

  if (profile && profile.role !== "master") {
    return <p className="text-sm text-text-muted">{t("accounts.masterOnlyNote")}</p>
  }

  return (
    <div className="space-y-4 pt-2">
      <div>
        <h1 className="text-2xl font-bold text-text">{t("accounts.outstanding.title")}</h1>
        <p className="text-sm text-text-muted">{t("accounts.outstanding.subtitle")}</p>
      </div>

      <Tabs defaultValue="outstanding">
        <TabsList>
          <TabsTrigger value="outstanding">{t("accounts.outstanding.tabOutstanding")}</TabsTrigger>
          <TabsTrigger value="reminders">{t("accounts.outstanding.tabReminders")}</TabsTrigger>
        </TabsList>
        <TabsContent value="outstanding" className="mt-3">
          <OutstandingListTab rows={rows} isLoading={isLoading} isError={isError} refetch={refetch} setActionFor={setActionFor} />
        </TabsContent>
        <TabsContent value="reminders" className="mt-3">
          <RemindersTab />
        </TabsContent>
      </Tabs>

      {actionFor ? (
        <CreateFollowUpDialog
          orgId={profile?.org_id}
          customerId={actionFor.customerId}
          customerName={actionFor.customerName}
          amount={actionFor.amount}
          onClose={() => setActionFor(null)}
        />
      ) : null}
    </div>
  )
}

function OutstandingListTab({
  rows,
  isLoading,
  isError,
  refetch,
  setActionFor,
}: {
  rows: ReturnType<typeof useCustomerOutstandingList>["data"]
  isLoading: boolean
  isError: boolean
  refetch: () => void
  setActionFor: (v: { customerId: string; customerName: string; amount: number } | null) => void
}) {
  const { t } = useTranslation()
  return (
    <>
      <div className="rounded-card border border-border bg-surface p-6 shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
        {isError ? (
          <p className="text-sm text-danger">
            {t("reports.loadFailed")}{" "}
            <button type="button" className="underline" onClick={() => refetch()}>
              {t("common.retry")}
            </button>
          </p>
        ) : isLoading ? (
          <div className="space-y-2">
            {Array.from({ length: 5 }).map((_, i) => (
              <Skeleton key={i} className="h-10 w-full" />
            ))}
          </div>
        ) : !rows || rows.length === 0 ? (
          <p className="text-sm text-text-muted">{t("accounts.outstanding.none")}</p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-border text-left text-xs font-semibold text-text-muted">
                  <th className="py-2 pr-3">{t("accounts.outstanding.customer")}</th>
                  <th className="py-2 pr-3 text-right">{t("accounts.outstanding.amount")}</th>
                  <th className="py-2 pr-3">{t("accounts.outstanding.oldestInvoice")}</th>
                  <th className="py-2 pr-3">{t("accounts.outstanding.reminders")}</th>
                  <th className="py-2 pr-3">{t("accounts.outstanding.tasks")}</th>
                  <th className="py-2 pr-0" />
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => (
                  <tr key={r.customer_id} className="border-b border-[#F1EDE6]">
                    <td className="py-2 pr-3 font-medium text-text">{r.customer_name}</td>
                    <td className="py-2 pr-3 text-right font-bold tabular-nums text-text">{formatCurrency(r.outstanding_amount)}</td>
                    <td className="py-2 pr-3 text-text-muted">{r.oldest_invoice_date ?? "—"}</td>
                    <td className="py-2 pr-3 text-text-muted">
                      {r.open_reminder_count > 0
                        ? t("accounts.outstanding.remindersCount", { count: r.open_reminder_count, date: r.next_reminder_at ? toLocalDateString(new Date(r.next_reminder_at)) : "—" })
                        : "—"}
                    </td>
                    <td className="py-2 pr-3 text-text-muted">
                      {r.open_task_count > 0
                        ? t("accounts.outstanding.tasksCount", { count: r.open_task_count, assignee: r.task_assignee_name ?? "—" })
                        : "—"}
                    </td>
                    <td className="py-2 pr-0 text-right">
                      <Button
                        size="sm"
                        variant="ghost"
                        onClick={() => setActionFor({ customerId: r.customer_id, customerName: r.customer_name, amount: r.outstanding_amount })}
                      >
                        <Plus className="size-3.5" />
                        {t("accounts.outstanding.followUp")}
                      </Button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </>
  )
}

function CreateFollowUpDialog({
  orgId,
  customerId,
  customerName,
  amount,
  onClose,
}: {
  orgId: string | undefined
  customerId: string
  customerName: string
  amount: number
  onClose: () => void
}) {
  const { t } = useTranslation()
  const { data: assignableProfiles } = useAssignableProfiles(orgId)
  const createReminder = useCreateOutstandingReminder()
  const createTask = useCreateOutstandingTask()
  // Reconcile this customer's outstanding opportunistically whenever this dialog opens on them.
  useReconcileOutstandingOnLoad(customerId)

  const suggestedDue = toLocalDateString(new Date(Date.now() + 3 * 86400000))
  const [mode, setMode] = useState<"reminder" | "task">("reminder")
  const [dueDate, setDueDate] = useState(suggestedDue)
  const [note, setNote] = useState("")
  const [assigneeId, setAssigneeId] = useState(assignableProfiles?.[0]?.id ?? "")

  const pending = createReminder.isPending || createTask.isPending

  function handleSubmit() {
    if (mode === "reminder") {
      createReminder.mutate(
        { customerId, dueAt: new Date(`${dueDate}T09:00:00`).toISOString(), note: note || null, amount },
        { onSuccess: onClose }
      )
    } else {
      createTask.mutate(
        { customerId, assigneeId: assigneeId || null, title: t("accounts.outstanding.taskTitle", { name: customerName }), dueDate, amount },
        { onSuccess: onClose }
      )
    }
  }

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent>
        <DialogTitle>{t("accounts.outstanding.followUpFor", { name: customerName })}</DialogTitle>
        <DialogDescription>{t("accounts.outstanding.followUpHint", { amount: formatCurrency(amount) })}</DialogDescription>

        <div className="flex gap-2">
          <Button size="sm" variant={mode === "reminder" ? "default" : "outline"} onClick={() => setMode("reminder")}>
            {t("accounts.outstanding.reminder")}
          </Button>
          <Button size="sm" variant={mode === "task" ? "default" : "outline"} onClick={() => setMode("task")}>
            {t("accounts.outstanding.task")}
          </Button>
        </div>

        <div className="space-y-1.5">
          <Label htmlFor="followup-due-date">{t("accounts.outstanding.dueDate")}</Label>
          <DatePicker id="followup-due-date" value={dueDate} onChange={setDueDate} />
        </div>

        {mode === "reminder" ? (
          <div className="space-y-1.5">
            <Label htmlFor="followup-note">{t("accounts.note")}</Label>
            <Input id="followup-note" value={note} onChange={(e) => setNote(e.target.value)} />
          </div>
        ) : (
          <div className="space-y-1.5">
            <Label htmlFor="followup-assignee">{t("accounts.outstanding.assignee")}</Label>
            <select
              id="followup-assignee"
              value={assigneeId}
              onChange={(e) => setAssigneeId(e.target.value)}
              className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
            >
              <option value="">{t("accounts.outstanding.noAssignee")}</option>
              {(assignableProfiles ?? []).map((p) => (
                <option key={p.id} value={p.id}>
                  {p.full_name}
                </option>
              ))}
            </select>
          </div>
        )}

        {(createReminder.error || createTask.error) && (
          <p className="rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">
            {((createReminder.error ?? createTask.error) as Error).message}
          </p>
        )}

        <div className="flex justify-end gap-2">
          <Button variant="ghost" onClick={onClose}>
            {t("common.cancel")}
          </Button>
          <Button onClick={handleSubmit} disabled={pending}>
            {pending ? <Loader2 className="size-4 animate-spin" /> : t("common.save")}
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  )
}

const REMINDER_FILTERS: ReminderBucket[] = ["dueToday", "overdue", "upcoming", "doneOrCancelled"]

/** Reminder-management batch, item 1 -- every reminder (any status), with
 * Due today / Overdue / Upcoming / Done/Cancelled filters, each row linking
 * to its customer's outstanding row, with mark done / cancel / edit due
 * date + note. All three write actions reuse the RPCs the original feature
 * already shipped (close/cancel/reschedule_customer_outstanding_reminder) --
 * only the listing itself (a plain master-only RLS read) is new. */
function RemindersTab() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { data: reminders, isLoading, isError, refetch } = useOutstandingReminders()
  const [filter, setFilter] = useState<ReminderBucket>("dueToday")
  const today = toLocalDateString(new Date())

  const bucketed = (reminders ?? []).filter((r) => classifyReminderBucket(r.status, toLocalDateString(new Date(r.due_at)), today) === filter)

  return (
    <div className="rounded-card border border-border bg-surface p-6 shadow-[0_1px_2px_rgba(26,26,26,.04),0_14px_30px_-22px_rgba(26,26,26,.16)]">
      <div className="mb-4 flex flex-wrap gap-2">
        {REMINDER_FILTERS.map((f) => (
          <Button key={f} size="sm" variant={filter === f ? "default" : "outline"} onClick={() => setFilter(f)}>
            {t(`accounts.outstanding.reminderFilter.${f}`)}
          </Button>
        ))}
      </div>

      {isError ? (
        <p className="text-sm text-danger">
          {t("reports.loadFailed")}{" "}
          <button type="button" className="underline" onClick={() => refetch()}>
            {t("common.retry")}
          </button>
        </p>
      ) : isLoading ? (
        <div className="space-y-2">
          {Array.from({ length: 4 }).map((_, i) => (
            <Skeleton key={i} className="h-10 w-full" />
          ))}
        </div>
      ) : bucketed.length === 0 ? (
        <p className="text-sm text-text-muted">{t("accounts.outstanding.noReminders")}</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-border text-left text-xs font-semibold text-text-muted">
                <th className="py-2 pr-3">{t("accounts.outstanding.customer")}</th>
                <th className="py-2 pr-3">{t("accounts.outstanding.dueDate")}</th>
                <th className="py-2 pr-3">{t("accounts.note")}</th>
                <th className="py-2 pr-3">{t("accounts.outstanding.status")}</th>
                <th className="py-2 pr-0" />
              </tr>
            </thead>
            <tbody>
              {bucketed.map((r) => (
                <ReminderRow key={r.id} reminder={r} onOpenCustomer={() => navigate(`/admin/customers/${r.customer_id}`)} />
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}

function ReminderRow({ reminder, onOpenCustomer }: { reminder: ReturnType<typeof useOutstandingReminders>["data"] extends (infer R)[] | undefined ? R : never; onOpenCustomer: () => void }) {
  const { t } = useTranslation()
  const closeReminder = useCloseOutstandingReminder()
  const cancelReminder = useCancelOutstandingReminder()
  const rescheduleReminder = useRescheduleOutstandingReminder()
  const [editing, setEditing] = useState(false)
  const [dueDate, setDueDate] = useState(toLocalDateString(new Date(reminder.due_at)))
  const [note, setNote] = useState(reminder.note ?? "")

  const pending = closeReminder.isPending || cancelReminder.isPending || rescheduleReminder.isPending

  function handleSaveEdit() {
    rescheduleReminder.mutate(
      { id: reminder.id, dueAt: new Date(`${dueDate}T09:00:00`).toISOString(), note: note || null },
      { onSuccess: () => setEditing(false) }
    )
  }

  return (
    <tr className="border-b border-[#F1EDE6]">
      <td className="py-2 pr-3 font-medium text-text">
        <button type="button" className="underline" onClick={onOpenCustomer}>
          {reminder.customer_name}
        </button>
      </td>
      <td className="py-2 pr-3 text-text-muted">
        {editing ? <DatePicker id={`reminder-due-${reminder.id}`} value={dueDate} onChange={setDueDate} /> : toLocalDateString(new Date(reminder.due_at))}
      </td>
      <td className="py-2 pr-3 text-text-muted">
        {editing ? <Input value={note} onChange={(e) => setNote(e.target.value)} /> : reminder.note ?? "—"}
      </td>
      <td className="py-2 pr-3 text-text-muted">
        {reminder.status === "open" ? t("accounts.outstanding.statusOpen") : reminder.status === "done" ? t("accounts.outstanding.statusDone") : t("accounts.outstanding.statusCancelled")}
        {reminder.status !== "open" && reminder.close_reason ? <span className="ml-1 text-xs">({reminder.close_reason})</span> : null}
      </td>
      <td className="py-2 pr-0 text-right">
        {reminder.status === "open" ? (
          editing ? (
            <div className="flex justify-end gap-1">
              <Button size="sm" variant="ghost" onClick={handleSaveEdit} disabled={pending}>
                {t("common.save")}
              </Button>
              <Button size="sm" variant="ghost" onClick={() => setEditing(false)}>
                {t("common.cancel")}
              </Button>
            </div>
          ) : (
            <div className="flex justify-end gap-1">
              <Button size="sm" variant="ghost" onClick={() => setEditing(true)} disabled={pending}>
                {t("common.edit")}
              </Button>
              <Button size="sm" variant="ghost" onClick={() => closeReminder.mutate(reminder.id)} disabled={pending}>
                {t("accounts.outstanding.markDone")}
              </Button>
              <Button size="sm" variant="ghost" onClick={() => cancelReminder.mutate({ id: reminder.id })} disabled={pending}>
                {t("common.cancel")}
              </Button>
            </div>
          )
        ) : null}
      </td>
    </tr>
  )
}
