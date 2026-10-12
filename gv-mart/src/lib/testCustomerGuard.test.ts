import { describe, expect, it } from "vitest"

/**
 * CI guard for the test-customer flag (batch-2 item 5).
 *
 * Scans every migration in order, keeps the LATEST definition of each public function, and checks that:
 *   1. every function whose name looks like a report / KPI / count / incentive / lead-queue function is listed
 *      in supabase/test-customer-guard.manifest.json (must_exclude or exempt-with-reason), and
 *   2. every must_exclude function's latest definition actually references the flag.
 * A new aggregating function therefore cannot ship without an explicit decision.
 */
const migrationFiles = import.meta.glob("../../supabase/migrations/*.sql", { query: "?raw", import: "default", eager: true }) as Record<string, string>
const manifestRaw = import.meta.glob("../../supabase/test-customer-guard.manifest.json", { query: "?raw", import: "default", eager: true }) as Record<string, string>
const manifest = JSON.parse(Object.values(manifestRaw)[0]) as {
  must_exclude: string[]
  exempt: Record<string, string>
}

const WATCHED =
  /^(report_|_report_)|kpi|_stats$|funnel|_counts?$|^reward_|^compute_|^technician_(attributed|finder|installation)|_paid_earning|^list_(followups|leads_without|post_service)/
const FLAG = /is_test|_is_test\(/

function latestDefinitions(): Map<string, string> {
  const latest = new Map<string, string>()
  for (const file of Object.keys(migrationFiles).sort()) {
    const text = migrationFiles[file].replace(/\r\n/g, "\n")
    const heads = [...text.matchAll(/create (?:or replace )?function public\.(\w+)\s*\(/gi)]
    heads.forEach((m, i) => {
      const end = i + 1 < heads.length ? heads[i + 1].index! : text.length
      latest.set(m[1].toLowerCase(), text.slice(m.index!, end))
    })
  }
  return latest
}

describe("test-customer guard", () => {
  const defs = latestDefinitions()

  it("scans a plausible number of functions", () => {
    expect(defs.size).toBeGreaterThan(100)
  })

  it("every report/KPI/count function is decided in the manifest", () => {
    const decided = new Set([...manifest.must_exclude, ...Object.keys(manifest.exempt)])
    const undecided = [...defs.keys()].filter((n) => WATCHED.test(n) && !decided.has(n))
    expect(undecided, "add each to must_exclude (and exclude flagged customers) or to exempt with a reason").toEqual([])
  })

  it("no function is both must_exclude and exempt, and every exempt entry has a reason", () => {
    const both = manifest.must_exclude.filter((n) => n in manifest.exempt)
    expect(both).toEqual([])
    for (const [n, why] of Object.entries(manifest.exempt)) expect(why.trim().length, n).toBeGreaterThan(5)
  })

  it("every must_exclude function exists and its latest definition references the flag", () => {
    for (const name of manifest.must_exclude) {
      const body = defs.get(name.toLowerCase())
      expect(body, `${name} not found in migrations`).toBeTruthy()
      expect(FLAG.test(body!), `${name} no longer excludes flagged test customers`).toBe(true)
    }
  })
})
