import { describe, expect, it } from "vitest"

/**
 * Regression (2026-11-26): 20261228100000 added leads.referred_by_customer_id and
 * customers.referred_by_customer_id, so leads<->customers now has two foreign keys.
 * PostgREST answers an un-hinted `customers(...)` embed from leads (or `leads(...)`
 * from customers) with PGRST201 "more than one relationship", which broke the
 * leads list in production. The generated types don't catch it, so this test does.
 */
// Vite raw-text glob (typed by vite/client) instead of node:fs: src is not typed for Node builtins,
// so node:fs broke `tsc -b` (npm run build). Same approach as waOutboxSentGuard.test.ts.
const sources = {
  ...import.meta.glob(["../**/*.{ts,tsx}", "!../**/*.test.{ts,tsx}"], { query: "?raw", import: "default", eager: true }),
  ...import.meta.glob(["../../supabase/functions/**/*.ts", "!../../supabase/functions/**/*.test.ts"], { query: "?raw", import: "default", eager: true }),
} as Record<string, string>

describe("leads <-> customers embeds name the foreign key", () => {
  it("the glob actually found source files (guards against a silently empty scan)", () => {
    expect(Object.keys(sources).length).toBeGreaterThan(100)
  })

  it("every from('leads') select embedding customers uses customers!<fkey>(...)", () => {
    const bad: string[] = []
    for (const [f, text] of Object.entries(sources)) {
      for (const m of text.matchAll(/from\(\s*["']leads["']\s*\)([\s\S]{0,400}?)\.select\(\s*(["'`])([\s\S]*?)\2/g)) {
        if (/(^|[^!\w])customers(!inner)?\(/.test(m[3])) bad.push(`${f}: ${m[3].slice(0, 80)}`)
      }
    }
    expect(bad).toEqual([])
  })

  it("every from('customers') select embedding leads uses leads!<fkey>(...)", () => {
    const bad: string[] = []
    for (const [f, text] of Object.entries(sources)) {
      for (const m of text.matchAll(/from\(\s*["']customers["']\s*\)([\s\S]{0,400}?)\.select\(\s*(["'`])([\s\S]*?)\2/g)) {
        if (/(^|[^!\w])(leads|customers)(!inner)?\(/.test(m[3])) bad.push(`${f}: ${m[3].slice(0, 80)}`)
      }
    }
    expect(bad).toEqual([])
  })
})
