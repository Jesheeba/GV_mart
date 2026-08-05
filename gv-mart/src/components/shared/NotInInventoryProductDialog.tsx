import { useEffect, useState } from "react"
import { useTranslation } from "react-i18next"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Dialog, DialogContent, DialogTitle, DialogDescription } from "@/components/ui/dialog"

const FIELD_ID = "not-in-inventory-product-name"

/**
 * Gate-assignment-on-product (2026-08-04): admin-only escape hatch for both
 * NewComplaintPage and TicketDetailPage's product editor — when the
 * customer's actual product isn't in Masters yet, type its name as free
 * text instead of being stuck requiring a catalog match. Shared so the two
 * call sites stay in sync (same copy, same behavior).
 */
export function NotInInventoryProductDialog({
  open,
  initialValue,
  onOpenChange,
  onSave,
}: {
  open: boolean
  initialValue: string
  onOpenChange: (open: boolean) => void
  onSave: (name: string) => void
}) {
  const { t } = useTranslation()
  const [name, setName] = useState(initialValue)

  useEffect(() => {
    if (open) setName(initialValue)
  }, [open, initialValue])

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogTitle>{t("service.newComplaint.notInInventoryPopup.title")}</DialogTitle>
        <DialogDescription>{t("service.newComplaint.notInInventoryPopup.hint")}</DialogDescription>
        <div className="space-y-1.5">
          <Label htmlFor={FIELD_ID}>{t("service.newComplaint.notInInventoryPopup.label")}</Label>
          <Input
            id={FIELD_ID}
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder={t("service.newComplaint.notInInventoryPopup.placeholder")}
            autoFocus
          />
        </div>
        <div className="flex justify-end gap-2 pt-1">
          <Button type="button" size="sm" variant="ghost" onClick={() => onOpenChange(false)}>
            {t("service.newComplaint.notInInventoryPopup.cancel")}
          </Button>
          <Button type="button" size="sm" disabled={!name.trim()} onClick={() => onSave(name.trim())}>
            {t("service.newComplaint.notInInventoryPopup.save")}
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  )
}
