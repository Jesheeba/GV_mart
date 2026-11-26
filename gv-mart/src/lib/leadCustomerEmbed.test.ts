import { readFileSync, readdirSync, statSync } from "node:fs"
import { join } from "node:path"
import { describe, expect, it } from "vitest"

/**
 * Regression (2026-11-26): 20261228100000 added leads.referred_by_customer_id and
 * customers.referred_by_customer_id, so leads<->customers now has two foreign keys.
 * PostgREST answers an un-hinted `customers(...)` embed from leads (or `leads(...)`
 * from customers) with PGRST201 "more than one relationship", which broke the
 * leads list in production. The generated types don't catch it, so this test does.
 */
function sourceFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const p = join(dir, name)
    if (statSync(p).isDirectory()) return sourceFiles(p)
    return /\.(ts|tsx)$/.test(name) && !/\.test\./.test(name) ? [p] : []
  })
}

describe("leads <-> customers embeds name the foreign key", () => {
  const files = [...sourceFiles(join(__dirname, "..")), ...sourceFiles(join(__dirname, "../../supabase/functions"))]

  it("every from('leads') select embedding customers uses customers!<fkey>(...)", () => {
    const bad: string[] = []
    for (const f of files) {
      const text = readFileSync(f, "utf8")
      for (const m of text.matchAll(/from\(\s*["']leads["']\s*\)([\s\S]{0,400}?)\.select\(\s*(["'`])([\s\S]*?)\2/g)) {
        if (/(^|[^!\w])customers(!inner)?\(/.test(m[3])) bad.push(`${f}: ${m[3].slice(0, 80)}`)
      }
    }
    expect(bad).toEqual([])
  })

  it("every from('customers') select embedding leads uses leads!<fkey>(...)", () => {
    const bad: string[] = []
    for (const f of files) {
      const text = readFileSync(f, "utf8")
      for (const m of text.matchAll(/from\(\s*["']customers["']\s*\)([\s\S]{0,400}?)\.select\(\s*(["'`])([\s\S]*?)\2/g)) {
        if (/(^|[^!\w])(leads|customers)(!inner)?\(/.test(m[3])) bad.push(`${f}: ${m[3].slice(0, 80)}`)
      }
    }
    expect(bad).toEqual([])
  })
})
