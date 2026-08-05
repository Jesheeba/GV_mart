const ONES = [
  "", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine",
  "Ten", "Eleven", "Twelve", "Thirteen", "Fourteen", "Fifteen", "Sixteen", "Seventeen", "Eighteen", "Nineteen",
]
const TENS = ["", "", "Twenty", "Thirty", "Forty", "Fifty", "Sixty", "Seventy", "Eighty", "Ninety"]

function twoDigitsToWords(n: number): string {
  if (n < 20) return ONES[n]
  return TENS[Math.floor(n / 10)] + (n % 10 ? ` ${ONES[n % 10]}` : "")
}

/** 0-999 → words, with "and" between the hundreds and the remainder (e.g. 154 → "One Hundred and Fifty Four"). This is the only group that can carry a hundreds digit in Indian numbering, so it's the only place "and" belongs. */
function hundredGroupToWords(n: number): string {
  const hundreds = Math.floor(n / 100)
  const rest = n % 100
  if (!hundreds) return twoDigitsToWords(rest)
  const hundredsWord = `${ONES[hundreds]} Hundred`
  return rest ? `${hundredsWord} and ${twoDigitsToWords(rest)}` : hundredsWord
}

/** Indian numbering (crore/lakh/thousand/hundred) integer → words, e.g. 354000 → "Three Lakh Fifty Four Thousand". */
function integerToWords(n: number): string {
  if (n === 0) return "Zero"
  const crore = Math.floor(n / 1_00_00_000)
  const lakh = Math.floor((n % 1_00_00_000) / 1_00_000)
  const thousand = Math.floor((n % 1_00_000) / 1_000)
  const hundred = n % 1_000

  const segments: string[] = []
  if (crore) segments.push(`${twoDigitsToWords(crore)} Crore`)
  if (lakh) segments.push(`${twoDigitsToWords(lakh)} Lakh`)
  if (thousand) segments.push(`${twoDigitsToWords(thousand)} Thousand`)
  if (hundred) segments.push(hundredGroupToWords(hundred))
  return segments.join(" ")
}

/** "Rupees Three Thousand Only" / "Rupees Three Thousand Five Hundred and Forty Only" for bill/invoice printouts. */
export function amountInWords(amount: number): string {
  const rupees = Math.floor(Math.round(amount * 100) / 100)
  const paise = Math.round((amount - rupees) * 100)

  if (paise === 0) return `Rupees ${integerToWords(rupees)} Only`
  return `Rupees ${integerToWords(rupees)} and Paise ${integerToWords(paise)} Only`
}
