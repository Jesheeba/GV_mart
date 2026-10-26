import { z } from "zod"

// Indian mobile: 10 digits, starts 6-9.
const MOBILE_REGEX = /^[6-9]\d{9}$/
const PINCODE_REGEX = /^\d{6}$/
// Same loose shape as the customer_members_email_format check constraint.
const EMAIL_REGEX = /^[^@\s]+@[^@\s]+\.[^@\s]+$/

// Mirrors the public.family_relation Postgres enum (migration
// 20260703130000_family_member_relation.sql). Only meaningful for
// non-primary members — the primary member IS the customer.
export const FAMILY_RELATIONS = ["spouse", "son", "daughter", "parent", "sibling", "other"] as const
export type FamilyRelation = (typeof FAMILY_RELATIONS)[number]

/**
 * Messages are i18n *keys*, not literal English text — Zod schemas live
 * outside the component tree so they can't call t() themselves. Forms
 * render `t(errors.field.message)` to resolve them.
 */
export const memberSchema = z.object({
  name: z.string().trim().min(2, "customers.errors.nameRequired"),
  mobile: z.string().regex(MOBILE_REGEX, "customers.errors.mobileInvalid"),
  // A native <select> with a placeholder `<option value="">` submits "" for
  // "nothing chosen", not undefined — z.enum(...).optional() only accepts
  // undefined, so "" silently failed validation with no rendered error on
  // this field (relation has no {errors.relation...} block anywhere it's
  // used), making Save do nothing with zero feedback whenever relation was
  // left on its placeholder. Accept "" too and normalize it to undefined so
  // every existing `relation ?? null` call site downstream still works
  // unchanged.
  relation: z
    .union([z.enum(FAMILY_RELATIONS), z.literal("")])
    .optional()
    .transform((v) => (v === "" ? undefined : v)),
  profession: z.string().trim().max(80).optional().or(z.literal("")),
  // Optional. Field order on every member form: Name, Number, Profession, Email.
  email: z.string().trim().max(254).refine((v) => v === "" || EMAIL_REGEX.test(v), "customers.errors.emailInvalid").optional(),
})
// react-hook-form types form state from the schema's *input* shape (what the
// user can actually type/select, including relation:"" before transform),
// not z.infer's output shape — using z.infer here caused a resolver/useForm
// generic mismatch (TS2322/TS2345) because relation's output type drops "".
export type MemberInput = z.input<typeof memberSchema>

export const peopleStepSchema = z.object({
  members: z.array(memberSchema).min(1, "customers.errors.memberRequired").max(5, "customers.errors.memberMax"),
  primaryIndex: z.number().int().min(0),
  profession: z.string().trim().max(80).optional().or(z.literal("")),
  // WhatsApp message language (customers.preferred_language); "" = not set (English).
  preferredLanguage: z.union([z.enum(["en", "ta"]), z.literal("")]).optional(),
})
// Same reasoning as MemberInput above: this schema embeds memberSchema
// (which transforms relation), so useForm needs the input shape.
export type PeopleStepInput = z.input<typeof peopleStepSchema>

// Mirrors the public.water_source_type Postgres enum (reused from ro_checklists —
// 20260915180000_ro_water_quality_readings.sql, not redefined for this feature).
export const WATER_SOURCES = ["corporation", "borewater", "other"] as const
export type WaterSource = (typeof WATER_SOURCES)[number]

// Mirrors the public.household_health_level Postgres enum
// (20261108100000_customer_water_profile.sql).
export const HEALTH_CONDITION_LEVELS = ["none", "normal", "medium", "high"] as const
export type HealthConditionLevel = (typeof HEALTH_CONDITION_LEVELS)[number]

/**
 * Who may edit the water/household profile fields (water source/TDS/pH + health_condition) —
 * master, operation_admin and sales_admin, per FEATURE_CUSTOMER_WATER_HOUSEHOLD_PROFILE.md.
 * Mirrors the DB's actual enforcement (guard_water_profile_edit_roles trigger for the water
 * columns; is_staff() RLS for customer_health_profile) — this is only the UI-level gate
 * (show/hide edit controls), the DB is still the real authority either way.
 */
export function canEditWaterHousehold(role: string | null | undefined): boolean {
  return role === "master" || role === "operation_admin" || role === "sales_admin"
}

/**
 * Whether a technician's job/history detail should even query/render the health_condition
 * row — gated on the org's show_health_condition_to_technicians setting (default off/absent,
 * fails closed). This is only the UI-level gate; get_customer_health_condition additionally
 * checks the technician actually has an appointment with that customer, server-side.
 */
export function technicianCanSeeHealthCondition(showHealthConditionSetting: boolean | null | undefined): boolean {
  return showHealthConditionSetting === true
}

/**
 * Same "" vs undefined gotcha as memberSchema.relation above — a native <select> with a
 * placeholder option submits "", not undefined.
 */
export const waterProfileSchema = z
  .object({
    waterSource: z
      .union([z.enum(WATER_SOURCES), z.literal("")])
      .optional()
      .transform((v) => (v === "" ? undefined : v)),
    waterSourceOther: z.string().trim().max(100).optional().or(z.literal("")),
    // DB check constraint mirrors this range (customers_water_ph_check); kept here too so the
    // form shows an error immediately instead of round-tripping to the server first.
    waterPh: z
      .union([z.number().min(0, "customers.errors.waterPhInvalid").max(14, "customers.errors.waterPhInvalid"), z.nan()])
      .optional(),
    waterTdsPpm: z.union([z.number().min(0, "customers.errors.waterTdsInvalid"), z.nan()]).optional(),
    healthCondition: z
      .union([z.enum(HEALTH_CONDITION_LEVELS), z.literal("")])
      .optional()
      .transform((v) => (v === "" ? undefined : v)),
  })
  .refine((v) => !v.waterSourceOther || v.waterSource === "other", {
    message: "customers.errors.waterSourceOtherRequiresOther",
    path: ["waterSourceOther"],
  })
export type WaterProfileInput = z.input<typeof waterProfileSchema>

export const addressStepSchema = z.object({
  // The whole address is optional — a contact can be saved without one and is
  // flagged needs_setup until an address is filled in. Pincode is only checked
  // when something was typed.
  doorNo: z.string().trim().optional().or(z.literal("")),
  buildingNo: z.string().trim().optional().or(z.literal("")),
  buildingName: z.string().trim().optional().or(z.literal("")),
  plotNo: z.string().trim().optional().or(z.literal("")),
  streetCross: z.string().trim().optional().or(z.literal("")),
  area: z.string().trim().optional().or(z.literal("")),
  pincode: z.union([z.string().regex(PINCODE_REGEX, "customers.errors.pincodeInvalid"), z.literal("")]),
  landmark: z.string().trim().optional().or(z.literal("")),
  district: z.string().trim().optional().or(z.literal("")),
  state: z.string().trim().optional().or(z.literal("")),
  zone: z.string().trim().optional().or(z.literal("")),
  addressType: z.enum(["residential", "commercial"]),
  ownership: z.enum(["own", "rental"]),
  lat: z.number().min(-90).max(90).optional(),
  lng: z.number().min(-180).max(180).optional(),
})
export type AddressStepInput = z.infer<typeof addressStepSchema>
