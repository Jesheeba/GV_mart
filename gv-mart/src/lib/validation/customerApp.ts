import { z } from "zod"

/**
 * Zod schemas for the Customer App (Phase 8). Messages are i18n *keys*, not
 * literal English text — see lib/validation/customer.ts for why (forms
 * render `t(errors.field.message)` to resolve them).
 */

// ── CUST-08 Profile: address form (mirrors ADM-04's address step) ────────
export const customerAddressSchema = z.object({
  doorNo: z.string().trim().min(1, "customerApp.errors.doorNoRequired"),
  flatNo: z.string().trim().optional().or(z.literal("")),
  streetCross: z.string().trim().optional().or(z.literal("")),
  area: z.string().trim().min(1, "customerApp.errors.areaRequired"),
  pincode: z.string().regex(/^\d{6}$/, "customerApp.errors.pincodeInvalid"),
  landmark: z.string().trim().optional().or(z.literal("")),
  district: z.string().trim().optional().or(z.literal("")),
  state: z.string().trim().optional().or(z.literal("")),
  addressType: z.enum(["residential", "commercial"]),
  ownership: z.enum(["own", "rental"]),
  // Root-cause fix (technician map location bug): this address form never
  // captured coordinates at all — every customer-self-added address had
  // lat/lng permanently null, so the technician's map had nothing to plot
  // and distance/ETA couldn't be computed. Optional here too (same shape as
  // ADM-04's admin-side addressStepSchema, for the same reason: a schema-
  // level requirement fights react-hook-form's `undefined` default before a
  // pin is ever set) — AddressForm.tsx enforces "must confirm a pin" itself
  // by disabling Save until lat/lng are present, which is the real gate.
  lat: z.number().min(-90).max(90).optional(),
  lng: z.number().min(-180).max(180).optional(),
})
export type CustomerAddressInput = z.infer<typeof customerAddressSchema>

// ── CUST-08 Profile: family member (mirrors ADM-04, max 5 enforced by the
// existing DB trigger + a client-side count check in the hook) ───────────
const MOBILE_REGEX = /^[6-9]\d{9}$/
export const customerMemberSchema = z.object({
  name: z.string().trim().min(2, "customerApp.errors.nameRequired"),
  mobile: z.string().regex(MOBILE_REGEX, "customerApp.errors.mobileInvalid"),
})
export type CustomerMemberInput = z.infer<typeof customerMemberSchema>

// ── CUST-02 Service Booking stepper ───────────────────────────────────────
// B1 (Build Order Step 4): a single window the customer marked as NOT
// available, "HH:MM" strings from native time inputs. Mirrors
// lib/validation/service.ts's unavailableWindowSchema (the admin-side
// equivalent) — kept as a separate declaration rather than a shared import
// since the two validation files are intentionally independent per-surface
// (see this file's header).
const unavailableWindowSchema = z
  .object({
    start: z.string().min(1, "customerApp.bookService.availableWindowInvalid"),
    end: z.string().min(1, "customerApp.bookService.availableWindowInvalid"),
  })
  .refine((v) => v.start < v.end, { message: "customerApp.bookService.availableWindowInvalid", path: ["end"] })

export const serviceBookingSchema = z
  .object({
    addressId: z.string().uuid("customerApp.errors.addressRequired"),
    productId: z.string().uuid().nullable(),
    brandId: z.string().uuid().nullable(),
    modelId: z.string().uuid().nullable(),
    nameOfComplaint: z.string().trim().min(3, "customerApp.errors.complaintRequired"),
    natureOfComplaint: z.string().trim().optional().or(z.literal("")),
    photoUrl: z.string().trim().optional().or(z.literal("")),
    priority: z.enum(["very_urgent", "urgent", "normal"]),
    appointmentMode: z.enum(["always", "datetime"]),
    // Holds a DATE ("YYYY-MM-DD") when appointmentMode is 'datetime' — B1
    // replaces exact-time picking with date-only + unavailable-windows.
    scheduledAt: z.string().optional().or(z.literal("")),
    // "any" = full working-hours window (B1's "Any time"); "custom" = the
    // windows below are the customer's marked NOT-available times.
    windowMode: z.enum(["any", "custom"]),
    unavailableWindows: z.array(unavailableWindowSchema),
  })
  // v2.2 §6.4: "datetime" mode must have an actual date picked — mirrors
  // service.ts's complaintAppointmentStepSchema (the admin-side equivalent).
  .refine((v) => v.appointmentMode === "always" || !!v.scheduledAt, {
    message: "customerApp.errors.scheduledAtRequired",
    path: ["scheduledAt"],
  })
export type ServiceBookingInput = z.infer<typeof serviceBookingSchema>

// ── CUST-04 Product Enquiry / CUST-05 Spare Enquiry ───────────────────────
export const enquirySchema = z.object({
  description: z.string().trim().min(3, "customerApp.errors.descriptionRequired"),
  photoUrl: z.string().trim().optional().or(z.literal("")),
  // Product Enquiry rebuild (2026-08-04) Phase 4 — structured per-product
  // quote requests from a product detail page; both optional so the
  // existing free-text-only "no specific product" form keeps working.
  productId: z.string().uuid().optional(),
  qty: z.number().int().min(1).optional(),
})
export type EnquiryInput = z.infer<typeof enquirySchema>

// ── Product Enquiry rebuild (2026-08-04) Phase 4 — Request Callback ──────
export const callbackRequestSchema = z.object({
  scheduledDate: z.string().min(1, "customerApp.errors.callbackDateRequired"),
  slotId: z.string().uuid("customerApp.errors.callbackSlotRequired"),
  note: z.string().trim().optional().or(z.literal("")),
})
export type CallbackRequestInput = z.infer<typeof callbackRequestSchema>

// ── CUST-06 register-via-QR ───────────────────────────────────────────────
export const registerProductSchema = z.object({
  productId: z.string().uuid("customerApp.errors.productRequired"),
  serialNo: z.string().trim().optional().or(z.literal("")),
  purchaseDate: z.string().trim().optional().or(z.literal("")),
})
export type RegisterProductInput = z.infer<typeof registerProductSchema>
