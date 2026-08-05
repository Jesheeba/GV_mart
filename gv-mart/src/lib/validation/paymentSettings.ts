import { z } from "zod"
import { UPI_ID_REGEX } from "@/lib/upi"

/** Mirrors the DB CHECK constraint on payment_settings.upi_id (20260806091000_payment_settings.sql) so the form fails fast before the request reaches Postgres. */
export const paymentSettingsSchema = z.object({
  merchant_name: z.string().trim().min(1, "paymentSettings.errors.merchantNameRequired"),
  upi_id: z.string().trim().regex(UPI_ID_REGEX, "paymentSettings.errors.upiIdInvalid"),
  phone_number: z.string().trim().optional().or(z.literal("")),
  payment_enabled: z.boolean(),
})

export type PaymentSettingsInput = z.infer<typeof paymentSettingsSchema>
