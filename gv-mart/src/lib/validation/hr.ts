import { z } from "zod"

/** Messages are i18n keys, resolved via t() at the call site — see lib/validation/service.ts. */

export const periodMonthSchema = z.string().regex(/^\d{4}-\d{2}$/, "hr.errors.periodRequired")

export const logRewardSchema = z.object({
  category: z.enum(["attendance", "highest_review", "highest_revenue"], { message: "hr.errors.categoryRequired" }),
  winnerId: z.string().uuid("hr.errors.winnerRequired"),
  note: z.string().trim().max(300).optional().or(z.literal("")),
})
export type LogRewardFormInput = z.infer<typeof logRewardSchema>
