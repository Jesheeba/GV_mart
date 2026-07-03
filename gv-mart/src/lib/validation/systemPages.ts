import { z } from "zod"

/** Messages are i18n keys, resolved via t() at the call site (matches lib/validation/service.ts convention). */

export const createTaskSchema = z.object({
  title: z.string().trim().min(3, "workspace.errors.titleRequired").max(200),
  dueDate: z.string().optional().or(z.literal("")),
})
export type CreateTaskFormInput = z.infer<typeof createTaskSchema>

export const createCampaignSchema = z.object({
  name: z.string().trim().min(3, "campaigns.errors.nameRequired").max(150),
  channel: z.string().trim().min(1, "campaigns.errors.channelRequired"),
  targetSegment: z.string().trim().max(200).optional().or(z.literal("")),
  startDate: z.string().optional().or(z.literal("")),
  endDate: z.string().optional().or(z.literal("")),
  message: z.string().trim().max(1000).optional().or(z.literal("")),
})
export type CreateCampaignFormInput = z.infer<typeof createCampaignSchema>

export const createReturnSchema = z.object({
  invoiceId: z.string().uuid("returns.errors.invoiceRequired"),
  itemType: z.enum(["product", "spare"], { message: "returns.errors.itemTypeRequired" }),
  itemId: z.string().uuid("returns.errors.itemRequired"),
  qty: z.number().int().positive("returns.errors.qtyPositive"),
  reason: z.string().trim().max(500).optional().or(z.literal("")),
  isReplacement: z.boolean(),
})
export type CreateReturnFormInput = z.infer<typeof createReturnSchema>
