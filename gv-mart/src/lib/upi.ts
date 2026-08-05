/** Mirrors the CHECK constraint on payment_settings.upi_id (20260806091000_payment_settings.sql, corrected by 20260806095000) — VPA format handle@bank. */
export const UPI_ID_REGEX = /^[\w.-]{2,64}@[a-zA-Z]{2,64}$/

/** Builds a `upi://pay?...` deep link for a dynamic QR — payment destination always comes from the caller, never hardcoded. */
export function generateUpiUri({
  upiId,
  merchantName,
  amount,
  invoiceNumber,
}: {
  upiId: string
  merchantName: string
  amount: number
  invoiceNumber: string
}): string {
  const params = new URLSearchParams({
    pa: upiId,
    pn: merchantName,
    am: amount.toFixed(2),
    cu: "INR",
    tn: `Invoice ${invoiceNumber}`,
  })
  return `upi://pay?${params.toString()}`
}
