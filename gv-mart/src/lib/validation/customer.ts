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
  // No separate account-email field: the primary member's own email IS the account email (customers.email),
  // kept in step by the DB (20261216120000_primary_member_sync.sql).
  // WhatsApp message language (customers.preferred_language); "" = not set (English).
  preferredLanguage: z.union([z.enum(["en", "ta"]), z.literal("")]).optional(),
  // Referral incentives — capture-at-creation only (never shown/edited in edit mode, per
  // design). Same optional-uuid-or-empty-string idiom as poId (lib/validation/automation.ts)
  // / brandId/modelId (lib/validation/service.ts) — a native <select> placeholder submits "".
  referredByUserId: z.string().uuid().optional().or(z.literal("")),
})
// Same reasoning as MemberInput above: this schema embeds memberSchema
// (which transforms relation), so useForm needs the input shape.
export type PeopleStepInput = z.input<typeof peopleStepSchema>

// Mirrors the public.water_source_type Postgres enum (reused from ro_checklists —
// 20260915180000_ro_water_quality_readings.sql, not redefined for this feature).
export const WATER_SOURCES = ["corporation", "borewater", "other"] as const
export type WaterSource = (typeof WATER_SOURCES)[number]

/** Cap on the "problems faced" list (DB check: customers_household_problems_check). */
export const MAX_HOUSEHOLD_PROBLEMS = 10

/**
 * Who may edit the water/household profile fields (source/TDS/pH/hardness/problems faced) —
 * master, operation_admin and sales_admin. Mirrors the DB's guard_water_profile_edit_roles
 * trigger — this is only the UI-level gate, the DB is still the real authority.
 */
export function canEditWaterHousehold(role: string | null | undefined): boolean {
  return role === "master" || role === "operation_admin" || role === "sales_admin"
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
    waterHardnessPpm: z.union([z.number().min(0, "customers.errors.waterHardnessInvalid"), z.nan()]).optional(),
    // One row per "+ add another" click. Blank rows are dropped on save (cleanHouseholdProblems),
    // so an empty trailing input never blocks the form.
    householdProblems: z
      .array(z.object({ value: z.string().trim().max(100, "customers.errors.problemTooLong") }))
      .max(MAX_HOUSEHOLD_PROBLEMS, "customers.errors.tooManyProblems")
      .optional(),
    // Water solution follow-up (build-docs/features/water-solution-followup.md). Blank = none.
    recommendedSolution: z.string().trim().max(500, "customers.errors.solutionTooLong").optional().or(z.literal("")),
    followUpDate: z.union([z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "customers.errors.followUpDateInvalid"), z.literal("")]).optional(),
  })
  .refine((v) => !v.waterSourceOther || v.waterSource === "other", {
    message: "customers.errors.waterSourceOtherRequiresOther",
    path: ["waterSourceOther"],
  })
export type WaterProfileInput = z.input<typeof waterProfileSchema>

/**
 * A follow-up date may be blank, unchanged from the saved one (even if that is now overdue), or today or later in
 * IST. Mirrors set_customer_water_followup. Returns the i18n error key, or null when allowed.
 */
export function followUpDateError(date: string | undefined, savedDate: string | null | undefined, todayIst: string): string | null {
  if (!date || date === savedDate) return null
  return date < todayIst ? "customers.errors.followUpDatePast" : null
}

/** Trimmed, non-blank, de-duplicated (case-insensitive) problems — what gets saved. */
export function cleanHouseholdProblems(rows: { value: string }[] | undefined): string[] {
  const seen = new Set<string>()
  const out: string[] = []
  for (const { value } of rows ?? []) {
    const v = value.trim()
    if (!v || seen.has(v.toLowerCase())) continue
    seen.add(v.toLowerCase())
    out.push(v)
  }
  return out
}

export const addressStepSchema = z.object({
  // The whole address is optional — a contact can be saved without one and is
  // flagged needs_setup until an address is filled in. Pincode is only checked
  // when something was typed.
  // Clean-address-form redesign (2026-11-03): structured fields replace the
  // single free-text box again, matching the owner's layout — see
  // src/lib/address.ts (composeFullAddress/splitAddressForForm) for how
  // these feed the canonical `full_address` column search/print/invoice
  // still read. `fullAddress` is kept as the read-only fallback shown for a
  // customer saved before this change whose structured columns are empty.
  doorNo: z.string().trim().optional().or(z.literal("")),
  plotNo: z.string().trim().optional().or(z.literal("")),
  buildingName: z.string().trim().optional().or(z.literal("")),
  streetCross: z.string().trim().optional().or(z.literal("")),
  subArea: z.string().trim().optional().or(z.literal("")),
  landmark: z.string().trim().optional().or(z.literal("")),
  fullAddress: z.string().trim().optional().or(z.literal("")),
  area: z.string().trim().optional().or(z.literal("")),
  pincode: z.union([z.string().regex(PINCODE_REGEX, "customers.errors.pincodeInvalid"), z.literal("")]),
  district: z.string().trim().optional().or(z.literal("")),
  state: z.string().trim().optional().or(z.literal("")),
  zone: z.string().trim().optional().or(z.literal("")),
  // Optional: "Not set" is a real answer, saved as null (owner, 2026-11-26; 20261229100000_address_choice_not_set).
  addressType: z.enum(["residential", "commercial"], { message: "customers.errors.addressTypeRequired" }).optional(),
  ownership: z.enum(["own", "rental"], { message: "customers.errors.ownershipRequired" }).optional(),
  lat: z.number().min(-90).max(90).optional(),
  lng: z.number().min(-180).max(180).optional(),
})
export type AddressStepInput = z.infer<typeof addressStepSchema>

type AddressDetailFields = Pick<
  AddressStepInput,
  "doorNo" | "plotNo" | "buildingName" | "streetCross" | "subArea" | "landmark" | "fullAddress" | "area" | "pincode" | "district" | "state" | "zone" | "lat" | "lng"
>

/** Mirrors the RPC's has_address: any address text or a map pin (type/ownership alone don't count). */
export function hasAddressDetails(a: AddressDetailFields) {
  return (
    [a.doorNo, a.plotNo, a.buildingName, a.streetCross, a.subArea, a.landmark, a.fullAddress, a.area, a.pincode, a.district, a.state, a.zone].some(
      (v) => v?.trim()
    ) ||
    a.lat != null ||
    a.lng != null
  )
}

/**
 * Only the master role may save a customer address without pinning an exact
 * map location — every other role (sales_admin included) must still confirm
 * a pin before saving, exactly as before this was added.
 */
export function canSkipAddressPin(role: string | undefined) {
  return role === "master"
}
