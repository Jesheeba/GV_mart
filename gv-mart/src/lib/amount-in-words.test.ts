import { describe, expect, it } from "vitest"
import { amountInWords } from "./amount-in-words"

describe("amountInWords", () => {
  it("formats a plain thousands amount", () => {
    expect(amountInWords(3000)).toBe("Rupees Three Thousand Only")
  })
  it("adds 'and' before the final hundred-group remainder", () => {
    expect(amountInWords(3540)).toBe("Rupees Three Thousand Five Hundred and Forty Only")
  })
  it("handles lakhs", () => {
    expect(amountInWords(354016)).toBe("Rupees Three Lakh Fifty Four Thousand Sixteen Only")
  })
  it("appends paise when present", () => {
    expect(amountInWords(100.5)).toBe("Rupees One Hundred and Paise Fifty Only")
  })
  it("handles zero", () => {
    expect(amountInWords(0)).toBe("Rupees Zero Only")
  })
})
