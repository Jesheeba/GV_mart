import { z } from "zod"

// Indian mobile: 10 digits, starts 6-9.
const MOBILE_REGEX = /^[6-9]\d{9}$/
const PINCODE_REGEX = /^\d{6}$/

/**
 * Messages are i18n *keys*, not literal English text — Zod schemas live
 * outside the component tree so they can't call t() themselves. Forms
 * render `t(errors.field.message)` to resolve them.
 */
export const memberSchema = z.object({
  name: z.string().trim().min(2, "customers.errors.nameRequired"),
  mobile: z.string().regex(MOBILE_REGEX, "customers.errors.mobileInvalid"),
})
export type MemberInput = z.infer<typeof memberSchema>

export const peopleStepSchema = z.object({
  members: z.array(memberSchema).min(1, "customers.errors.memberRequired").max(5, "customers.errors.memberMax"),
  primaryIndex: z.number().int().min(0),
  profession: z.string().trim().max(80).optional().or(z.literal("")),
})
export type PeopleStepInput = z.infer<typeof peopleStepSchema>

export const addressStepSchema = z.object({
  doorNo: z.string().trim().min(1, "customers.errors.doorNoRequired"),
  flatNo: z.string().trim().optional().or(z.literal("")),
  streetCross: z.string().trim().optional().or(z.literal("")),
  area: z.string().trim().min(1, "customers.errors.areaRequired"),
  pincode: z.string().regex(PINCODE_REGEX, "customers.errors.pincodeInvalid"),
  landmark: z.string().trim().optional().or(z.literal("")),
  district: z.string().trim().optional().or(z.literal("")),
  state: z.string().trim().optional().or(z.literal("")),
  addressType: z.enum(["residential", "commercial"]),
  ownership: z.enum(["own", "rental"]),
})
export type AddressStepInput = z.infer<typeof addressStepSchema>
