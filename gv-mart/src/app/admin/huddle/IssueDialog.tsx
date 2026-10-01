import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import { Button } from "@/components/ui/button"
import { Label } from "@/components/ui/label"
import { useToast } from "@/components/ui/toast-context"
import type { AssignableProfile } from "@/services/tasks"
import type { IssueInput, MeetingIssue } from "@/services/huddle"

const textareaClass = "w-full rounded-xl border border-border bg-surface px-3 py-2 text-sm text-text outline-none focus-visible:ring-2 focus-visible:ring-accent/40"

/** Create (issue = null) or edit one huddle issue. The mutation lives in the
 * parent so create and edit share one dialog. */
export function IssueDialog({
  issue,
  profiles,
  saving,
  onSubmit,
  onClose,
}: {
  issue: MeetingIssue | null
  profiles: AssignableProfile[]
  saving: boolean
  onSubmit: (input: IssueInput) => void
  onClose: () => void
}) {
  const { t } = useTranslation()
  const { toast } = useToast()
  const [description, setDescription] = useState(issue?.description ?? "")
  const [rootCause, setRootCause] = useState(issue?.root_cause ?? "")
  const [solution, setSolution] = useState(issue?.solution ?? "")
  const [ownerId, setOwnerId] = useState(issue?.owner_id ?? "")

  function submit() {
    if (!description.trim()) {
      toast.error(t("huddle.descriptionRequired"))
      return
    }
    onSubmit({ description, rootCause, solution, ownerId: ownerId || null })
  }

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent>
        <DialogTitle>{issue ? t("huddle.editIssue") : t("huddle.addIssue")}</DialogTitle>
        <DialogDescription>{t("huddle.issueDialogHint")}</DialogDescription>

        <div className="space-y-1.5">
          <Label htmlFor="issueDescription">{t("huddle.problem")}</Label>
          <textarea id="issueDescription" rows={2} className={textareaClass} value={description} onChange={(e) => setDescription(e.target.value)} />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="issueRootCause">{t("huddle.rootCause")}</Label>
          <textarea id="issueRootCause" rows={2} className={textareaClass} value={rootCause} onChange={(e) => setRootCause(e.target.value)} />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="issueSolution">{t("huddle.solution")}</Label>
          <textarea id="issueSolution" rows={2} className={textareaClass} value={solution} onChange={(e) => setSolution(e.target.value)} />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="issueOwner">{t("huddle.owner")}</Label>
          <select
            id="issueOwner"
            value={ownerId}
            onChange={(e) => setOwnerId(e.target.value)}
            className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
          >
            <option value="">{t("huddle.noOwner")}</option>
            {profiles.map((p) => (
              <option key={p.id} value={p.id}>
                {p.full_name}
              </option>
            ))}
          </select>
        </div>

        <div className="flex justify-end gap-2 pt-1">
          <Button type="button" variant="outline" onClick={onClose}>
            {t("common.cancel")}
          </Button>
          <Button type="button" disabled={saving} onClick={submit}>
            {t("common.save")}
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  )
}
