import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2, Repeat, Wallet } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { useProfile } from "@/hooks/useProfile"
import { useNonTechnicianStaff } from "@/hooks/useHr"
import { useCreateExpense, useSalarySpendByStaff } from "@/hooks/useReports"
import { useAssignableProfiles, useAssignTask, useOrgTasks } from "@/hooks/useTasks"
import { formatCurrency } from "@/lib/sale-calc"
import { useToast } from "@/components/ui/toast-context"
import type { StaffOption } from "@/services/hr"

function currentMonthIso() {
  return new Date().toISOString().slice(0, 7)
}

function monthToRange(month: string) {
  const [y, m] = month.split("-").map(Number)
  return { from: `${month}-01`, to: new Date(y, m, 0).toISOString().slice(0, 10) }
}

const SALARY_TASK_PREFIX = "Process salary — "

/** Staff Salary — item 1 of the 2026-09-24 Accounts change request. Covers
 * master/operation_admin/sales_admin, who have no `technicians` row and so
 * never go through compute_salary(). No calculation, no default/repeated
 * amount — master types the actual amount paid, every time, same discipline
 * requested for this feature. Writes to the same `expenses` table
 * (category='salary', staff_id) that SalaryTab's "Log to Accounts" uses, so
 * technician and non-technician salaries land in one combined ledger. */
export function StaffSalaryTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id
  const { toast } = useToast()
  const [month, setMonth] = useState(currentMonthIso())
  const range = monthToRange(month)

  const { data: staff, isLoading, isError, refetch } = useNonTechnicianStaff(orgId)
  const { data: staffSalaryTotals } = useSalarySpendByStaff(orgId, range)
  const totalsByStaffId = new Map((staffSalaryTotals ?? []).map((s) => [s.staffId, s.total]))
  const createExpense = useCreateExpense()
  const [amounts, setAmounts] = useState<Record<string, string>>({})
  const [loggingId, setLoggingId] = useState<string | null>(null)

  function logSalary(person: StaffOption) {
    const raw = amounts[person.id]
    const amount = Number(raw)
    if (!orgId || !raw || !(amount > 0)) return
    setLoggingId(person.id)
    createExpense.mutate(
      {
        orgId,
        category: "salary",
        amount,
        date: new Date().toISOString().slice(0, 10),
        note: `Salary — ${month}`,
        staffId: person.id,
        loggedBy: profile?.id ?? null,
      },
      {
        onSuccess: () => setAmounts((prev) => ({ ...prev, [person.id]: "" })),
        onSettled: () => setLoggingId(null),
      }
    )
  }

  // Monthly salary reminders (recurring Task, reusing the existing
  // is_recurring/advance_recurring_tasks mechanism — no new schema). Bulk
  // action covers EVERY staff member (technician + non-technician) so no
  // one is the one salary that gets forgotten.
  const { data: assignableProfiles } = useAssignableProfiles(orgId)
  const { data: orgTasks } = useOrgTasks(orgId)
  const assignTask = useAssignTask()
  const [settingUpReminders, setSettingUpReminders] = useState(false)

  async function setupReminders() {
    if (!orgId || !profile || !assignableProfiles) return
    const covered = new Set(
      (orgTasks ?? []).filter((tsk) => tsk.is_recurring && tsk.title.startsWith(SALARY_TASK_PREFIX)).map((tsk) => tsk.title.slice(SALARY_TASK_PREFIX.length))
    )
    const missing = assignableProfiles.filter((p) => !covered.has(p.full_name))
    if (missing.length === 0) {
      toast.success(t("hr.staffSalary.remindersAlreadySetUp"))
      return
    }
    setSettingUpReminders(true)
    const now = new Date()
    const nextMonth1st = new Date(now.getFullYear(), now.getMonth() + 1, 1).toISOString().slice(0, 10)
    try {
      for (const person of missing) {
        await assignTask.mutateAsync({
          orgId,
          assignedBy: profile.id,
          assigneeId: profile.id,
          title: `${SALARY_TASK_PREFIX}${person.full_name}`,
          description: null,
          priority: "normal",
          dueDate: nextMonth1st,
          dueAt: null,
          isRecurring: true,
        })
      }
      toast.success(t("hr.staffSalary.remindersSetUp", { count: missing.length }))
    } finally {
      setSettingUpReminders(false)
    }
  }

  const columns: DataTableColumn<StaffOption>[] = [
    { key: "name", header: t("hr.staffSalary.staff"), render: (r) => r.full_name },
    { key: "role", header: t("hr.staffSalary.role"), render: (r) => t(`roles.${r.role}`, r.role) },
    {
      key: "status",
      header: "",
      render: (r) => {
        const total = totalsByStaffId.get(r.id)
        return total ? (
          <span className="text-xs font-semibold text-success">{t("hr.staffSalary.logged", { amount: formatCurrency(total) })}</span>
        ) : (
          <span className="text-xs text-text-muted">{t("hr.staffSalary.notLoggedYet")}</span>
        )
      },
    },
    {
      key: "__actions",
      header: "",
      className: "text-right",
      render: (r) => (
        <div className="flex items-center justify-end gap-2">
          <Input
            type="number"
            min={0}
            step="0.01"
            placeholder={t("hr.staffSalary.amount")}
            value={amounts[r.id] ?? ""}
            onChange={(e) => setAmounts((prev) => ({ ...prev, [r.id]: e.target.value }))}
            className="h-9 w-32"
          />
          <Button size="xs" variant="accent" onClick={() => logSalary(r)} disabled={!amounts[r.id] || Number(amounts[r.id]) <= 0 || loggingId === r.id}>
            {loggingId === r.id ? <Loader2 className="size-3 animate-spin" /> : <Wallet className="size-3" />}
            {t("hr.staffSalary.logSalary")}
          </Button>
        </div>
      ),
    },
  ]

  return (
    <div className="space-y-4">
      <p className="text-xs text-text-muted">{t("hr.staffSalary.subtitle")}</p>

      <div className="flex flex-wrap items-end justify-between gap-3">
        <div className="space-y-1">
          <Label htmlFor="staff-salary-month" className="block text-xs font-medium text-text-muted">
            {t("hr.staffSalary.month")}
          </Label>
          <Input id="staff-salary-month" type="month" value={month} onChange={(e) => setMonth(e.target.value)} className="h-9 max-w-44 border-border" />
        </div>
        <Button variant="outline" onClick={setupReminders} disabled={settingUpReminders || !assignableProfiles}>
          {settingUpReminders ? <Loader2 className="size-3.5 animate-spin" /> : <Repeat className="size-3.5" />}
          {t("hr.staffSalary.setupReminders")}
        </Button>
      </div>

      <DataTable
        columns={columns}
        rows={staff ?? []}
        rowKey={(r) => r.id}
        loading={isLoading}
        error={isError ? t("hr.salary.loadFailed") : null}
        onRetry={() => refetch()}
        emptyMessage={t("hr.staffSalary.empty")}
      />
    </div>
  )
}
