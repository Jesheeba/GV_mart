import { z } from "zod"

/**
 * Messages are i18n *keys*, not literal English text — see
 * lib/validation/customer.ts for the convention (components resolve via t()).
 */

export const complaintCustomerStepSchema = z.object({
  customerId: z.string().uuid("service.errors.customerRequired"),
})
export type ComplaintCustomerStepInput = z.infer<typeof complaintCustomerStepSchema>

export const complaintEquipmentStepSchema = z.object({
  productId: z.string().uuid("service.errors.productRequired").optional().or(z.literal("")),
  brandId: z.string().uuid().optional().or(z.literal("")),
  modelId: z.string().uuid().optional().or(z.literal("")),
})
export type ComplaintEquipmentStepInput = z.infer<typeof complaintEquipmentStepSchema>

export const complaintDetailsStepSchema = z.object({
  nameOfComplaint: z.string().trim().min(3, "service.errors.nameOfComplaintRequired").max(200),
  natureOfComplaint: z.string().trim().max(500).optional().or(z.literal("")),
  priority: z.enum(["very_urgent", "urgent", "normal"], { message: "service.errors.priorityRequired" }),
})
export type ComplaintDetailsStepInput = z.infer<typeof complaintDetailsStepSchema>

export const complaintAppointmentStepSchema = z
  .object({
    mode: z.enum(["always", "datetime"], { message: "service.errors.modeRequired" }),
    scheduledAt: z.string().optional().or(z.literal("")),
    autoAssign: z.boolean(),
  })
  .refine((v) => v.mode === "always" || !!v.scheduledAt, {
    message: "service.errors.scheduledAtRequired",
    path: ["scheduledAt"],
  })
export type ComplaintAppointmentStepInput = z.infer<typeof complaintAppointmentStepSchema>

export const ticketFiltersSchema = z.object({
  status: z.string().optional(),
  priority: z.string().optional(),
  type: z.string().optional(),
  technicianId: z.string().optional(),
  date: z.string().optional(),
  area: z.string().optional(),
  search: z.string().optional(),
})
export type TicketFilters = z.infer<typeof ticketFiltersSchema>
