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

// Admin/customer booking-format parity (2026-08-03): mirrors the customer
// app's plain date + admin-configured appointment-slot pick (see
// lib/validation/customerApp.ts's serviceBookingSchema note on why the two
// validation files stay separate declarations) — replaces the old
// windowMode/unavailableWindows free-text builder. The "always"/anytime
// appointment mode was dropped from this form (2026-08-03 follow-up) so a
// date + slot is always required, matching the customer app's own flow,
// which never offered "always" either — 'always' remains a valid
// `appointment_mode` value everywhere it's already displayed/stored
// (TicketDetailPage, AppointmentsPage, TicketsListPage, etc.), only the
// admin's own New Complaint form stops creating new appointments with it.
export const complaintAppointmentStepSchema = z.object({
  // Holds a DATE ("YYYY-MM-DD").
  scheduledDate: z.string().min(1, "service.errors.scheduledAtRequired"),
  slotId: z.string().min(1, "customerApp.bookService.slotRequired"),
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
