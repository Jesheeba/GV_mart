import { z } from "zod"

/**
 * The New Sale wizard (ADM-05/06) is a cart builder, not a fixed-shape
 * form — react-hook-form's field-array model doesn't fit a dynamic
 * add/remove/edit cart well, so cart state lives in plain React state
 * (see NewSalePage) and these schemas validate the payment step and the
 * final submit payload only, matching the pattern of validating at the
 * server-action boundary (lib/validation/customer.ts's comment on why
 * messages are i18n keys applies here too).
 */
export const paymentDetailsSchema = z
  .object({
    method: z.enum(["cash", "transfer"]),
    txnId: z
      .string()
      .trim()
      .max(120)
      .optional()
      .or(z.literal("")),
    description: z
      .string()
      .trim()
      .max(200)
      .optional()
      .or(z.literal("")),
  })
  .refine((v) => v.method !== "transfer" || !!v.txnId, {
    message: "sales.errors.txnIdRequired",
    path: ["txnId"],
  })
  .refine((v) => v.method !== "transfer" || !!v.description, {
    message: "sales.errors.paymentDescriptionRequired",
    path: ["description"],
  })
export type PaymentDetailsInput = z.infer<typeof paymentDetailsSchema>

/** Mirrors the DB bound in `create_sale` (settings.discount_admin_max) — checked client-side for instant feedback, re-checked server-side as the source of truth. */
export function isDiscountBlocked(percent: number, adminMax: number) {
  return percent < 0 || percent > adminMax
}
/** 5–10% band (v2.2 §6.1): allowed, but flags an approvals row for a master to review. */
export function discountNeedsApproval(percent: number, techMax: number, adminMax: number) {
  return percent > techMax && percent <= adminMax
}
