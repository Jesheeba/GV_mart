import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useToast } from "@/components/ui/toast-context"
import { useCreateStaff } from "@/hooks/useHr"
import { PasswordRevealDialog } from "@/app/admin/technicians/PasswordRevealDialog"

type StaffRole = "sales_admin" | "operation_admin"
const ROLES: StaffRole[] = ["sales_admin", "operation_admin"]
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/

const selectClass =
  "h-9 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"

/**
 * Master-only "Add staff": creates an operation_admin / sales_admin login through the admin-create-staff
 * Edge Function (email is the login). The password is shared in person: a generated one is shown exactly once.
 */
export function AddStaffDialog({ open, onOpenChange }: { open: boolean; onOpenChange: (open: boolean) => void }) {
  const { t } = useTranslation()
  const { toast } = useToast()
  const create = useCreateStaff()

  const [fullName, setFullName] = useState("")
  const [email, setEmail] = useState("")
  const [phone, setPhone] = useState("")
  const [designation, setDesignation] = useState("")
  const [address, setAddress] = useState("")
  const [role, setRole] = useState<StaffRole>("sales_admin")
  const [mode, setMode] = useState<"generate" | "type">("generate")
  const [typed, setTyped] = useState("")
  const [reason, setReason] = useState("")
  const [revealed, setRevealed] = useState<{ password: string } | null>(null)

  const emailOk = EMAIL_RE.test(email.trim())
  const typedOk = mode === "generate" || new TextEncoder().encode(typed).length >= 10
  const phoneDigits = phone.replace(/\D/g, "").replace(/^91(?=\d{10}$)/, "")
  const phoneOk = phoneDigits.length === 10
  const canSubmit =
    fullName.trim().length >= 2 && emailOk && phoneOk && designation.trim().length >= 2 && address.trim().length >= 8 && typedOk && !create.isPending

  function reset() {
    setFullName("")
    setEmail("")
    setPhone("")
    setDesignation("")
    setAddress("")
    setRole("sales_admin")
    setMode("generate")
    setTyped("")
    setReason("")
  }

  function submit() {
    if (!canSubmit) return
    const name = fullName.trim()
    create.mutate(
      {
        fullName: name,
        email: email.trim(),
        phone: phoneDigits,
        designation: designation.trim(),
        address: address.trim(),
        role,
        password: mode === "type" ? typed : undefined,
        reason: reason.trim() || undefined,
      },
      {
        onSuccess: (res) => {
          reset()
          onOpenChange(false)
          if (res.password) setRevealed({ password: res.password })
          else toast.success(t("hr.staffSalary.createdTyped", { name }))
        },
        onError: (e) => toast.error(e instanceof Error && e.message ? e.message : t("hr.staffSalary.createFailed")),
      }
    )
  }

  return (
    <>
      <Dialog open={open} onOpenChange={onOpenChange}>
        <DialogContent>
          <DialogTitle>{t("hr.staffSalary.addStaffTitle")}</DialogTitle>
          <DialogDescription>{t("hr.staffSalary.addStaffHint")}</DialogDescription>
          <form
            className="space-y-3"
            onSubmit={(e) => {
              e.preventDefault()
              submit()
            }}
          >
            <div className="space-y-1">
              <Label htmlFor="staff-full-name" className="block text-xs font-medium text-text-muted">
                {t("hr.staffSalary.fullName")}
              </Label>
              <Input id="staff-full-name" value={fullName} maxLength={80} onChange={(e) => setFullName(e.target.value)} autoComplete="off" />
            </div>
            <div className="space-y-1">
              <Label htmlFor="staff-email" className="block text-xs font-medium text-text-muted">
                {t("hr.staffSalary.email")}
              </Label>
              <Input id="staff-email" type="email" value={email} onChange={(e) => setEmail(e.target.value)} autoComplete="off" />
            </div>
            <div className="grid grid-cols-2 gap-3">
              <div className="space-y-1">
                <Label htmlFor="staff-phone" className="block text-xs font-medium text-text-muted">
                  {t("hr.staffSalary.phone")}
                </Label>
                <Input id="staff-phone" type="tel" value={phone} onChange={(e) => setPhone(e.target.value)} autoComplete="off" required />
              </div>
              <div className="space-y-1">
                <Label htmlFor="staff-role" className="block text-xs font-medium text-text-muted">
                  {t("hr.staffSalary.role")}
                </Label>
                <select id="staff-role" value={role} onChange={(e) => setRole(e.target.value as StaffRole)} className={selectClass}>
                  {ROLES.map((r) => (
                    <option key={r} value={r}>
                      {t(`roles.${r}`)}
                    </option>
                  ))}
                </select>
              </div>
            </div>

            <div className="space-y-1">
              <Label htmlFor="staff-designation" className="block text-xs font-medium text-text-muted">
                {t("hr.staffSalary.designation")}
              </Label>
              <Input id="staff-designation" value={designation} maxLength={80} onChange={(e) => setDesignation(e.target.value)} autoComplete="off" required />
            </div>
            <div className="space-y-1">
              <Label htmlFor="staff-address" className="block text-xs font-medium text-text-muted">
                {t("hr.staffSalary.address")}
              </Label>
              <textarea
                id="staff-address"
                rows={3}
                maxLength={400}
                value={address}
                onChange={(e) => setAddress(e.target.value)}
                required
                className="w-full rounded-xl border border-border bg-surface px-3 py-2 text-sm text-text outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"
              />
            </div>

            <p className="rounded-xl bg-surface-alt px-3 py-2 text-xs text-text-muted">{t("hr.staffSalary.mustChangeHint")}</p>

            <fieldset className="space-y-1.5">
              <legend className="text-xs font-medium text-text-muted">{t("hr.staffSalary.passwordMode")}</legend>
              <label className="flex items-center gap-2 text-sm text-text">
                <input type="radio" name="staff-password-mode" checked={mode === "generate"} onChange={() => setMode("generate")} />
                {t("hr.staffSalary.passwordGenerate")}
              </label>
              <label className="flex items-center gap-2 text-sm text-text">
                <input type="radio" name="staff-password-mode" checked={mode === "type"} onChange={() => setMode("type")} />
                {t("hr.staffSalary.passwordType")}
              </label>
              {mode === "type" ? (
                <Input aria-label={t("hr.staffSalary.typedPassword")} placeholder={t("hr.staffSalary.typedPassword")} type="text" autoComplete="off" minLength={10} maxLength={72} value={typed} onChange={(e) => setTyped(e.target.value)} />
              ) : null}
            </fieldset>

            <div className="space-y-1">
              <Label htmlFor="staff-reason" className="block text-xs font-medium text-text-muted">
                {t("hr.staffSalary.reason")}
              </Label>
              <Input id="staff-reason" value={reason} maxLength={200} onChange={(e) => setReason(e.target.value)} placeholder={t("hr.staffSalary.reasonPlaceholder")} autoComplete="off" />
            </div>

            <div className="flex justify-end gap-2">
              <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
                {t("common.cancel", "Cancel")}
              </Button>
              <Button type="submit" disabled={!canSubmit}>
                {create.isPending && <Loader2 className="size-3.5 animate-spin" />}
                {t("hr.staffSalary.createStaff")}
              </Button>
            </div>
          </form>
        </DialogContent>
      </Dialog>

      {/* shown once; no phone passed, so no WhatsApp share link - the password is handed over in person */}
      <PasswordRevealDialog password={revealed?.password ?? null} title={t("hr.staffSalary.createdTitle")} onClose={() => setRevealed(null)} />
    </>
  )
}
