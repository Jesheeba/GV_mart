import { useTranslation } from "react-i18next"
import { useNavigate, useParams } from "react-router-dom"
import { MessageCircle, Printer } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { StatusDot } from "@/components/shared/StatusDot"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { useProfile } from "@/hooks/useProfile"
import { useInvoice, useInvoiceExtras, useOrganization } from "@/hooks/useSales"
import { formatCurrency } from "@/lib/sale-calc"
import type { StatusTone } from "@/components/shared/StatusDot"

const PAYMENT_STATUS_TONE: Record<string, StatusTone> = { paid: "success", partial: "warning", due: "danger" }

function toWhatsappLink(mobile: string, message: string) {
  const digits = mobile.replace(/\D/g, "")
  const withCountryCode = digits.length === 10 ? `91${digits}` : digits
  return `https://wa.me/${withCountryCode}?text=${encodeURIComponent(message)}`
}

export function InvoicePage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { id } = useParams<{ id: string }>()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: invoice, isLoading, isError, refetch } = useInvoice(orgId, id)
  const { data: org } = useOrganization(orgId)
  const { data: extras } = useInvoiceExtras(id)

  if (isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError || !invoice) {
    return <FullPageError message={t("sales.invoice.loadFailed")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  const withoutGst = invoice.subtotal - invoice.discount
  const paymentTone = PAYMENT_STATUS_TONE[invoice.payment_status] ?? "neutral"

  // Cost/margin tracking (stage 1) — cost is a snapshot taken at sale time
  // (see _sale_create_line_invoice / create_service_invoice), null when the
  // item had no cost_price set yet. Profit only sums lines with a known
  // cost — a missing cost is surfaced as a count, never folded in as 0
  // (that would silently overstate profit).
  const itemsMissingCost = invoice.invoice_items.filter((it) => it.cost == null).length
  const invoiceProfit = invoice.invoice_items
    .filter((it) => it.cost != null)
    .reduce((sum, it) => sum + (it.qty * it.price - it.discount - it.qty * (it.cost ?? 0)), 0)

  return (
    <div className="mx-auto max-w-3xl space-y-4 pt-2">
      <div className="flex flex-wrap items-center justify-between gap-2 print:hidden">
        <Button type="button" variant="outline" onClick={() => navigate(-1)}>
          {t("sales.newSale.back")}
        </Button>
        <div className="flex items-center gap-2">
          <Button type="button" variant="outline" onClick={() => window.print()}>
            <Printer className="size-4" />
            {t("sales.invoice.print")}
          </Button>
          <Button
            variant="accent"
            nativeButton={false}
            render={
              <a
                href={toWhatsappLink(
                  invoice.customers?.mobile ?? "",
                  t("sales.invoice.whatsappMessage", { id: invoice.id.slice(0, 8), total: formatCurrency(invoice.total) })
                )}
                target="_blank"
                rel="noreferrer"
              />
            }
          >
            <MessageCircle className="size-4" />
            {t("sales.invoice.shareWhatsapp")}
          </Button>
        </div>
      </div>

      <Card className="gap-4 px-5">
        <div className="flex items-start justify-between border-b border-border px-1 pb-3">
          <div>
            <p className="text-lg font-bold text-text">{org?.name ?? t("common.appName")}</p>
            {org?.gst_no ? <p className="text-xs text-text-muted">{t("sales.invoice.gstNo", { gst: org.gst_no })}</p> : null}
          </div>
          <div className="text-right">
            <p className="text-sm font-semibold text-text">{t("sales.invoice.invoiceNo", { id: invoice.id.slice(0, 8).toUpperCase() })}</p>
            <p className="text-xs text-text-muted">{new Date(invoice.created_at).toLocaleDateString("en-IN")}</p>
            <p className="text-xs text-text-muted">{t(`sales.invoice.type.${invoice.type}`)}</p>
          </div>
        </div>

        <div className="px-1">
          <p className="text-xs font-medium text-text-muted">{t("sales.invoice.billedTo")}</p>
          <p className="text-sm font-semibold text-text">{invoice.customers?.name}</p>
          <p className="text-sm text-text-muted">{invoice.customers?.mobile}</p>
        </div>

        {invoice.invoice_items.length > 0 ? (
          <div className="overflow-hidden rounded-subcard border border-border">
            <table className="w-full text-sm">
              <thead className="bg-surface-alt text-text-muted">
                <tr>
                  <th className="px-3 py-2 text-left font-medium">{t("sales.invoice.item")}</th>
                  <th className="px-3 py-2 text-right font-medium">{t("sales.invoice.qty")}</th>
                  <th className="px-3 py-2 text-right font-medium">{t("sales.invoice.price")}</th>
                  <th className="px-3 py-2 text-right font-medium">{t("sales.invoice.lineDiscount")}</th>
                  <th className="px-3 py-2 text-right font-medium">{t("sales.invoice.lineTotal")}</th>
                  <th className="px-3 py-2 text-right font-medium">{t("sales.invoice.lineProfit")}</th>
                </tr>
              </thead>
              <tbody>
                {invoice.invoice_items.map((item) => (
                  <tr key={item.id} className="border-t border-border">
                    <td className="px-3 py-2 text-text">{item.itemName}</td>
                    <td className="px-3 py-2 text-right text-text">{item.qty}</td>
                    <td className="px-3 py-2 text-right text-text">{formatCurrency(item.price)}</td>
                    <td className="px-3 py-2 text-right text-text-muted">{item.discount > 0 ? `−${formatCurrency(item.discount)}` : "—"}</td>
                    <td className="px-3 py-2 text-right font-medium text-text">{formatCurrency(item.qty * item.price - item.discount)}</td>
                    <td className="px-3 py-2 text-right text-text-muted">
                      {item.cost != null ? formatCurrency(item.qty * item.price - item.discount - item.qty * item.cost) : t("sales.invoice.costNotSet")}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <p className="px-1 text-sm text-text-muted">{t("sales.invoice.noLineItemsNote")}</p>
        )}

        <div className="ml-auto w-full max-w-64 space-y-1 px-1">
          <div className="flex justify-between text-sm text-text">
            <span>{t("sales.summary.subtotal")}</span>
            <span>{formatCurrency(invoice.subtotal)}</span>
          </div>
          {invoice.discount > 0 ? (
            <div className="flex justify-between text-sm text-danger">
              <span>{t("sales.summary.discount")}</span>
              <span>−{formatCurrency(invoice.discount)}</span>
            </div>
          ) : null}
          <div className="flex justify-between text-sm text-text-muted">
            <span>{t("sales.invoice.totalWithoutGst")}</span>
            <span>{formatCurrency(withoutGst)}</span>
          </div>
          <div className="flex justify-between text-sm text-text-muted">
            <span>{t("sales.invoice.gstAmount")}</span>
            <span>{formatCurrency(invoice.gst)}</span>
          </div>
          <div className="flex justify-between border-t border-border pt-1 text-base font-bold text-text">
            <span>{t("sales.invoice.totalWithGst")}</span>
            <span>{formatCurrency(invoice.total)}</span>
          </div>
          {invoice.invoice_items.length > 0 ? (
            <div className="flex justify-between border-t border-border pt-1 text-sm font-semibold text-success">
              <span>{t("sales.invoice.profit")}</span>
              <span>{formatCurrency(invoiceProfit)}</span>
            </div>
          ) : null}
        </div>

        {itemsMissingCost > 0 ? (
          <p className="px-1 text-xs text-text-muted">{t("sales.invoice.profitMissingCostNote", { count: itemsMissingCost })}</p>
        ) : null}

        <div className="flex flex-wrap items-center justify-between gap-2 border-t border-border px-1 pt-3">
          <div className="text-sm text-text">
            <p>
              {t("sales.invoice.paymentMethod")}: <span className="font-medium">{invoice.payment_method ? t(`sales.payment.${invoice.payment_method}`) : "—"}</span>
            </p>
            {invoice.txn_id ? <p className="text-xs text-text-muted">{t("sales.payment.txnId")}: {invoice.txn_id}</p> : null}
            {invoice.payment_description ? <p className="text-xs text-text-muted">{invoice.payment_description}</p> : null}
          </div>
          <StatusDot tone={paymentTone} label={t(`sales.invoice.paymentStatus.${invoice.payment_status}`)} />
        </div>

        {invoice.gifts ? (
          <p className="px-1 text-sm text-success">{t("sales.summary.giftApplied", { gift: invoice.gifts.name })}</p>
        ) : null}
      </Card>

      {extras && (extras.warranties.length > 0 || extras.tickets.length > 0 || extras.amcContract) ? (
        <Card className="gap-2 px-5">
          <p className="px-1 text-sm font-semibold text-text">{t("sales.invoice.generatedTitle")}</p>
          {extras.warranties.map((w) => (
            <p key={w.id} className="px-1 text-sm text-text-muted">
              {t("sales.invoice.warrantyLine", { date: new Date(w.expiry_date).toLocaleDateString("en-IN") })}
            </p>
          ))}
          {extras.tickets.map((tk) => (
            <p key={tk.id} className="px-1 text-sm text-text-muted">
              {t("sales.invoice.ticketLine", { status: t(`sales.invoice.ticketStatus.${tk.status}`) })}
            </p>
          ))}
          {extras.amcContract ? (
            <p className="px-1 text-sm text-text-muted">
              {t("sales.invoice.amcLine", {
                plan: (extras.amcContract as { amc_plans: { name: string } | null }).amc_plans?.name ?? "—",
                date: new Date(extras.amcContract.expiry_date).toLocaleDateString("en-IN"),
              })}
            </p>
          ) : null}
        </Card>
      ) : null}
    </div>
  )
}
