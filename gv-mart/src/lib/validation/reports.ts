import { z } from "zod"

export const dateRangeSchema = z
  .object({
    from: z.string().min(1, "reports.errors.fromRequired"),
    to: z.string().min(1, "reports.errors.toRequired"),
  })
  .refine((v) => v.from <= v.to, { message: "reports.errors.rangeInvalid", path: ["to"] })
export type DateRangeInput = z.infer<typeof dateRangeSchema>
