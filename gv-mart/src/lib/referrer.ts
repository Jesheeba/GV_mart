import { z } from "zod"
import type { DuplicateContactMatch } from "@/lib/duplicateContactWarning"

/**
 * Referral sources everywhere (build-docs/features/referral-sources.md).
 * Pure logic behind ReferrerField / QuickAddCustomerDialog, kept React-free
 * so vitest (plain Node, no jsdom) can exercise it.
 *
 * Walk-in / Lead are deliberately NOT kinds: they are Sources (how the
 * customer reached us), not people who referred them — owner decision 2026-11-26.
 */
export const REFERRER_KINDS = ["none", "technician", "staff", "customer", "other"] as const
export type ReferrerKind = (typeof REFERRER_KINDS)[number]

export type ReferrerValue = {
  kind: ReferrerKind
  /** profiles.id — technician or staff (kind technician/staff). */
  userId: string
  /** customers.id — kind customer. */
  customerId: string
  /** Display name: the picked customer's, or typed (kind other). */
  name: string
  phone: string
}

export const EMPTY_REFERRER: ReferrerValue = { kind: "none", userId: "", customerId: "", name: "", phone: "" }

/** Switching kind wipes every field the new kind doesn't own, so stale data from a kind the user backed out of is never submitted. */
export function switchReferrerKind(current: ReferrerValue, kind: ReferrerKind): ReferrerValue {
  if (current.kind === kind) return current
  return { ...EMPTY_REFERRER, kind }
}

/** A referrer is only "set" once the chosen kind has its required field. */
export function isReferrerComplete(v: ReferrerValue): boolean {
  switch (v.kind) {
    case "technician":
    case "staff":
      return v.userId !== ""
    case "customer":
      return v.customerId !== ""
    case "other":
      return v.name.trim() !== ""
    default:
      return false
  }
}

// Same rules as lib/validation/customer.ts memberSchema (10-digit Indian mobile, starts 6-9).
export const quickAddCustomerSchema = z.object({
  name: z.string().trim().min(2, "customers.errors.nameRequired").max(120),
  mobile: z
    .string()
    .trim()
    .regex(/^[6-9]\d{9}$/, "customers.errors.mobileInvalid"),
  area: z.string().trim().max(120).optional().or(z.literal("")),
})
export type QuickAddCustomerInput = z.input<typeof quickAddCustomerSchema>

/** The existing customer (not lead) holding this mobile, if any — quick-add offers it instead of creating a duplicate. */
export function existingCustomerMatch(matches: DuplicateContactMatch[] | undefined | null): DuplicateContactMatch | null {
  return (matches ?? []).find((m) => m.source === "customer") ?? null
}
