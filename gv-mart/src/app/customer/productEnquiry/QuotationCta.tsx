import { useState } from "react"
import { useTranslation } from "react-i18next"
import { CheckCircle2, Loader2, Minus, Plus } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Label } from "@/components/ui/label"
import { useSubmitEnquiry } from "@/hooks/useCustomerApp"
import type { Json } from "@/types/database"

type QuotationConfig = { qty_stepper_enabled?: boolean; min_qty?: number; max_qty?: number; note_field_enabled?: boolean }

/**
 * Product Enquiry rebuild (2026-08-04), Phase 4 — inline "Request
 * Quotation" flow on the product detail page. Carries productId/qty into
 * submit_customer_enquiry (Phase 4 backend) instead of only free text.
 * Deliberately its own local state, not react-hook-form/zod's enquirySchema
 * — that schema's "description required, min 3 chars" was designed for the
 * free-text-only Videos & Topics flow; here the product itself is the
 * primary signal and a note is optional per admin config.
 */
export function QuotationCta({ orgId, productId, config, label }: { orgId: string | undefined; productId: string; config: Json; label: string }) {
  const { t } = useTranslation()
  const cfg = (config ?? {}) as QuotationConfig
  const minQty = cfg.min_qty ?? 1
  const maxQty = cfg.max_qty ?? 10
  const showQtyStepper = cfg.qty_stepper_enabled !== false
  const showNoteField = cfg.note_field_enabled !== false

  const [open, setOpen] = useState(false)
  const [qty, setQty] = useState(minQty)
  const [note, setNote] = useState("")
  const submitEnquiry = useSubmitEnquiry()

  if (submitEnquiry.isSuccess) {
    return (
      <Card className="items-center gap-2 py-4 text-center lg:px-5">
        <CheckCircle2 className="size-6 text-success" />
        <p className="text-sm font-medium text-text">{t("customerApp.productEnquiry.detail.quotationSubmitted")}</p>
      </Card>
    )
  }

  if (!open) {
    return (
      <Button type="button" className="w-full" onClick={() => setOpen(true)}>
        {label}
      </Button>
    )
  }

  return (
    <Card className="gap-3 lg:px-5">
      {showQtyStepper ? (
        <div className="flex items-center justify-between">
          <Label>{t("customerApp.productEnquiry.detail.qtyLabel")}</Label>
          <div className="flex items-center gap-2">
            <Button size="icon-xs" variant="outline" disabled={qty <= minQty} onClick={() => setQty((q) => Math.max(minQty, q - 1))}>
              <Minus className="size-3" />
            </Button>
            <span className="w-6 text-center text-sm font-semibold text-text">{qty}</span>
            <Button size="icon-xs" variant="outline" disabled={qty >= maxQty} onClick={() => setQty((q) => Math.min(maxQty, q + 1))}>
              <Plus className="size-3" />
            </Button>
          </div>
        </div>
      ) : null}
      {showNoteField ? (
        <div className="space-y-1">
          <Label>{t("customerApp.productEnquiry.detail.noteLabel")}</Label>
          <textarea
            rows={2}
            value={note}
            onChange={(e) => setNote(e.target.value)}
            placeholder={t("customerApp.productEnquiry.detail.notePlaceholder")}
            className="w-full rounded-xl border border-border bg-surface px-3.5 py-2.5 text-sm text-text outline-none placeholder:text-text-muted"
          />
        </div>
      ) : null}
      {submitEnquiry.isError ? <p className="text-xs text-danger">{(submitEnquiry.error as Error).message}</p> : null}
      <div className="flex justify-end gap-2">
        <Button type="button" variant="ghost" size="sm" onClick={() => setOpen(false)}>
          {t("common.cancel")}
        </Button>
        <Button
          type="button"
          size="sm"
          disabled={submitEnquiry.isPending || !orgId}
          onClick={() =>
            submitEnquiry.mutate({
              orgId: orgId!,
              kind: "product",
              enquiryType: null,
              description: note.trim(),
              productId,
              qty: showQtyStepper ? qty : 1,
            })
          }
        >
          {submitEnquiry.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("customerApp.productEnquiry.detail.submit")}
        </Button>
      </div>
    </Card>
  )
}
