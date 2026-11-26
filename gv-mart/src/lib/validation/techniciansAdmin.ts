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

/**
 * Tier override (master only) → patch fragment. "Not set" ("") saves tier_id null: a null tier is the normal state of
 * a new technician and compute_salary, technician_tier_progress and the promotion detector all treat it as rank 1.
 * Unchanged → no tier_id key, so the tier guard/stamp triggers don't fire.
 */
export function tierOverridePatch(edited: string, saved: string | null | undefined): { tier_id?: string | null } {
  return edited === (saved ?? "") ? {} : { tier_id: edited || null }
}
