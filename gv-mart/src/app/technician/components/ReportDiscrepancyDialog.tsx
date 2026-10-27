import { useState } from "react"
import { useTranslation } from "react-i18next"
import { AlertTriangle } from "lucide-react"
import { Dialog, DialogContent, DialogTitle, DialogDescription } from "@/components/ui/dialog"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { useToast } from "@/components/ui/toast-context"
import { useReportHandoverDiscrepancy } from "@/hooks/useTechnician"
import { spareHandoverDiscrepancySchema } from "@/lib/validation/technician"

/**
 * Requirement 2 (dispute flagging, 2026-11-14 gap fix) — lets the technician say "I didn't
 * actually receive this quantity" for one line of today's hand-over, without having to
 * refuse signing the whole block. Calls report_spare_handover_discrepancy, which notifies
 * staff (role=operation_admin, which master also sees) — the technician doesn't need to
 * chase anyone separately.
 */
export function ReportDiscrepancyDialog({
  orgId,
  itemId,
  spareName,
  qtyGiven,
  open,
  onOpenChange,
}: {
  orgId: string
  itemId: string
  spareName: string
  qtyGiven: number
  open: boolean
  onOpenChange: (open: boolean) => void
}) {
  const { t } = useTranslation()
  const { toast } = useToast()
  const reportDiscrepancy = useReportHandoverDiscrepancy()
  const [receivedQty, setReceivedQty] = useState("")
  const [note, setNote] = useState("")
  const [error, setError] = useState<string | null>(null)

  function reset() {
    setReceivedQty("")
    setNote("")
    setError(null)
  }

  async function handleSubmit() {
    const parsed = spareHandoverDiscrepancySchema(qtyGiven).safeParse({ receivedQty, note })
    if (!parsed.success) {
      setError(t(parsed.error.issues[0]?.message ?? "technician.spareHandover.receivedQtyRequired"))
      return
    }
    setError(null)
    try {
      await reportDiscrepancy.mutateAsync({ orgId, itemId, receivedQty: parsed.data.receivedQty, note: parsed.data.note ?? null })
      toast.success(t("technician.spareHandover.reportSuccess"))
      reset()
      onOpenChange(false)
    } catch {
      toast.error(t("technician.spareHandover.reportFailed"))
    }
  }

  return (
    <Dialog
      open={open}
      onOpenChange={(next) => {
        if (!next) reset()
        onOpenChange(next)
      }}
    >
      <DialogContent className="max-w-sm">
        <DialogTitle className="flex items-center gap-1.5 text-warning">
          <AlertTriangle className="size-4" />
          {t("technician.spareHandover.reportProblemTitle", { name: spareName })}
        </DialogTitle>
        <DialogDescription>{t("technician.spareHandover.givenQtyLabel", { qty: qtyGiven })}</DialogDescription>

        <div className="flex flex-col gap-1.5">
          <label className="text-xs font-medium text-text-muted">{t("technician.spareHandover.receivedQtyLabel")}</label>
          <Input
            type="number"
            inputMode="numeric"
            min={0}
            value={receivedQty}
            onChange={(e) => setReceivedQty(e.target.value)}
            disabled={reportDiscrepancy.isPending}
          />
        </div>
        <div className="flex flex-col gap-1.5">
          <label className="text-xs font-medium text-text-muted">{t("technician.spareHandover.noteLabel")}</label>
          <Input value={note} onChange={(e) => setNote(e.target.value)} disabled={reportDiscrepancy.isPending} />
        </div>
        {error ? <p className="text-xs text-danger">{error}</p> : null}

        <div className="flex gap-2">
          <Button type="button" variant="outline" className="flex-1" onClick={() => onOpenChange(false)} disabled={reportDiscrepancy.isPending}>
            {t("technician.spareHandover.reportCancel")}
          </Button>
          <Button type="button" className="flex-1" onClick={handleSubmit} disabled={reportDiscrepancy.isPending}>
            {t("technician.spareHandover.reportSubmit")}
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  )
}
