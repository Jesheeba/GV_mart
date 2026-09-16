/** wa.me deep-link builder — opens WhatsApp Web/app with the message
 * pre-filled, no server-side send. Originally InvoicePage-only; reused as-is
 * for the Quotation WhatsApp button (Item 8 Tier A, 2026-09-16) rather than
 * duplicated, since it's an exact copy. */
export function toWhatsappLink(mobile: string, message: string) {
  const digits = mobile.replace(/\D/g, "")
  const withCountryCode = digits.length === 10 ? `91${digits}` : digits
  return `https://wa.me/${withCountryCode}?text=${encodeURIComponent(message)}`
}
