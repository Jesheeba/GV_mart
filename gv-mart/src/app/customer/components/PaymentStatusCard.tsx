import { useTranslation } from "react-i18next"
import { CheckCircle2, CreditCard } from "lucide-react"
import { Card } from "@/components/ui/card"
import { Button } from "@/components/ui/button"
import { PaymentQRCode } from "./PaymentQRCode"
import { useCustomerPaymentSettings } from "@/hooks/usePaymentSettings"
import { usePaymentStatus } from "@/hooks/usePaymentStatus"
import type { Enums } from "@/types/database"

/**
 * Customer-facing QR payment screen — fetches the org's live payment
 * settings and renders a dynamic QR, then flips to "confirmed" the moment
 * the technician records payment (invoices realtime, see usePaymentStatus).
 * Rendered by CustomerBookingDetailPage immediately before CompletionOtpCard
 * — the completion code only ever appears once this resolves to "paid"
 * (server-enforced by generate_visit_otp's payment gate).
 */
export function PaymentStatusCard({
  orgId,
  invoiceId,
  invoiceTotal,
  initialPaymentStatus,
}: {
  orgId: string
  invoiceId: string
  invoiceTotal: number
  initialPaymentStatus: Enums<"payment_status">
}) {
  const { t } = useTranslation()
  const { data: paymentSettings, isLoading } = useCustomerPaymentSettings(orgId)
  const { paymentStatus, connectionState } = usePaymentStatus(invoiceId, initialPaymentStatus)

  if (isLoading) {
    return <div className="h-40 animate-pulse rounded-card border border-border bg-surface" />
  }

  if (!paymentSettings || !paymentSettings.payment_enabled) {
    return (
      <Card className="gap-2 lg:px-5">
        <div className="flex items-center gap-2 px-1">
          <CreditCard className="size-4 text-text-muted" />
          <h2 className="text-sm font-semibold text-text">{t("customerApp.bookingDetail.payment.title")}</h2>
        </div>
        <p className="px-1 text-sm text-text-muted">{t("customerApp.bookingDetail.payment.unavailable")}</p>
      </Card>
    )
  }

  if (paymentStatus === "paid") {
    return (
      <Card className="gap-2 lg:px-5">
        <div className="flex items-center gap-2 px-1">
          <CreditCard className="size-4 text-text-muted" />
          <h2 className="text-sm font-semibold text-text">{t("customerApp.bookingDetail.payment.title")}</h2>
        </div>
        <p className="flex items-center gap-1.5 px-1 text-sm text-success">
          <CheckCircle2 className="size-4" /> {t("customerApp.bookingDetail.payment.confirmed")}
        </p>
      </Card>
    )
  }

  return (
    <Card className="gap-3 lg:px-5">
      <div className="flex items-center gap-2 px-1">
        <CreditCard className="size-4 text-text-muted" />
        <h2 className="text-sm font-semibold text-text">{t("customerApp.bookingDetail.payment.title")}</h2>
      </div>
      <PaymentQRCode
        upiId={paymentSettings.upi_id}
        merchantName={paymentSettings.merchant_name}
        amount={invoiceTotal}
        invoiceNumber={invoiceId}
      />
      <p className="px-1 text-center text-xs text-text-muted">{t("customerApp.bookingDetail.payment.waitingHint")}</p>
      {connectionState === "reconnecting" ? (
        <Button type="button" variant="outline" size="sm" className="mx-auto" onClick={() => window.location.reload()}>
          {t("common.reload")}
        </Button>
      ) : null}
    </Card>
  )
}
