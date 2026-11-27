import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { DatePicker } from "@/components/ui/date-picker"
import { Dialog, DialogContent, DialogTitle } from "@/components/ui/dialog"
import { useSettings } from "@/hooks/useMasters"
import { useUpdateQuotation } from "@/hooks/useQuotations"
import { billBreakdown } from "@/lib/sale-calc"
import { quotationDiscountProblem } from "@/lib/quotationDiscount"
import type { QuotationDetail } from "@/services/quotations"
import { QuotationLinesEditor, type QuoteLine } from "./QuotationLinesEditor"
import { QuotationDiscountField, QuotationTotals, type DiscountState } from "./QuotationDiscountField"

/**
 * Edit an OPEN quotation (quotation-edit-discount): items, qty, ₹ discount, valid-until, plus a required
 * reason that goes into the quotation's edit history. Converted/Lost quotes never show this (and the RPC
 * + a table trigger refuse anyway). Mounted only while open, so every open starts from the saved quote.
 */
export function QuotationEditDialog({ orgId, quotation, onClose }: { orgId: string; quotation: QuotationDetail; onClose: () => void }) {
  const { t } = useTranslation()
  const { data: settings } = useSettings(orgId)
  const update = useUpdateQuotation()

  const [lines, setLines] = useState<QuoteLine[]>(() =>
    quotation.quotation_items.map((it) => ({ itemType: it.item_type, itemId: it.item_id, name: it.itemName, price: Number(it.price), qty: it.qty }))
  )
  const [discount, setDiscount] = useState<DiscountState>(() => ({
    enabled: quotation.discount_amount > 0,
    amount: quotation.discount_amount > 0 ? String(quotation.discount_amount) : "",
    reason: quotation.discount_reason ?? "",
  }))
  const [validUntil, setValidUntil] = useState(quotation.valid_until ?? "")
  const [reason, setReason] = useState("")
  const [reasonTouched, setReasonTouched] = useState(false)

  const subtotal = useMemo(() => lines.reduce((sum, l) => sum + l.price * l.qty, 0), [lines])
  const maxPct = settings ? Number(settings.discount_admin_max) : 10
  const discountAmount = discount.enabled ? Number(discount.amount) || 0 : 0
  const problem = discount.enabled ? quotationDiscountProblem(subtotal, discountAmount, discount.reason, maxPct) : null
  const gstRate = quotation.no_gst ? 0 : settings ? Number(settings.gst_rate) : 0
  const bill = billBreakdown(subtotal - discountAmount, 0, gstRate, !!quotation.gst_inclusive)
  const gstLabel = quotation.no_gst ? t("sales.gst.notCharged") : quotation.gst_inclusive ? t("sales.gst.includedAmount") : t("sales.summary.gst", { rate: gstRate })
  const canSave = lines.length > 0 && !problem && reason.trim() !== "" && !update.isPending

  async function save() {
    setReasonTouched(true)
    if (!canSave) return
    try {
      await update.mutateAsync({
        id: quotation.id,
        items: lines.map((l) => ({ itemType: l.itemType, itemId: l.itemId, qty: l.qty })),
        discountAmount,
        discountReason: discountAmount > 0 ? discount.reason.trim() : null,
        validUntil: validUntil || null,
        reason: reason.trim(),
      })
      onClose()
    } catch {
      // shown from update.error below
    }
  }

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="max-w-2xl">
        <DialogTitle>{t("quotations.edit.title")}</DialogTitle>
        <QuotationLinesEditor orgId={orgId} lines={lines} onChange={setLines} />
        <div className="border-t border-border pt-3">
          <QuotationDiscountField value={discount} onChange={setDiscount} subtotal={subtotal} maxPercent={maxPct} problem={problem} />
        </div>
        {lines.length > 0 ? <QuotationTotals subtotal={subtotal} discount={discountAmount} gstLabel={gstLabel} gst={quotation.gst_inclusive === null ? 0 : bill.gst} total={quotation.gst_inclusive === null ? subtotal - discountAmount : bill.total} /> : null}
        <div className="grid gap-3 border-t border-border px-1 pt-3 sm:grid-cols-[auto_1fr]">
          <div className="space-y-1">
            <Label htmlFor="quote-edit-valid">{t("quotations.form.validUntil")}</Label>
            <DatePicker id="quote-edit-valid" value={validUntil} onChange={setValidUntil} className="w-48" />
          </div>
          <div className="space-y-1">
            <Label htmlFor="quote-edit-reason">{t("quotations.edit.reasonLabel")}</Label>
            <Input
              id="quote-edit-reason"
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              onBlur={() => setReasonTouched(true)}
              placeholder={t("quotations.edit.reasonPlaceholder")}
              aria-invalid={(reasonTouched && !reason.trim()) || undefined}
              aria-describedby={reasonTouched && !reason.trim() ? "quote-edit-reason-error" : undefined}
            />
            {reasonTouched && !reason.trim() ? (
              <p id="quote-edit-reason-error" role="alert" className="text-xs text-danger">
                {t("quotations.edit.reasonRequired")}
              </p>
            ) : null}
          </div>
        </div>
        {update.isError ? <p className="rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{(update.error as Error).message}</p> : null}
        <div className="flex justify-end gap-2">
          <Button type="button" variant="ghost" onClick={onClose}>
            {t("common.cancel")}
          </Button>
          <Button type="button" onClick={save} disabled={lines.length === 0 || !!problem || update.isPending}>
            {update.isPending ? <Loader2 className="size-4 animate-spin" /> : t("common.save")}
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  )
}
