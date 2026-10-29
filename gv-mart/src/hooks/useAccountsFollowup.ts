import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as accountsFollowup from "@/services/accountsFollowup"
import { classifyReminderBucket } from "@/services/reportMappers"
import { toLocalDateString } from "@/lib/local-date"

export function useCustomerOutstandingList(cursor: string | null) {
  return useQuery({
    queryKey: ["accounts", "outstanding", "list", cursor],
    queryFn: () => accountsFollowup.listCustomerOutstanding(cursor, 50),
  })
}

export function useCustomerOutstandingDetail(customerId: string | undefined) {
  return useQuery({
    queryKey: ["accounts", "outstanding", "detail", customerId],
    queryFn: () => accountsFollowup.getCustomerOutstandingDetail(customerId!),
    enabled: !!customerId,
  })
}

function invalidateOutstanding(qc: ReturnType<typeof useQueryClient>, customerId?: string) {
  qc.invalidateQueries({ queryKey: ["accounts", "outstanding"] })
  qc.invalidateQueries({ queryKey: ["tasks"] })
  if (customerId) qc.invalidateQueries({ queryKey: ["accounts", "outstanding", "detail", customerId] })
}

export function useCreateOutstandingReminder() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: accountsFollowup.createOutstandingReminder,
    onSuccess: (_d, vars) => invalidateOutstanding(qc, vars.customerId),
  })
}

export function useRescheduleOutstandingReminder() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: { id: string; dueAt: string; note?: string | null }) =>
      accountsFollowup.rescheduleOutstandingReminder(input.id, input.dueAt, input.note),
    onSuccess: () => invalidateOutstanding(qc),
  })
}

export function useCloseOutstandingReminder() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (id: string) => accountsFollowup.closeOutstandingReminder(id),
    onSuccess: () => invalidateOutstanding(qc),
  })
}

export function useCancelOutstandingReminder() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: { id: string; reason?: string | null }) => accountsFollowup.cancelOutstandingReminder(input.id, input.reason),
    onSuccess: () => invalidateOutstanding(qc),
  })
}

export function useCreateOutstandingTask() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: accountsFollowup.createOutstandingTask,
    onSuccess: (_d, vars) => invalidateOutstanding(qc, vars.customerId),
  })
}

/** Opportunistic, read-triggered reconciliation — fired when the detail view loads. Silent no-op for anyone but master. */
export function useReconcileOutstandingOnLoad(customerId: string | undefined) {
  const qc = useQueryClient()
  useQuery({
    queryKey: ["accounts", "outstanding", "reconcile", customerId],
    queryFn: async () => {
      await accountsFollowup.closeOutstandingRemindersIfZero(customerId!)
      qc.invalidateQueries({ queryKey: ["accounts", "outstanding", "detail", customerId] })
      return true
    },
    enabled: !!customerId,
    staleTime: 60_000,
  })
}

/** Reminder-management batch, item 2 — the bulk reconciliation sweep, fired
 * whenever the Customer Outstanding list or the Reminders view loads (not
 * only one customer's own dialog). Silent no-op for anyone but master. */
export function useReconcileAllOutstandingOnLoad() {
  const qc = useQueryClient()
  useQuery({
    queryKey: ["accounts", "outstanding", "reconcileAll"],
    queryFn: async () => {
      await accountsFollowup.closeOutstandingRemindersIfZeroBulk()
      qc.invalidateQueries({ queryKey: ["accounts", "outstanding"] })
      return true
    },
    staleTime: 60_000,
  })
}

export function useOutstandingReminders() {
  return useQuery({
    queryKey: ["accounts", "outstanding", "reminders"],
    queryFn: accountsFollowup.listOutstandingReminders,
  })
}

/** Reminder-management batch, item 1 -- the overdue+due-today count badge
 * shown on the Accounts entry/Customer Outstanding button, so master sees
 * it without opening anything. */
export function useOverdueOrDueTodayReminderCount() {
  const { data: reminders } = useOutstandingReminders()
  const today = toLocalDateString(new Date())
  if (!reminders) return 0
  return reminders.filter((r) => {
    const bucket = classifyReminderBucket(r.status, toLocalDateString(new Date(r.due_at)), today)
    return bucket === "overdue" || bucket === "dueToday"
  }).length
}

export function useExpenseCategories(orgId: string | undefined) {
  return useQuery({
    queryKey: ["accounts", "expenseCategories", orgId],
    queryFn: () => accountsFollowup.listExpenseCategories(orgId!),
    enabled: !!orgId,
  })
}

export function useCreateExpenseCategory() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: accountsFollowup.createExpenseCategory,
    onSuccess: () => qc.invalidateQueries({ queryKey: ["accounts", "expenseCategories"] }),
  })
}

export function useRenameExpenseCategory() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: { id: string; name: string }) => accountsFollowup.renameExpenseCategory(input.id, input.name),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["accounts", "expenseCategories"] }),
  })
}

export function useDeactivateExpenseCategory() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (id: string) => accountsFollowup.deactivateExpenseCategory(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["accounts", "expenseCategories"] }),
  })
}

export function useDeleteExpenseCategory() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (id: string) => accountsFollowup.deleteExpenseCategory(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["accounts", "expenseCategories"] }),
  })
}
