import QRCode from "react-qr-code"
import { generateUpiUri } from "@/lib/upi"
import { formatCurrency } from "@/lib/sale-calc"

/** Dynamic UPI QR — the destination always comes from the caller's live payment_settings row, never hardcoded. */
export function PaymentQRCode({
  upiId,
  merchantName,
  amount,
  invoiceNumber,
}: {
  upiId: string
  merchantName: string
  amount: number
  invoiceNumber: string
}) {
  const uri = generateUpiUri({ upiId, merchantName, amount, invoiceNumber })

  return (
    <div className="flex flex-col items-center gap-2">
      <div className="rounded-2xl border border-border bg-white p-4">
        <QRCode value={uri} size={200} />
      </div>
      <p className="text-center text-sm font-semibold text-text">{merchantName}</p>
      <p className="text-center text-xs text-text-muted">{upiId}</p>
      <p className="text-center text-lg font-bold text-text">{formatCurrency(amount)}</p>
    </div>
  )
}
