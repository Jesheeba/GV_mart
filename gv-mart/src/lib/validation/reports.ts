import { z } from "zod"

export const dateRangeSchema = z
  .object({
    from: z.string().min(1, "reports.errors.fromRequired"),
    to: z.string().min(1, "reports.errors.toRequired"),
  })
  .refine((v) => v.from <= v.to, { message: "reports.errors.rangeInvalid", path: ["to"] })
export type DateRangeInput = z.infer<typeof dateRangeSchema>

/** expense_category enum (supabase/migrations/20260701090000_extensions_and_enums.sql) — all 6 values. */
export const expenseCategories = ["marketing", "stationery", "salary", "petrol", "purchase", "other"] as const

export const createExpenseSchema = z.object({
  category: z.enum(expenseCategories, { message: "reports.errors.expenseCategoryRequired" }),
  amount: z.coerce.number().positive("reports.errors.expenseAmountPositive"),
  date: z.string().min(1, "reports.errors.expenseDateRequired"),
})
/** Pre-coercion shape (what the form fields hold — react-hook-form's generic), mirrors lib/validation/settings.ts's SettingsFormInput/Output split. */
export type CreateExpenseFormInput = z.input<typeof createExpenseSchema>
/** Post-coercion shape (what gets submitted to the API). */
export type CreateExpenseOutput = z.output<typeof createExpenseSchema>
