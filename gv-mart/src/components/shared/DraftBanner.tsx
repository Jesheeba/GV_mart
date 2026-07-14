import { useState } from "react"
import { Save } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"

/**
 * "Your progress is saved on this device" banner + confirm-then-destructive
 * "Discard draft" affordance, shared by the admin/customer wizards that use
 * useLocalDraft (NewSalePage, NewComplaintPage, BookServicePage). Mirrors
 * OnSiteVisitPage's inline draft banner (technician.onsite.draft.*) and the
 * confirm-card pattern used by QuotationDetailPage's "Mark as Lost" flow.
 */
export function DraftBanner({
  restored,
  autosaveNote,
  restoredNote,
  discardLabel,
  discardWarning,
  confirmDiscardLabel,
  cancelLabel,
  onConfirmDiscard,
}: {
  restored: boolean
  autosaveNote: string
  restoredNote: string
  discardLabel: string
  discardWarning: string
  confirmDiscardLabel: string
  cancelLabel: string
  onConfirmDiscard: () => void
}) {
  const [showConfirm, setShowConfirm] = useState(false)

  return (
    <>
      <div className="flex items-center justify-between gap-2 px-1">
        <p className="flex items-center gap-1.5 text-xs text-text-muted">
          <Save className="size-3.5" />
          {restored ? restoredNote : autosaveNote}
        </p>
        {restored ? (
          <button type="button" className="text-xs font-medium text-danger" onClick={() => setShowConfirm((v) => !v)}>
            {discardLabel}
          </button>
        ) : null}
      </div>
      {showConfirm ? (
        <Card className="gap-2 px-3.5 py-3">
          <p className="text-xs text-text-muted">{discardWarning}</p>
          <div className="flex justify-end gap-2">
            <Button type="button" variant="outline" size="sm" onClick={() => setShowConfirm(false)}>
              {cancelLabel}
            </Button>
            <Button
              type="button"
              variant="destructive"
              size="sm"
              onClick={() => {
                setShowConfirm(false)
                onConfirmDiscard()
              }}
            >
              {confirmDiscardLabel}
            </Button>
          </div>
        </Card>
      ) : null}
    </>
  )
}
