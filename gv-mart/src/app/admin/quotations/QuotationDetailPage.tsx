import { useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate, useParams } from "react-router-dom"
import { Printer } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { StatusDot, type StatusTone } from "@/components/shared/StatusDot"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { useProfile } from "@/hooks/useProfile"
import { useMarkQuotationLost, useQuotation } from "@/hooks/useQuotations"
import { useOrganization } from "@/hooks/useSales"
import { formatCurrency } from "@/lib/sale-calc"
import { amountInWords } from "@/lib/amount-in-words"

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
  const markLost = useMarkQuotationLost()
  const [lostReason, setLostReason] = useState("")
  const [showLostForm, setShowLostForm] = useState(false)

  if (isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError || !quotation) {
    return <FullPageError message={t("quotations.error.loadFailed")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  const quotationNo = quotation.id.slice(0, 8).toUpperCase()

  return (
    <div className="mx-auto max-w-2xl space-y-4 pt-2">
      <div className="flex items-center justify-between print:hidden">
        <Button type="button" variant="outline" onClick={() => navigate(-1)}>
          {t("sales.newSale.back")}
        </Button>
        <Button type="button" variant="outline" onClick={() => window.print()}>
          <Printer className="size-4" />
          {t("quotations.print")}
        </Button>
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
                      <td className={CELL}>{new Date(quotation.created_at).toLocaleDateString("en-IN")}</td>
                    </tr>
                    {quotation.valid_until ? (
                      <tr>
                        <td className={CELL}>{t("quotations.table.validUntil")}</td>
                        <td className={CELL}>{new Date(quotation.valid_until).toLocaleDateString("en-IN")}</td>
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
                <td className={CELL}>{item.itemName}</td>
                <td className={`${CELL} text-right`}>{item.qty}</td>
                <td className={`${CELL} text-right`}>{item.price.toFixed(2)}</td>
                <td className={`${CELL} text-right`}>{(item.qty * item.price).toFixed(2)}</td>
              </tr>
            ))}
            <tr>
              <td colSpan={4} className={`${CELL} text-right`}>
                <b>{t("sales.invoice.netAmount")}</b>
              </td>
              <td className={`${CELL} text-right`}>
                <b>{quotation.total.toFixed(2)}</b>
              </td>
            </tr>
            <tr>
              <td colSpan={5} className={CELL}>
                <b>{amountInWords(quotation.total)}</b>
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
            <p className="text-xs text-text-muted">{new Date(quotation.created_at).toLocaleDateString("en-IN")}</p>
            {quotation.valid_until ? (
              <p className="text-xs text-text-muted">
                {t("quotations.table.validUntil")}: {new Date(quotation.valid_until).toLocaleDateString("en-IN")}
              </p>
            ) : null}
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
                  <td className="px-3 py-2 text-text">{item.itemName}</td>
                  <td className="px-3 py-2 text-right text-text">{item.qty}</td>
                  <td className="px-3 py-2 text-right text-text">{formatCurrency(item.price)}</td>
                  <td className="px-3 py-2 text-right font-medium text-text">{formatCurrency(item.qty * item.price)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <div className="ml-auto w-full max-w-64 space-y-1 px-1">
          <div className="flex justify-between border-t border-border pt-1 text-base font-bold text-text">
            <span>{t("sales.invoice.netAmount")}</span>
            <span>{formatCurrency(quotation.total)}</span>
          </div>
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
          </div>
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
    </div>
  )
}
