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
})
export type SellAmcInput = z.infer<typeof sellAmcSchema>
