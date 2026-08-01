import { z } from "zod"

/**
 * Mirrors the DB CHECK constraints on `settings` (Phase 1 migration
 * 20260701091100_system.sql) so the form surfaces a friendly error before
 * the request ever reaches Postgres. Messages are i18n keys — see
 * lib/validation/customer.ts for why.
 */
export const settingsSchema = z
  .object({
    per_km_minutes: z.coerce.number().positive("settings.errors.positive"),
    geofence_radius_m: z.coerce.number().int().positive("settings.errors.positive"),
    office_lat: z.coerce.number().min(-90, "settings.errors.latRange").max(90, "settings.errors.latRange"),
    office_lng: z.coerce.number().min(-180, "settings.errors.lngRange").max(180, "settings.errors.lngRange"),
    work_start: z.string().min(1, "settings.errors.required"),
    work_end: z.string().min(1, "settings.errors.required"),
    late_cutoff: z.string().min(1, "settings.errors.required"),
    very_late_threshold_minutes: z.coerce.number().int().positive("settings.errors.positive"),
    lunch_minutes_allowed: z.coerce.number().int().positive("settings.errors.positive"),
    lunch_minutes_red_threshold: z.coerce.number().int().positive("settings.errors.positive"),
    discount_tech_max: z.coerce.number().min(0).max(100, "settings.errors.percentRange"),
    discount_admin_max: z.coerce.number().min(0).max(100, "settings.errors.percentRange"),
    amc_book_window_days: z.coerce.number().int().positive("settings.errors.positive"),
    referral_point_value: z.coerce.number().min(50, "settings.errors.referralMin"),
    review_link_min_stars: z.coerce.number().min(1).max(5, "settings.errors.starsRange"),
    google_review_url: z.string().trim().url("settings.errors.urlInvalid").optional().or(z.literal("")),
    default_min_stock: z.coerce.number().int().min(0, "settings.errors.nonNegative"),
    gst_rate: z.coerce.number().min(0).max(100, "settings.errors.percentRange"),
    sla_hours_very_urgent: z.coerce.number().positive("settings.errors.positive"),
    sla_hours_urgent: z.coerce.number().positive("settings.errors.positive"),
    sla_hours_normal: z.coerce.number().positive("settings.errors.positive"),
    default_duration_paid_minutes: z.coerce.number().int().positive("settings.errors.positive"),
    default_duration_warranty_minutes: z.coerce.number().int().positive("settings.errors.positive"),
    default_duration_amc_minutes: z.coerce.number().int().positive("settings.errors.positive"),
    default_duration_installation_minutes: z.coerce.number().int().positive("settings.errors.positive"),
    narrow_window_threshold_minutes: z.coerce.number().int().positive("settings.errors.positive"),
    po_approval_threshold: z.coerce.number().min(0, "settings.errors.nonNegative"),
    po_requires_approval: z.boolean(),
    po_quote_timeout_hours: z.coerce.number().positive("settings.errors.positive"),
    // GV.md 1.2: "admin also sets a review time and a new-enquiry time allowance."
    review_time_allowance_minutes: z.coerce.number().int().positive("settings.errors.positive"),
    enquiry_time_allowance_minutes: z.coerce.number().int().positive("settings.errors.positive"),
  })
  .refine((v) => v.lunch_minutes_red_threshold > v.lunch_minutes_allowed, {
    message: "settings.errors.lunchRedAfterAllowed",
    path: ["lunch_minutes_red_threshold"],
  })
  .refine((v) => v.late_cutoff >= v.work_start, {
    message: "settings.errors.lateCutoffBeforeWorkStart",
    path: ["late_cutoff"],
  })
  .refine((v) => v.discount_admin_max >= v.discount_tech_max, {
    message: "settings.errors.adminMaxAboveTech",
    path: ["discount_admin_max"],
  })

/** Pre-coercion shape (what the form fields hold — react-hook-form's generic). */
export type SettingsFormInput = z.input<typeof settingsSchema>
/** Post-coercion shape (what gets submitted to the API). */
export type SettingsOutput = z.output<typeof settingsSchema>
