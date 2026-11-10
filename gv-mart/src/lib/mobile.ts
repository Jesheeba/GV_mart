/**
 * Indian mobile helpers for the Edit Lead flow (#3, 2026-11-02).
 *
 * The rest of the app validates mobile numbers with a strict 10-digit regex
 * (`/^[6-9]\d{9}$/`, duplicated as-is in lib/validation/customer.ts,
 * lib/validation/customerApp.ts and lib/validation/technician.ts) but never
 * actually *normalizes* input — none of those forms strip a typed "+91",
 * "0091" or leading "0" before validating, so a customer who types
 * "+91 98765 43210" simply fails validation there today. There is no
 * existing normalization helper anywhere in src/ to reuse (checked
 * services/customers.ts, lib/whatsapp-link.ts — that one only *adds* a "91"
 * prefix for the wa.me link, it doesn't strip one on input).
 *
 * This file is therefore a new, narrowly-scoped helper for the Edit Lead
 * screen only — it does not touch the other three forms' existing literal
 * regexes, to keep this change additive and low-risk per the task's
 * "don't duplicate, but don't rewrite what already works" guidance.
 */

/** Same shape as every other mobile field in this codebase: 10 digits, starts 6-9. */
export const MOBILE_REGEX = /^[6-9]\d{9}$/

export type MobileNormalizeResult =
  | { ok: true; value: string }
  | { ok: false; reason: "empty" | "invalid" }

/**
 * Trims, strips all non-digit characters, then strips a leading "91"
 * country code (with or without a "+") or a single leading "0" trunk
 * prefix, and checks what remains is a valid 10-digit Indian mobile.
 *
 * Examples that all normalize to "9876543210":
 *   "+91 98765 43210", "0091-98765-43210", "098765 43210", " 9876543210 "
 */
export function normalizeIndianMobile(input: string | null | undefined): MobileNormalizeResult {
  const trimmed = (input ?? "").trim()
  if (!trimmed) return { ok: false, reason: "empty" }

  let digits = trimmed.replace(/\D/g, "")
  if (digits.length === 12 && digits.startsWith("91")) {
    digits = digits.slice(2)
  } else if (digits.length === 11 && digits.startsWith("0")) {
    digits = digits.slice(1)
  }

  if (!MOBILE_REGEX.test(digits)) return { ok: false, reason: "invalid" }
  return { ok: true, value: digits }
}

/** Convenience for optional fields (alternate mobile): blank input is valid and normalizes to null. */
export function normalizeOptionalIndianMobile(input: string | null | undefined): MobileNormalizeResult | { ok: true; value: null } {
  const trimmed = (input ?? "").trim()
  if (!trimmed) return { ok: true, value: null }
  return normalizeIndianMobile(trimmed)
}
