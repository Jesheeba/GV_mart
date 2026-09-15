import { z } from "zod"

/** Messages are i18n keys — see lib/validation/customer.ts. */

export const rentOutSchema = z.object({
  customerId: z.string().uuid("rentals.errors.customerRequired"),
  productId: z.string().uuid("rentals.errors.productRequired"),
  planId: z.string().uuid("rentals.errors.planRequired"),
  addressId: z.string().uuid("rentals.errors.addressRequired"),
  startDate: z.string().min(1, "rentals.errors.startDateRequired"),
  paymentMethod: z.enum(["cash", "transfer", "upi"]),
  txnId: z.string().optional().or(z.literal("")),
  paymentDescription: z.string().optional().or(z.literal("")),
})
export type RentOutInput = z.infer<typeof rentOutSchema>
