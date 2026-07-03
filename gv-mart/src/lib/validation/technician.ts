import { z } from "zod"

// Indian mobile: 10 digits, starts 6-9 — same rule as lib/validation/customer.ts.
const MOBILE_REGEX = /^[6-9]\d{9}$/

/**
 * Messages are i18n *keys*, not literal English text (see
 * lib/validation/customer.ts for why) — forms render `t(errors.field.message)`.
 */

// TECH-01 Attendance — the three ticks are sequential (Affirmation -> Pledge
// -> Meeting per v2.2 §6.8) but modeled as independent booleans; the UI
// enforces the order, this schema just validates the final payload.
export const attendanceSchema = z.object({
  selfieDataUrl: z.string().min(1, "technician.errors.selfieRequired"),
  affirmation: z.boolean(),
  pledge: z.boolean(),
  meeting: z.boolean(),
})
export type AttendanceInput = z.infer<typeof attendanceSchema>

// TECH-02 Spare receipt
export const spareHandoverSignSchema = z.object({
  techSignDataUrl: z.string().min(1, "technician.errors.signatureRequired"),
})
export type SpareHandoverSignInput = z.infer<typeof spareHandoverSignSchema>

// TECH-07 step 6 — Charges / discount
export const chargesStepSchema = z.object({
  serviceCharge: z.coerce.number().min(0, "technician.errors.nonNegative"),
  discountPercent: z.coerce.number().min(0, "technician.errors.nonNegative").max(100),
})
export type ChargesStepInput = z.infer<typeof chargesStepSchema>

/** Mirrors settings.discount_admin_max / discount_tech_max, same shape as lib/validation/sale.ts. */
export function isDiscountBlocked(percent: number, adminMax: number) {
  return percent < 0 || percent > adminMax
}
export function discountNeedsApproval(percent: number, techMax: number, adminMax: number) {
  return percent > techMax && percent <= adminMax
}

// TECH-07 step 7 — RO checklist
export const roChecklistSchema = z.object({
  tdsBefore: z.coerce.number().min(0, "technician.errors.nonNegative").optional(),
  tdsAfter: z.coerce.number().min(0, "technician.errors.nonNegative").optional(),
  tankCleaned: z.boolean().nullable(),
  productExplained: z.boolean().nullable(),
  clientName: z.string().trim().min(1, "technician.errors.clientNameRequired"),
})
export type RoChecklistInput = z.infer<typeof roChecklistSchema>

// TECH-07 step 10 — Payment. Same transfer-requires-txn+description rule as
// lib/validation/sale.ts's paymentDetailsSchema (v2.2 §6.1, "NO gateway" in
// staff billing).
export const servicePaymentSchema = z
  .object({
    method: z.enum(["cash", "transfer"]),
    txnId: z.string().trim().max(120).optional().or(z.literal("")),
    description: z.string().trim().max(200).optional().or(z.literal("")),
  })
  .refine((v) => v.method !== "transfer" || !!v.txnId, {
    message: "technician.errors.txnIdRequired",
    path: ["txnId"],
  })
  .refine((v) => v.method !== "transfer" || !!v.description, {
    message: "technician.errors.paymentDescriptionRequired",
    path: ["description"],
  })
export type ServicePaymentInput = z.infer<typeof servicePaymentSchema>

// TECH-07 "Generate Enquiry"
export const enquiryLeadSchema = z.object({
  name: z.string().trim().min(2, "technician.errors.nameRequired"),
  mobile: z.string().regex(MOBILE_REGEX, "technician.errors.mobileInvalid").optional().or(z.literal("")),
  enquiryType: z.enum(["online", "price", "quality", "customization", "water_premium", "budget"]),
  note: z.string().trim().max(500).optional().or(z.literal("")),
})
export type EnquiryLeadInput = z.infer<typeof enquiryLeadSchema>

// TECH-08 Rating
export const ratingSchema = z
  .object({
    stars: z.coerce.number().min(1, "technician.errors.starsRequired").max(5),
    review: z.string().trim().max(500).optional().or(z.literal("")),
    lowRatingReason: z.string().trim().max(300).optional().or(z.literal("")),
  })
  .refine((v) => v.stars >= 3 || !!v.lowRatingReason, {
    message: "technician.errors.lowRatingReasonRequired",
    path: ["lowRatingReason"],
  })
export type RatingInput = z.infer<typeof ratingSchema>

/** v2.2 Design Deltas #3 / settings.review_link_min_stars: Google review link shows only at/above the admin-set threshold. */
export function showsGoogleReviewLink(stars: number, minStars: number) {
  return stars >= minStars
}
