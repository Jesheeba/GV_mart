import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useToast } from "@/components/ui/toast-context"
import { useProfile } from "@/hooks/useProfile"
import { useAssignLead, useLeadAssignees } from "@/hooks/useLeadFollowups"
import type { UserRole } from "@/lib/roles"

export type AssignableLead = { id: string; name: string; assignedTo: string | null }

const selectClass =
  "h-9 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"
/** Assign one lead, or several at once (master bulk assign). Sends one assign_lead call per lead. */
export function AssignLeadDialog({ leads, open, onOpenChange, onDone }: { leads: AssignableLead[]; open: boolean; onOpenChange: (open: boolean) => void; onDone?: () => void }) {
  const { t } = useTranslation()
  const { toast } = useToast()
  const { data: profile } = useProfile()
  const role = profile?.role as UserRole | undefined
  const assignees = useLeadAssignees(profile?.org_id, role).data ?? []
  const assign = useAssignLead()
  const [target, setTarget] = useState("")
  const [reason, setReason] = useState("")

  const isMaster = role === "master"
  // sales_admin: pick up for themselves, or hand over to a colleague
  const single = leads[0]
  const singleEffective = single?.assignedTo && assignees.some((a) => a.id === single.assignedTo) ? single.assignedTo : null
  const options = isMaster ? assignees : singleEffective ? assignees.filter((a) => a.id !== profile?.id) : assignees.filter((a) => a.id === profile?.id)

  async function save() {
    if (!target) return
    const assigneeId = target === "__none__" ? null : target
    let ok = 0
    let firstError: string | null = null
    for (const l of leads) {
      try {
        await assign.mutateAsync({ leadId: l.id, assigneeId, reason: reason.trim() || null })
        ok += 1
      } catch (e) {
        firstError ??= e instanceof Error && e.message ? e.message : t("common.actionFailed")
      }
    }
    if (ok > 0) toast.success(t("leads.assign.done", { count: ok }))
    if (firstError) toast.error(leads.length > 1 ? t("leads.assign.partial", { failed: leads.length - ok, error: firstError }) : firstError)
    if (ok > 0) {
      setTarget("")
      setReason("")
      onOpenChange(false)
      onDone?.()
    }
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogTitle>{leads.length > 1 ? t("leads.assign.titleBulk", { count: leads.length }) : t("leads.assign.title")}</DialogTitle>
        <DialogDescription>{leads.length === 1 ? leads[0].name : t("leads.assign.bulkHint")}</DialogDescription>
        <div className="space-y-3">
          <div className="space-y-1.5">
            <Label htmlFor="assign-target">{t("leads.assign.to")}</Label>
            <select id="assign-target" value={target} onChange={(e) => setTarget(e.target.value)} className={selectClass}>
              <option value="">{t("leads.assign.choose")}</option>
              {options.map((a) => (
                <option key={a.id} value={a.id}>
                  {a.full_name}
                  {a.id === profile?.id ? ` (${t("leads.assign.me")})` : ""}
                </option>
              ))}
              {isMaster ? <option value="__none__">{t("leads.assign.unassign")}</option> : null}
            </select>
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="assign-reason">{t("leads.assign.reason")}</Label>
            <Input id="assign-reason" value={reason} onChange={(e) => setReason(e.target.value)} placeholder={t("leads.assign.reasonPlaceholder")} />
          </div>
          <div className="flex justify-end gap-2">
            <Button variant="ghost" onClick={() => onOpenChange(false)}>
              {t("common.cancel")}
            </Button>
            <Button variant="accent" onClick={save} disabled={!target || assign.isPending}>
              {assign.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("leads.assign.save")}
            </Button>
          </div>
        </div>
      </DialogContent>
    </Dialog>
  )
}
