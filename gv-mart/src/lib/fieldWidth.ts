/**
 * Fitted widths for short-value inputs (input-density, 2026-11-26).
 * Inputs stay h-10; only the width shrinks. Pass via className on <Input>:
 * tailwind-merge in cn() lets these override the primitive's `w-full`.
 * amount (w-32, 128px) fits "10,00,000.00" at text-sm with the input padding.
 */
export const FIELD_W = {
  qty: "w-20",
  reading: "w-24",
  pincode: "w-28",
  otp: "w-28",
  amount: "w-32",
  mobile: "w-40",
} as const

export type FieldWidthKey = keyof typeof FIELD_W

/** Hides the up/down stepper arrows on a type="number" input (owner, 2026-11-26: readings are typed, not stepped). */
export const NO_SPINNER =
  "[appearance:textfield] [&::-webkit-inner-spin-button]:appearance-none [&::-webkit-outer-spin-button]:appearance-none"
