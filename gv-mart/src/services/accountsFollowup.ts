import { supabase } from "@/lib/supabase"

/** Customer Outstanding <-> Reminders/Tasks (Feature B) and owner-managed
 * expense categories (Feature A). database.ts was not regenerated (no
 * Docker on this machine, same constraint as every other hand-patched
 * migration here) -- these new tables/RPCs are typed by hand below rather
 * than through the generated Tables<>/Enums<> helpers. */

export type CustomerOutstandingRow = {
  customer_id: string
  customer_name: string
  outstanding_amount: number
  oldest_invoice_date: string | null
  open_reminder_count: number
  next_reminder_at: string | null
  open_task_count: number
  task_assignee_name: string | null
  task_status: string | null
}

export type CustomerOutstandingDetail = {
  customer_id: string
  customer_name: string
  outstanding_amount: number
  oldest_invoice_date: string | null
  open_reminder_count: number
  next_reminder_at: string | null
  open_task_count: number
}

export async function listCustomerOutstanding(cursor: string | null, limit = 50) {
  const { data, error } = await supabase.rpc("report_customer_outstanding", { p_cursor: cursor, p_limit: limit })
  if (error) throw error
  return (data ?? []) as CustomerOutstandingRow[]
}

export async function getCustomerOutstandingDetail(customerId: string) {
  const { data, error } = await supabase.rpc("report_customer_outstanding_detail", { p_customer: customerId })
  if (error) throw error
  const row = (data ?? [])[0] as CustomerOutstandingDetail | undefined
  return row ?? null
}

export async function createOutstandingReminder(input: {
  customerId: string
  dueAt: string
  note?: string | null
  invoiceId?: string | null
  amount: number
}) {
  const { data, error } = await supabase.rpc("create_customer_outstanding_reminder", {
    p_customer: input.customerId,
    p_due_at: input.dueAt,
    p_note: input.note ?? null,
    p_invoice: input.invoiceId ?? null,
    p_amount: input.amount,
  })
  if (error) throw error
  return data
}

export async function rescheduleOutstandingReminder(id: string, dueAt: string, note?: string | null) {
  const { data, error } = await supabase.rpc("reschedule_customer_outstanding_reminder", {
    p_reminder: id,
    p_due_at: dueAt,
    p_note: note ?? null,
  })
  if (error) throw error
  return data
}

export async function closeOutstandingReminder(id: string) {
  const { data, error } = await supabase.rpc("close_customer_outstanding_reminder", { p_reminder: id })
  if (error) throw error
  return data
}

export async function cancelOutstandingReminder(id: string, reason?: string | null) {
  const { data, error } = await supabase.rpc("cancel_customer_outstanding_reminder", { p_reminder: id, p_reason: reason ?? null })
  if (error) throw error
  return data
}

export async function createOutstandingTask(input: {
  customerId: string
  assigneeId: string | null
  title: string
  dueDate: string
  invoiceId?: string | null
  amount: number
}) {
  const { data, error } = await supabase.rpc("create_customer_outstanding_task", {
    p_customer: input.customerId,
    p_assignee: input.assigneeId,
    p_title: input.title,
    p_due_date: input.dueDate,
    p_invoice: input.invoiceId ?? null,
    p_amount: input.amount,
  })
  if (error) throw error
  return data
}

/** Best-effort, read-triggered reconciliation (owner's condition 2: never a
 * trigger on a money table). Called when the Customer Outstanding detail
 * view loads; silently a no-op for anyone but master. */
export async function closeOutstandingRemindersIfZero(customerId: string) {
  const { error } = await supabase.rpc("close_outstanding_reminders_if_zero", { p_customer: customerId })
  if (error) {
    // not master, or nothing to close -- never surface this as a user-facing error
    return 0
  }
}

export type ExpenseCategoryRow = {
  id: string
  org_id: string
  name: string
  is_system: boolean
  enum_value: string | null
  is_active: boolean
  created_at: string
  updated_at: string
}

export async function listExpenseCategories(orgId: string) {
  const { data, error } = await supabase
    .from("expense_categories")
    .select("*")
    .eq("org_id", orgId)
    .order("is_system", { ascending: false })
    .order("name", { ascending: true })
  if (error) throw error
  return (data ?? []) as ExpenseCategoryRow[]
}

export async function createExpenseCategory(name: string) {
  const { data, error } = await supabase.rpc("create_expense_category", { p_name: name })
  if (error) throw error
  return data as ExpenseCategoryRow
}

export async function renameExpenseCategory(id: string, name: string) {
  const { data, error } = await supabase.rpc("rename_expense_category", { p_id: id, p_name: name })
  if (error) throw error
  return data as ExpenseCategoryRow
}

export async function deactivateExpenseCategory(id: string) {
  const { data, error } = await supabase.rpc("deactivate_expense_category", { p_id: id })
  if (error) throw error
  return data as ExpenseCategoryRow
}

export async function deleteExpenseCategory(id: string) {
  const { error } = await supabase.rpc("delete_expense_category", { p_id: id })
  if (error) throw error
}
