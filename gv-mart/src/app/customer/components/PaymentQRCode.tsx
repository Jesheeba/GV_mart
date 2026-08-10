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
        {/* fgColor mirrors --accent (src/index.css) — hardcoded literal, not
            var(--accent), matching this codebase's convention for
            theme-matched colors in non-Tailwind SVG/canvas contexts (see
            COLOR_ALERT/COLOR_ON_TIME in TechniciansMapPage.tsx). level="H"
            (highest error correction) compensates for the lower contrast of
            a colored code vs. plain black-on-white. */}
        <QRCode value={uri} size={200} fgColor="#f5612c" bgColor="#ffffff" level="H" />
      </div>
      <p className="text-center text-sm font-semibold text-text">{merchantName}</p>
      <p className="text-center text-xs text-text-muted">{upiId}</p>
      <p className="text-center text-lg font-bold text-text">{formatCurrency(amount)}</p>
    </div>
  )
}
