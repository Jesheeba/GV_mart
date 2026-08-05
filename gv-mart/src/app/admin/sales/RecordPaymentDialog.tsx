import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useRecordAdditionalPayment } from "@/hooks/useSales"
import { paymentDetailsSchema, isAmountPaidBlocked } from "@/lib/validation/sale"
import { formatCurrency } from "@/lib/sale-calc"
import type { Enums } from "@/types/database"

/** Top-up form for a partial/due invoice — the only settlement path besides UPI's own record_upi_payment (technician-only, always full amount). Opened from InvoicePage next to the payment-status badge. */
export function RecordPaymentDialog({
  orgId,
  invoiceId,
  remaining,
  onClose,
}: {
  orgId: string
  invoiceId: string
  remaining: number
  onClose: () => void
}) {
  const { t } = useTranslation()
  const recordPayment = useRecordAdditionalPayment()
  const [amountInput, setAmountInput] = useState(remaining.toFixed(2))
  const [method, setMethod] = useState<Enums<"payment_method">>("cash")
  const [txnId, setTxnId] = useState("")
  const [description, setDescription] = useState("")
  const [error, setError] = useState<string | null>(null)

  const amount = Math.max(0, Number(amountInput) || 0)

  function handleSubmit() {
    const result = paymentDetailsSchema.safeParse({ method, txnId, description, amountPaid: amount })
    if (!result.success) {
      setError(result.error.issues[0]?.message ?? "sales.errors.paymentInvalid")
      return
    }
    if (amount <= 0 || isAmountPaidBlocked(amount, remaining)) {
      setError("sales.errors.recordPaymentInvalid")
      return
    }
    setError(null)
    recordPayment.mutate(
      {
        orgId,
        invoiceId,
        amount,
        paymentMethod: method,
        txnId: method === "transfer" ? txnId : null,
        paymentDescription: method === "transfer" ? description : null,
      },
      {
        onSuccess: () => onClose(),
        onError: () => setError("sales.errors.paymentInvalid"),
      }
    )
  }

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent>
        <DialogTitle>{t("sales.invoice.recordPayment")}</DialogTitle>
        <DialogDescription>{t("sales.invoice.recordPaymentHint", { amount: formatCurrency(remaining) })}</DialogDescription>

        <div className="space-y-1.5">
          <Label htmlFor="recordAmount">{t("sales.payment.amountCollected")}</Label>
          <Input
            id="recordAmount"
            type="number"
            min={0}
            step="0.01"
            value={amountInput}
            onChange={(e) => setAmountInput(e.target.value)}
            className="w-40"
          />
        </div>

        <div className="space-y-1.5">
          <Label>{t("sales.payment.method")}</Label>
          <div className="flex w-fit gap-1 rounded-full bg-surface-alt p-1">
            {(["cash", "transfer"] as const).map((m) => (
              <button
                key={m}
                type="button"
                onClick={() => setMethod(m)}
                className={`rounded-full px-4 py-1.5 text-sm font-medium transition-colors ${method === m ? "bg-ink text-white" : "text-text-muted"}`}
              >
                {t(`sales.payment.${m}`)}
              </button>
            ))}
          </div>
        </div>

        {method === "transfer" ? (
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <div className="space-y-1.5">
              <Label htmlFor="recordTxnId">{t("sales.payment.txnId")}</Label>
              <Input id="recordTxnId" value={txnId} onChange={(e) => setTxnId(e.target.value)} />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="recordDescription">{t("sales.payment.description")}</Label>
              <Input id="recordDescription" value={description} onChange={(e) => setDescription(e.target.value)} />
            </div>
          </div>
        ) : null}

        {error ? <p className="text-xs text-danger">{t(error)}</p> : null}

        <div className="flex justify-end gap-2 pt-1">
          <Button type="button" variant="outline" onClick={onClose}>
            {t("common.cancel")}
          </Button>
          <Button type="button" onClick={handleSubmit} disabled={recordPayment.isPending}>
            {t("sales.invoice.recordPayment")}
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  )
}
