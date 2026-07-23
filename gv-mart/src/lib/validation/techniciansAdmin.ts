import { z } from "zod"

/** Messages are i18n keys, resolved via t() at the call site — see lib/validation/service.ts. */

export const technicianEditSchema = z.object({
  zone: z.string().trim().max(100).optional().or(z.literal("")),
  skills: z.array(z.string()).default([]),
  is_active: z.boolean(),
  daily_capacity_minutes: z.number().int().positive(),
})
export type TechnicianEditInput = z.infer<typeof technicianEditSchema>

export const spareHandoverItemSchema = z.object({
  spareId: z.string().uuid("technicians.spares.errors.spareRequired"),
  qtyGiven: z.number().int().positive("technicians.spares.errors.qtyPositive"),
})

export const spareHandoverFormSchema = z.object({
  technicianId: z.string().uuid("technicians.spares.errors.technicianRequired"),
  date: z.string().min(1, "technicians.spares.errors.dateRequired"),
  items: z.array(spareHandoverItemSchema).min(1, "technicians.spares.errors.itemsRequired"),
})
export type SpareHandoverFormInput = z.infer<typeof spareHandoverFormSchema>
