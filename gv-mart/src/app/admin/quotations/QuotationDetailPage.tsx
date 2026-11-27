import { useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate, useParams } from "react-router-dom"
import { MessageCircle, Printer } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { StatusDot, type StatusTone } from "@/components/shared/StatusDot"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { useProfile } from "@/hooks/useProfile"
import { useMarkQuotationLost, useQuotation, useQuotationRevisions } from "@/hooks/useQuotations"
import { useOrganization } from "@/hooks/useSales"
import { billBreakdown, formatCurrency } from "@/lib/sale-calc"
import { useSettings } from "@/hooks/useMasters"
import { formatDate } from "@/lib/formatDate"
import { amountInWords } from "@/lib/amount-in-words"
import { toWhatsappLink } from "@/lib/whatsapp-link"
import { QuotationOriginBadge } from "./QuotationBadges"
import { QuotationEditDialog } from "./QuotationEditDialog"

const STATUS_TONE: Record<string, StatusTone> = { open: "info", converted: "success", lost: "danger" }
const CELL = "border border-[#444] p-2 align-top"

export function QuotationDetailPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { id } = useParams<{ id: string }>()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: quotation, isLoading, isError, refetch } = useQuotation(orgId, id)
  const { data: org } = useOrganization(orgId)
  const { data: settings } = useSettings(orgId)
  const markLost = useMarkQuotationLost()
  const [lostReason, setLostReason] = useState("")
  const [showLostForm, setShowLostForm] = useState(false)
  const [editOpen, setEditOpen] = useState(false)
  const revisions = useQuotationRevisions(id)

  if (isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError || !quotation) {
    return <FullPageError message={t("quotations.error.loadFailed")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  const quotationNo = quotation.id.slice(0, 8).toUpperCase()
  // quotation-edit-discount: total is NET of the ₹ discount; subtotal = what the lines add up to.
  const discount = Number(quotation.discount_amount) || 0
  const subtotal = quotation.total + discount
  // GST (2026-11-26): null = quotation made before the GST switch existed —
  // shown exactly as before (no GST lines). Uses today's org rate; a quote is
  // an estimate and create_sale recomputes at the rate in force when billed.
  const gstRate = settings ? Number(settings.gst_rate) : 0
  const gstBill = quotation.gst_inclusive === null ? null : billBreakdown(quotation.total, 0, quotation.no_gst ? 0 : gstRate, quotation.gst_inclusive)
  const payable = gstBill ? gstBill.total : quotation.total
  // no_gst (no-gst-bill): GST 0, and the quotation total is the final amount.
  const gstLabel = quotation.no_gst ? t("sales.gst.notCharged") : quotation.gst_inclusive ? t("sales.gst.includedAmount") : t("sales.summary.gst", { rate: gstRate })

  return (
    <div className="mx-auto max-w-2xl space-y-4 pt-2">
      <div className="flex items-center justify-between print:hidden">
        <Button type="button" variant="outline" onClick={() => navigate(-1)}>
          {t("sales.newSale.back")}
        </Button>
        <div className="flex items-center gap-2">
          <Button type="button" variant="outline" onClick={() => window.print()}>
            <Printer className="size-4" />
            {t("quotations.print")}
          </Button>
          {quotation.customers?.mobile ? (
            <Button
              variant="accent"
              nativeButton={false}
              render={
                <a
                  href={toWhatsappLink(
                    quotation.customers.mobile,
                    t("quotations.whatsappMessage", { id: quotationNo, total: formatCurrency(payable) })
                  )}
                  target="_blank"
                  rel="noreferrer"
                />
              }
            >
              <MessageCircle className="size-4" />
              {t("quotations.shareWhatsapp")}
            </Button>
          ) : null}
        </div>
      </div>

      {/* Customer-facing printout — mirrors the invoice's letterhead format
          (org header + fields table + items table) rather than the
          staff-facing card below. */}
      <div className="hidden bg-white text-black print:block">
        <table className="w-full border-collapse">
          <tbody>
            <tr>
              <td className="p-2 align-top">
                {org?.gst_no ? (
                  <>
                    <strong>GSTIN:</strong> {org.gst_no}
                  </>
                ) : null}
              </td>
              <td className="p-2 text-center align-top">
                <h2 className="m-1 text-xl font-bold">{org?.name ?? t("common.appName")}</h2>
                {org?.address ? <div>{org.address}</div> : null}
                <h3 className="m-1 text-lg font-bold">{t("quotations.printTitle")}</h3>
              </td>
              <td className="p-2 text-right align-top">{org?.phone ?? ""}</td>
            </tr>
          </tbody>
        </table>

        <table className="mt-2 w-full border-collapse">
          <tbody>
            <tr>
              <td className={`${CELL} w-[55%]`}>
                <b>{t("sales.invoice.billedTo")}:</b> {quotation.customers?.name} - {quotation.customers?.mobile}
              </td>
              <td className="p-0 align-top">
                <table className="w-full border-collapse">
                  <tbody>
                    <tr>
                      <td className={CELL}>{t("quotations.quotationNoLabel")}</td>
                      <td className={CELL}>{quotationNo}</td>
                    </tr>
                    <tr>
                      <td className={CELL}>{t("sales.invoice.dateLabel")}</td>
                      <td className={`${CELL} whitespace-nowrap`}>{formatDate(quotation.created_at)}</td>
                    </tr>
                    {quotation.valid_until ? (
                      <tr>
                        <td className={CELL}>{t("quotations.table.validUntil")}</td>
                        <td className={`${CELL} whitespace-nowrap`}>{formatDate(quotation.valid_until)}</td>
                      </tr>
                    ) : null}
                  </tbody>
                </table>
              </td>
            </tr>
          </tbody>
        </table>

        <table className="mt-2 w-full border-collapse">
          <thead>
            <tr>
              <th className={CELL}>{t("sales.invoice.sno")}</th>
              <th className={CELL}>{t("sales.invoice.description")}</th>
              <th className={CELL}>{t("sales.invoice.qty")}</th>
              <th className={CELL}>{t("sales.invoice.rate")}</th>
              <th className={CELL}>{t("sales.invoice.value")}</th>
            </tr>
          </thead>
          <tbody>
            {quotation.quotation_items.map((item, i) => (
              <tr key={item.id}>
                <td className={CELL}>{i + 1}</td>
                <td className={CELL}>{item.itemName} {item.itemCode ? <span className="text-text-muted"> ({item.itemCode})</span> : null}</td>
                <td className={`${CELL} text-right`}>{item.qty}</td>
                <td className={`${CELL} text-right`}>{item.price.toFixed(2)}</td>
                <td className={`${CELL} text-right`}>{(item.qty * item.price).toFixed(2)}</td>
              </tr>
            ))}
            {discount > 0 ? (
              <>
                <tr>
                  <td colSpan={4} className={`${CELL} text-right`}>{t("quotations.discount.subtotal")}</td>
                  <td className={`${CELL} text-right`}>{subtotal.toFixed(2)}</td>
                </tr>
                <tr>
                  <td colSpan={4} className={`${CELL} text-right`}>{t("quotations.discount.label")}</td>
                  <td className={`${CELL} text-right`}>-{discount.toFixed(2)}</td>
                </tr>
              </>
            ) : null}
            <tr>
              <td colSpan={4} className={`${CELL} text-right`}>
                <b>{t("sales.invoice.netAmount")}</b>
              </td>
              <td className={`${CELL} text-right`}>
                <b>{quotation.total.toFixed(2)}</b>
              </td>
            </tr>
            {gstBill ? (
              <>
                <tr>
                  <td colSpan={4} className={`${CELL} text-right`}>{gstLabel}</td>
                  <td className={`${CELL} text-right`}>{gstBill.gst.toFixed(2)}</td>
                </tr>
                {!quotation.gst_inclusive && !quotation.no_gst ? (
                  <tr>
                    <td colSpan={4} className={`${CELL} text-right`}><b>{t("sales.invoice.totalWithGst")}</b></td>
                    <td className={`${CELL} text-right`}><b>{gstBill.total.toFixed(2)}</b></td>
                  </tr>
                ) : null}
              </>
            ) : null}
            <tr>
              <td colSpan={5} className={CELL}>
                <b>{amountInWords(payable)}</b>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <Card className="gap-4 px-5 print:hidden">
        <div className="flex items-start justify-between border-b border-border px-1 pb-3">
          <div>
            <p className="text-lg font-bold text-text">{org?.name ?? t("common.appName")}</p>
            {org?.gst_no ? <p className="text-xs text-text-muted">{t("sales.invoice.gstNo", { gst: org.gst_no })}</p> : null}
          </div>
          <div className="text-right">
            <p className="text-sm font-semibold text-text">{t("quotations.quotationNo", { id: quotationNo })}</p>
            <p className="text-xs text-text-muted">{formatDate(quotation.created_at)}</p>
            {quotation.valid_until ? (
              <p className="text-xs text-text-muted">
                {t("quotations.table.validUntil")}: {formatDate(quotation.valid_until)}
              </p>
            ) : null}
            <div className="mt-1.5 flex justify-end print:hidden">
              <QuotationOriginBadge leadName={quotation.leads?.name ?? null} />
            </div>
          </div>
        </div>

        <div className="px-1">
          <p className="text-xs font-medium text-text-muted">{t("sales.invoice.billedTo")}</p>
          <p className="text-sm font-semibold text-text">{quotation.customers?.name}</p>
          <p className="text-sm text-text-muted">{quotation.customers?.mobile}</p>
        </div>

        <div className="overflow-x-auto rounded-subcard border border-border">
          <table className="w-full min-w-[420px] text-sm">
            <thead className="bg-surface-alt text-text-muted">
              <tr>
                <th className="px-3 py-2 text-left font-medium">{t("sales.invoice.item")}</th>
                <th className="px-3 py-2 text-right font-medium">{t("sales.invoice.qty")}</th>
                <th className="px-3 py-2 text-right font-medium">{t("sales.invoice.price")}</th>
                <th className="px-3 py-2 text-right font-medium">{t("sales.invoice.lineTotal")}</th>
              </tr>
            </thead>
            <tbody>
              {quotation.quotation_items.map((item) => (
                <tr key={item.id} className="border-t border-border">
                  <td className="px-3 py-2 text-text">{item.itemName} {item.itemCode ? <span className="text-text-muted"> ({item.itemCode})</span> : null}</td>
                  <td className="px-3 py-2 text-right text-text">{item.qty}</td>
                  <td className="px-3 py-2 text-right text-text">{formatCurrency(item.price)}</td>
                  <td className="px-3 py-2 text-right font-medium text-text">{formatCurrency(item.qty * item.price)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <div className="ml-auto w-full max-w-64 space-y-1 px-1">
          {discount > 0 ? (
            <>
              <div className="flex justify-between text-sm text-text-muted">
                <span>{t("quotations.discount.subtotal")}</span>
                <span>{formatCurrency(subtotal)}</span>
              </div>
              <div className="flex justify-between text-sm text-success">
                <span>{t("quotations.discount.label")}</span>
                <span>− {formatCurrency(discount)}</span>
              </div>
              {quotation.discount_reason ? <p className="text-right text-xs text-text-muted">{quotation.discount_reason}</p> : null}
            </>
          ) : null}
          <div className="flex justify-between border-t border-border pt-1 text-base font-bold text-text">
            <span>{t("sales.invoice.netAmount")}</span>
            <span>{formatCurrency(quotation.total)}</span>
          </div>
          {gstBill ? (
            <>
              <div className="flex justify-between text-sm text-text-muted">
                <span>{gstLabel}</span>
                <span>{formatCurrency(gstBill.gst)}</span>
              </div>
              {!quotation.gst_inclusive && !quotation.no_gst ? (
                <div className="flex justify-between border-t border-border pt-1 text-base font-bold text-text">
                  <span>{t("sales.invoice.totalWithGst")}</span>
                  <span>{formatCurrency(gstBill.total)}</span>
                </div>
              ) : null}
            </>
          ) : null}
        </div>

        <div className="flex flex-wrap items-center justify-between gap-2 border-t border-border px-1 pt-3">
          <StatusDot tone={STATUS_TONE[quotation.status] ?? "neutral"} label={t(`quotations.status.${quotation.status}`)} />
          {quotation.lost_reason ? <p className="text-sm text-danger">{t("quotations.lostReasonLabel")}: {quotation.lost_reason}</p> : null}
        </div>
      </Card>

      {quotation.status === "open" ? (
        <div className="space-y-3 print:hidden">
          <div className="flex flex-wrap gap-2">
            <Button type="button" variant="accent" onClick={() => navigate(`/admin/sales/new?fromQuotation=${quotation.id}`)}>
              {t("quotations.convertButton")}
            </Button>
            <Button type="button" variant="outline" onClick={() => setShowLostForm((v) => !v)}>
              {t("quotations.markLostButton")}
            </Button>
            <Button type="button" variant="outline" onClick={() => setEditOpen(true)}>
              {t("quotations.editButton")}
            </Button>
          </div>
          {editOpen && orgId ? <QuotationEditDialog orgId={orgId} quotation={quotation} onClose={() => setEditOpen(false)} /> : null}
          {showLostForm ? (
            <Card className="gap-2 px-5">
              <Input value={lostReason} onChange={(e) => setLostReason(e.target.value)} placeholder={t("quotations.lostReasonPlaceholder")} />
              <Button
                type="button"
                variant="destructive"
                size="sm"
                disabled={!lostReason.trim() || markLost.isPending}
                onClick={() => markLost.mutate({ id: quotation.id, reason: lostReason })}
              >
                {t("quotations.confirmLost")}
              </Button>
            </Card>
          ) : null}
        </div>
      ) : null}

      {revisions.data && revisions.data.length > 0 ? (
        <Card className="gap-2 px-5 print:hidden">
          <p className="px-1 text-sm font-semibold text-text">{t("quotations.history.title")}</p>
          <ul className="space-y-2 px-1">
            {revisions.data.map((r) => (
              <li key={r.id} className="rounded-xl border border-border px-3.5 py-2.5 text-sm">
                <div className="flex flex-wrap items-baseline justify-between gap-2">
                  <span className="font-medium text-text">
                    {formatCurrency(r.old_total)} → {formatCurrency(r.new_total)}
                    {r.new_discount !== r.old_discount ? (
                      <span className="ml-2 text-xs font-normal text-text-muted">
                        {t("quotations.history.discountChange", { from: formatCurrency(r.old_discount), to: formatCurrency(r.new_discount) })}
                      </span>
                    ) : null}
                  </span>
                  <span className="text-xs text-text-muted">
                    {formatDate(r.edited_at)} · {r.editor?.full_name ?? t("quotations.history.unknownEditor")}
                  </span>
                </div>
                <p className="text-xs text-text-muted">{r.reason}</p>
              </li>
            ))}
          </ul>
        </Card>
      ) : null}
    </div>
  )
}
