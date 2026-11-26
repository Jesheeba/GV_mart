import { z } from "zod"

/** Messages are i18n keys — see lib/validation/customer.ts. */

export const amcPlanSchema = z.object({
  name: z.string().trim().min(2, "amc.errors.nameRequired").max(80),
  years: z.coerce.number().int().positive("amc.errors.yearsPositive"),
  price: z.coerce.number().min(0, "amc.errors.priceNonNegative"),
  visitsPerYear: z.coerce.number().int().positive("amc.errors.visitsPositive"),
  giftId: z.string().optional().or(z.literal("")),
  inclusions: z.string().optional().or(z.literal("")),
})
export type AmcPlanInput = z.infer<typeof amcPlanSchema>

export const sellAmcSchema = z.object({
  customerId: z.string().uuid("amc.errors.customerRequired"),
  productId: z.string().uuid("amc.errors.roProductRequired"),
  planId: z.string().uuid("amc.errors.planRequired"),
  startDate: z.string().min(1, "amc.errors.startDateRequired"),
  // gst-everywhere: the sale now bills a GST invoice, so how it was paid is asked (same keys as New Sale / Rent Out).
  paymentMethod: z.enum(["cash", "transfer", "upi"], { message: "sales.errors.paymentMethodRequired" }),
  txnId: z.string().trim().optional().or(z.literal("")),
  paymentDescription: z.string().trim().optional().or(z.literal("")),
  // No years field: a sale always uses the plan's own duration (shown as text in SellAmcPanel; the server falls back to
  // the plan's years when none is sent). The server parameter p_years stays for renewals.
})
  .refine((v) => v.paymentMethod !== "transfer" || !!v.txnId, { message: "sales.errors.txnIdRequired", path: ["txnId"] })
  .refine((v) => v.paymentMethod !== "transfer" || !!v.paymentDescription, { message: "sales.errors.paymentDescriptionRequired", path: ["paymentDescription"] })
// zod v4 input/output split (z.coerce.number()'s input is `unknown`, output
// is `number`) — same two-type pattern as lib/validation/settings.ts's
// SettingsFormInput/SettingsOutput, needed here for the first time now that
// this schema has a coerced field.
export type SellAmcFormInput = z.input<typeof sellAmcSchema>
export type SellAmcInput = z.output<typeof sellAmcSchema>
