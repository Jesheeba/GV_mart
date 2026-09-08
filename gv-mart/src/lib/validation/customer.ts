import { z } from "zod"

// Indian mobile: 10 digits, starts 6-9.
const MOBILE_REGEX = /^[6-9]\d{9}$/
const PINCODE_REGEX = /^\d{6}$/

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
})
// Same reasoning as MemberInput above: this schema embeds memberSchema
// (which transforms relation), so useForm needs the input shape.
export type PeopleStepInput = z.input<typeof peopleStepSchema>

export const addressStepSchema = z.object({
  doorNo: z.string().trim().min(1, "customers.errors.doorNoRequired"),
  flatNo: z.string().trim().optional().or(z.literal("")),
  streetCross: z.string().trim().optional().or(z.literal("")),
  area: z.string().trim().min(1, "customers.errors.areaRequired"),
  pincode: z.string().regex(PINCODE_REGEX, "customers.errors.pincodeInvalid"),
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
