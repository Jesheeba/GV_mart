import { useState } from "react"
import { getIstNow } from "@/lib/ist"
import { toLocalDateString } from "@/lib/local-date"
import { useTranslation } from "react-i18next"
import { KeyRound, Loader2, Repeat, Wallet } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { useProfile } from "@/hooks/useProfile"
import { useNonTechnicianStaff, useResetStaffPassword, useSetStaffRoleKey } from "@/hooks/useHr"
import { roleBaseSalariesHooks } from "@/hooks/useMasters"
import { useCreateExpense, useSalarySpendByStaff } from "@/hooks/useReports"
import { useAssignableProfiles, useAssignTask, useOrgTasks } from "@/hooks/useTasks"
import { formatCurrency } from "@/lib/sale-calc"
import { useToast } from "@/components/ui/toast-context"
import type { StaffOption } from "@/services/hr"
import { PasswordRevealDialog } from "@/app/admin/technicians/PasswordRevealDialog"

function currentMonthIso() {
  return getIstNow().date.slice(0, 7)
}

function monthToRange(month: string) {
  const [y, m] = month.split("-").map(Number)
  return { from: `${month}-01`, to: toLocalDateString(new Date(y, m, 0)) }
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
  // Role base salaries (Masters > Role Salaries). Pre-fills the amount for a
  // staff member linked via profiles.staff_role_key; master can still override.
  const { data: roleSalaries } = roleBaseSalariesHooks.useList(orgId)
  const setRoleKey = useSetStaffRoleKey()
  const resetPassword = useResetStaffPassword()
  const [revealedPassword, setRevealedPassword] = useState<string | null>(null)
  const [resettingId, setResettingId] = useState<string | null>(null)

  function resetStaffLogin(person: StaffOption) {
    if (!window.confirm(t("hr.staffSalary.resetPasswordConfirm", { name: person.full_name }))) return
    setResettingId(person.id)
    resetPassword.mutate(person.id, {
      onSuccess: (res) => setRevealedPassword(res.password),
      onError: (e) => toast.error(e instanceof Error ? e.message : t("hr.staffSalary.resetPasswordFailed")),
      onSettled: () => setResettingId(null),
    })
  }
  const baseByRoleKey = new Map((roleSalaries ?? []).filter((r) => r.is_active).map((r) => [r.role_key, r.monthly_base]))
  const [amounts, setAmounts] = useState<Record<string, string>>({})
  const [loggingId, setLoggingId] = useState<string | null>(null)

  /** What the input shows/logs: the typed value if any, else the mapped role base (when > 0). */
  function effectiveAmount(person: StaffOption): string {
    const typed = amounts[person.id]
    if (typed !== undefined) return typed
    const base = person.staff_role_key ? baseByRoleKey.get(person.staff_role_key) : undefined
    return base && base > 0 ? String(base) : ""
  }

  function logSalary(person: StaffOption) {
    const raw = effectiveAmount(person)
    const amount = Number(raw)
    if (!orgId || !raw || !(amount > 0)) return
    setLoggingId(person.id)
    createExpense.mutate(
      {
        orgId,
        category: "salary",
        amount,
        date: getIstNow().date,
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
    const nextMonth1st = toLocalDateString(new Date(now.getFullYear(), now.getMonth() + 1, 1))
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
      key: "salaryRole",
      header: t("hr.staffSalary.salaryRole"),
      render: (r) => (
        <select
          aria-label={t("hr.staffSalary.salaryRole")}
          value={r.staff_role_key ?? ""}
          onChange={(e) => setRoleKey.mutate({ profileId: r.id, staffRoleKey: e.target.value || null })}
          disabled={setRoleKey.isPending}
          className="h-9 rounded-md border border-border bg-surface px-2 text-sm"
        >
          <option value="">{t("hr.staffSalary.noRole")}</option>
          {(roleSalaries ?? []).map((rs) => (
            <option key={rs.id} value={rs.role_key}>
              {rs.label}
            </option>
          ))}
        </select>
      ),
    },
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
            value={effectiveAmount(r)}
            onChange={(e) => setAmounts((prev) => ({ ...prev, [r.id]: e.target.value }))}
            className="h-9 w-32"
          />
          <Button size="xs" variant="accent" onClick={() => logSalary(r)} disabled={!(Number(effectiveAmount(r)) > 0) || loggingId === r.id}>
            {loggingId === r.id ? <Loader2 className="size-3 animate-spin" /> : <Wallet className="size-3" />}
            {t("hr.staffSalary.logSalary")}
          </Button>
          <Button size="xs" variant="outline" onClick={() => resetStaffLogin(r)} disabled={resettingId === r.id}>
            {resettingId === r.id ? <Loader2 className="size-3 animate-spin" /> : <KeyRound className="size-3" />}
            {t("hr.staffSalary.resetPassword")}
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
      <PasswordRevealDialog password={revealedPassword} title={t("hr.staffSalary.passwordDialogTitle")} onClose={() => setRevealedPassword(null)} />
    </div>
  )
}
