import { ShareProductButton } from "./ShareProductButton"
import type { Json } from "@/types/database"

/**
 * Product Enquiry rebuild (2026-08-04), Phase 4 — thin adapter so ShareCta
 * fits the same CTA_RENDERERS shape as Quotation/Callback, reading which
 * fields to include from the org's admin-configured share config.
 */
export function ShareCta({
  config,
  name,
  brand,
  price,
  emiPerMonth,
}: {
  config: Json
  name: string
  brand: string | null
  price: number
  emiPerMonth: number | null
}) {
  const fields = Array.isArray((config as { fields?: unknown })?.fields) ? ((config as { fields: unknown[] }).fields.filter((f) => typeof f === "string") as string[]) : []
  return <ShareProductButton fields={fields} name={name} brand={brand} price={price} emiPerMonth={emiPerMonth} />
}
