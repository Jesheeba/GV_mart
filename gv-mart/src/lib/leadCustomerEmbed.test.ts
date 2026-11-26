import { describe, expect, it } from "vitest"

/**
 * Regression (2026-11-26): 20261228100000 added leads.referred_by_customer_id and
 * customers.referred_by_customer_id, so leads<->customers now has two foreign keys.
 * PostgREST answers an un-hinted `customers(...)` embed from leads (or `leads(...)`
 * from customers) with PGRST201 "more than one relationship", which broke the
 * leads list in production. The generated types don't catch it, so this test does.
 */
const sources = {
  ...import.meta.glob(["../**/*.{ts,tsx}", "!../**/*.test.{ts,tsx}"], { query: "?raw", import: "default", eager: true }),
  ...import.meta.glob(["../../supabase/functions/**/*.ts", "!../../supabase/functions/**/*.test.ts"], { query: "?raw", import: "default", eager: true }),
} as Record<string, string>

function unhintedEmbeds(table: string, embedded: RegExp): string[] {
  const bad: string[] = []
  const from = new RegExp(`from\\(\\s*["']${table}["']\\s*\\)[\\s\\S]{0,400}?\\.select\\(\\s*(["'\`])([\\s\\S]*?)\\1`, "g")
  for (const [file, text] of Object.entries(sources)) {
    for (const m of text.matchAll(from)) if (embedded.test(m[2])) bad.push(`${file}: ${m[2].slice(0, 80)}`)
  }
  return bad
}

describe("leads <-> customers embeds name the foreign key", () => {
  it("scans the app and edge-function sources", () => {
    expect(Object.keys(sources).length).toBeGreaterThan(100)
  })
  it("every from('leads') select embedding customers uses customers!<fkey>(...)", () => {
    expect(unhintedEmbeds("leads", /(^|[^!\w])customers(!inner)?\(/)).toEqual([])
  })
  it("every from('customers') select embedding leads or customers uses !<fkey>", () => {
    expect(unhintedEmbeds("customers", /(^|[^!\w])(leads|customers)(!inner)?\(/)).toEqual([])
  })
})
