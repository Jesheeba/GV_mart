import { z } from "zod"

/** Messages are i18n keys — see lib/validation/customer.ts. */

export const leadSchema = z.object({
  name: z.string().trim().min(2, "leads.errors.nameRequired").max(120),
  mobile: z.string().trim().max(20).optional().or(z.literal("")),
  source: z.enum(["field", "customer_app", "whatsapp", "walk_in", "referral", "other"], {
    message: "leads.errors.sourceRequired",
  }),
  enquiryType: z.enum(["online", "price", "quality", "customization", "water_premium", "budget"]).optional().or(z.literal("")),
})
export type LeadInput = z.infer<typeof leadSchema>

export const leadActivitySchema = z.object({
  type: z.enum(["call", "note", "whatsapp", "meeting"], { message: "leads.errors.activityTypeRequired" }),
  note: z.string().trim().max(500).optional().or(z.literal("")),
})
export type LeadActivityInput = z.infer<typeof leadActivitySchema>

export const referralPointsSchema = z.object({
  customerId: z.string().uuid("leads.errors.customerRequired"),
  points: z.coerce.number().int().positive("leads.errors.pointsPositive"),
  reason: z.string().trim().max(200).optional().or(z.literal("")),
})
export type ReferralPointsInput = z.infer<typeof referralPointsSchema>

export const automationFlowSchema = z.object({
  trigger: z.enum(["online", "price", "quality", "customization", "water_premium", "budget"], {
    message: "automation.errors.triggerRequired",
  }),
  action: z.enum(["send_video", "quotation", "link"], { message: "automation.errors.actionRequired" }),
  assetUrl: z.string().trim().max(500).optional().or(z.literal("")),
  isActive: z.boolean(),
})
export type AutomationFlowInput = z.infer<typeof automationFlowSchema>

export const videoLibrarySchema = z.object({
  topic: z.enum(["online", "price", "quality", "customization", "water_premium", "budget"], {
    message: "automation.errors.topicRequired",
  }),
  url: z.string().trim().min(1, "automation.errors.urlRequired").max(500),
})
export type VideoLibraryInput = z.infer<typeof videoLibrarySchema>

export const simulateInboundSchema = z.object({
  fromMobile: z.string().trim().min(5, "automation.errors.mobileRequired").max(20),
  body: z.string().trim().min(1, "automation.errors.bodyRequired").max(1000),
})
export type SimulateInboundInput = z.infer<typeof simulateInboundSchema>

// ── Purchase (ADM-20/21) ─────────────────────────────────────────────────
export const poItemSchema = z.object({
  itemType: z.enum(["product", "spare"]),
  itemId: z.string().uuid("purchase.errors.itemRequired"),
  qty: z.coerce.number().int().positive("purchase.errors.qtyPositive"),
  price: z.coerce.number().min(0, "purchase.errors.priceNonNegative"),
})
export type PoItemInput = z.infer<typeof poItemSchema>

export const createPurchaseOrderSchema = z.object({
  supplierId: z.string().uuid("purchase.errors.supplierRequired"),
  items: z.array(poItemSchema).min(1, "purchase.errors.itemsRequired"),
})
export type CreatePurchaseOrderInput = z.infer<typeof createPurchaseOrderSchema>

export const billEntrySchema = z.object({
  supplierId: z.string().uuid("purchase.errors.supplierRequired"),
  poId: z.string().uuid().optional().or(z.literal("")),
  items: z.array(poItemSchema).min(1, "purchase.errors.itemsRequired"),
  gst: z.coerce.number().min(0, "purchase.errors.gstNonNegative"),
  billDate: z.string().min(1, "purchase.errors.billDateRequired"),
  billImageUrl: z.string().trim().max(500).optional().or(z.literal("")),
})
export type BillEntryInput = z.infer<typeof billEntrySchema>
