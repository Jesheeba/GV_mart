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

// Admin/customer booking-format parity (2026-10-24): the appointment step
// now mirrors the customer app's own free-form unavailable-time-range
// picker exactly (see lib/validation/customerApp.ts's serviceBookingSchema
// note on why the two validation files stay separate declarations), instead
// of the admin-configured appointment-slot pick this replaced. A date +
// window geometry (unavailableWindows, possibly empty) is required, same as
// BookServicePage.tsx. The "always"/anytime appointment mode remains
// unused by this form (dropped 2026-08-03) — 'always' stays a valid
// `appointment_mode` value everywhere it's already displayed/stored
// (TicketDetailPage, AppointmentsPage, TicketsListPage, etc.), only the
// admin's own New Complaint form never creates new appointments with it.
export const complaintAppointmentStepSchema = z.object({
  // Holds a DATE ("YYYY-MM-DD").
  scheduledDate: z.string().min(1, "service.errors.scheduledAtRequired"),
  unavailableWindows: z
    .array(z.object({ start: z.string(), end: z.string() }))
    .refine((windows) => windows.every((w) => w.end > w.start), "customerApp.bookService.unavailability.invalidRange"),
  autoAssign: z.boolean(),
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
