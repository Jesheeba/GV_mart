import { useTranslation } from "react-i18next"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { formatCurrency } from "@/lib/sale-calc"
import { maxQuotationDiscount, type DiscountProblem } from "@/lib/quotationDiscount"
import { FIELD_W } from "@/lib/fieldWidth"

export type DiscountState = { enabled: boolean; amount: string; reason: string }

/** The ₹ discount for a quotation: off by default (like the sale's opt-in discount), amount + required reason. */
export function QuotationDiscountField({
  value,
  onChange,
  subtotal,
  maxPercent,
  problem,
}: {
  value: DiscountState
  onChange: (next: DiscountState) => void
  subtotal: number
  maxPercent: number
  problem: DiscountProblem
}) {
  const { t } = useTranslation()
  return (
    <div className="space-y-2 px-1">
      <div className="flex items-center justify-between">
        <Label>{t("quotations.discount.label")}</Label>
        <div className="flex w-fit gap-1 rounded-full bg-surface-alt p-1" role="group" aria-label={t("quotations.discount.label")}>
          {([false, true] as const).map((v) => (
            <button
              key={String(v)}
              type="button"
              aria-pressed={value.enabled === v}
              onClick={() => onChange(v ? { ...value, enabled: true } : { enabled: false, amount: "", reason: "" })}
              className={`rounded-full px-4 py-1.5 text-sm font-medium transition-colors ${value.enabled === v ? "bg-ink text-white" : "text-text-muted"}`}
            >
              {t(v ? "common.yes" : "common.no")}
            </button>
          ))}
        </div>
      </div>
      {value.enabled ? (
        <div className="grid gap-2 sm:grid-cols-[auto_1fr]">
          <div className="space-y-1">
            <Label htmlFor="quote-discount-amount" className="text-xs text-text-muted">
              {t("quotations.discount.amountLabel")}
            </Label>
            <Input
              id="quote-discount-amount"
              type="number"
              inputMode="decimal"
              min={0}
              step="0.01"
              value={value.amount}
              onChange={(e) => onChange({ ...value, amount: e.target.value })}
              aria-invalid={problem?.key === "quotations.discount.errorOverCap" || problem?.key === "quotations.discount.errorNegative" || undefined}
              className={FIELD_W.amount}
            />
            <p className="text-xs text-text-muted">{t("quotations.discount.maxHint", { percent: maxPercent, max: formatCurrency(maxQuotationDiscount(subtotal, maxPercent)) })}</p>
          </div>
          <div className="space-y-1">
            <Label htmlFor="quote-discount-reason" className="text-xs text-text-muted">
              {t("quotations.discount.reasonLabel")}
            </Label>
            <Input
              id="quote-discount-reason"
              value={value.reason}
              onChange={(e) => onChange({ ...value, reason: e.target.value })}
              placeholder={t("quotations.discount.reasonPlaceholder")}
              aria-invalid={problem?.key === "quotations.discount.errorReason" || undefined}
            />
          </div>
        </div>
      ) : null}
      {problem ? (
        <p role="alert" className="text-xs text-danger">
          {t(problem.key, { ...problem.params, max: problem.params?.max != null ? formatCurrency(Number(problem.params.max)) : undefined })}
        </p>
      ) : null}
    </div>
  )
}

/** Subtotal − discount = net, then GST and the total (new quotation + edit popup). */
export function QuotationTotals({ subtotal, discount, gstLabel, gst, total }: { subtotal: number; discount: number; gstLabel: string; gst: number; total: number }) {
  const { t } = useTranslation()
  return (
    <div className="ml-auto w-full max-w-72 space-y-1 px-1 text-sm">
      {discount > 0 ? (
        <>
          <div className="flex justify-between text-text-muted">
            <span>{t("quotations.discount.subtotal")}</span>
            <span>{formatCurrency(subtotal)}</span>
          </div>
          <div className="flex justify-between text-success">
            <span>{t("quotations.discount.label")}</span>
            <span>− {formatCurrency(discount)}</span>
          </div>
        </>
      ) : null}
      <div className="flex justify-between text-text-muted">
        <span>{gstLabel}</span>
        <span>{formatCurrency(gst)}</span>
      </div>
      <div className="flex justify-between border-t border-border pt-1 font-bold text-text">
        <span>{t("sales.summary.total")}</span>
        <span>{formatCurrency(total)}</span>
      </div>
    </div>
  )
}
